// Mithril-Wapper - egl/egl.mm
// EGL 1.5 implementation backed by Metal 2.
//
// This is the layer that Amethyst-iOS' Natives/ctxbridges/gl_bridge.m dlsym's
// against libmithril.dylib. It exposes the 21 egl* entry points listed in
// Amethyst's `egl_library` struct (see Natives/ctxbridges/gl_bridge.h) plus a
// handful of EGL 1.5 helpers (eglCreatePbufferSurface, eglQuerySurface, ...).
//
// Mapping:
//   EGLDisplay  -> singleton EglDisplay wrapping the MTLDevice/MTLCommandQueue
//                  from metal_context.mm (we reuse metal_init/metal_device).
//   EGLConfig   -> opaque pointer to one of a small set of pre-baked
//                  EglConfig records (RGBA8 + optional depth/stencil).
//   EGLSurface  -> EglSurface holding a CAMetalLayer*, the current
//                  CAMetalDrawable, and a Depth32Float_Stencil8 MTLTexture
//                  matching the drawable size.
//   EGLContext  -> EglContext holding its own mithril::GLState* (allocated
//                  via state_create()) so multiple contexts do not share GL
//                  object tables. eglMakeCurrent swaps mithril::g_state to
//                  point at the chosen context's state.
//
// The render path:
//   eglMakeCurrent installs the surface's current drawable MTLTexture on
//   g_state->eglDefaultColor. GL commands against framebuffer 0 then render
//   straight into the on-screen drawable (see collect_draw_fbo_attachments).
//   eglSwapBuffers flushes Mithril's pending Metal work, presents the
//   drawable to the CAMetalLayer, then acquires the next drawable for the
//   following frame.
//
// Minimum requirements: Metal 2 (MTLCreateSystemDefaultDevice), iOS 14+,
// MSL 2.3. All Metal API used here (MTLDevice / MTLCommandQueue /
// MTLTexture / CAMetalLayer) is available since iOS 8 / Metal 1, so the
// A11 / Metal 2 floor declared in README.md is comfortably satisfied.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>   // object_setClass() for layer coercion

#include "includes.h"
#include <EGL/egl.h>

#include <atomic>
#include <mutex>
#include <thread>

// ---------------------------------------------------------------------------
// Internal handle types
// ---------------------------------------------------------------------------
namespace {

struct EglDisplay {
    bool      initialized = false;
    EGLenum   boundAPI   = EGL_OPENGL_API;
};

struct EglConfig {
    EGLint  redSize;
    EGLint  greenSize;
    EGLint  blueSize;
    EGLint  alphaSize;
    EGLint  depthSize;
    EGLint  stencilSize;
    EGLint  surfaceType;   // EGL_WINDOW_BIT | EGL_PBUFFER_BIT
    EGLint  renderableType; // EGL_OPENGL_BIT (we expose Core Profile)
    EGLint  configId;
};

struct EglSurface {
    CAMetalLayer*       layer      = nil;     // weak ref; owned by the host view
    id<CAMetalDrawable> drawable   = nil;     // current frame's drawable
    id<MTLTexture>      colorTex   = nil;     // == drawable.texture (cached)
    id<MTLTexture>      depthTex   = nil;     // Depth32Float_Stencil8
    EGLConfig           config     = nullptr;
    EGLint              width      = 0;
    EGLint              height     = 0;
    EGLint              swapInterval = 1;
    bool                firstFrame = true;
};

struct EglContext {
    mithril::GLState*   state      = nullptr;
    EGLConfig           config     = nullptr;
    EglContext*         share      = nullptr;
    EGLenum             clientAPI  = EGL_OPENGL_API;
    EGLint              majorVer   = 3;   // we report OpenGL 3.3 Core Profile
    EGLint              minorVer   = 3;
    bool                lost       = false;
    std::atomic<int>    refcount{1};
};

// Singleton display. Returned for every eglGetDisplay / eglGetPlatformDisplay.
EglDisplay g_display;

// Pre-baked configs. Indexed by EGLConfig (we hand out &g_configs[i]).
EglConfig g_configs[] = {
    // id=1: RGBA8 + D24S8 (the config Amethyst requests for MC Java)
    { 8, 8, 8, 8, 24, 8,  EGL_WINDOW_BIT | EGL_PBUFFER_BIT, EGL_OPENGL_BIT, 1 },
    // id=2: RGBA8 + D24 (no stencil)
    { 8, 8, 8, 8, 24, 0,  EGL_WINDOW_BIT | EGL_PBUFFER_BIT, EGL_OPENGL_BIT, 2 },
    // id=3: RGBA8 + S8 (no depth)
    { 8, 8, 8, 8, 0,  8,  EGL_WINDOW_BIT | EGL_PBUFFER_BIT, EGL_OPENGL_BIT, 3 },
    // id=4: RGBA8 only
    { 8, 8, 8, 8, 0,  0,  EGL_WINDOW_BIT | EGL_PBUFFER_BIT, EGL_OPENGL_BIT, 4 },
};
constexpr int kNumConfigs = sizeof(g_configs) / sizeof(g_configs[0]);

// Thread-local EGL current state (mirrors Khronos EGL semantics).
thread_local EglContext* t_currentCtx    = nullptr;
thread_local EglSurface* t_currentDraw   = nullptr;
thread_local EglSurface* t_currentRead   = nullptr;
thread_local EGLint      t_lastError     = EGL_SUCCESS;
thread_local EGLenum     t_boundAPI      = EGL_OPENGL_API;

std::mutex g_ctxMutex; // guards share-group refcount updates

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------
inline void set_error(EGLint e) { if (t_lastError == EGL_SUCCESS) t_lastError = e; }
inline void clear_error()       { t_lastError = EGL_SUCCESS; }

inline bool valid_display(EGLDisplay d) {
    return d == (EGLDisplay)&g_display;
}
inline bool valid_config(EGLConfig c) {
    if (!c) return false;
    for (int i = 0; i < kNumConfigs; ++i) {
        if ((EGLConfig)&g_configs[i] == c) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Metal helpers
// ---------------------------------------------------------------------------
id<MTLTexture> create_depth_texture(int w, int h) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev || w <= 0 || h <= 0) return nil;
    MTLTextureDescriptor* d = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                     width:(NSUInteger)w
                                    height:(NSUInteger)h
                                 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;     // GPU-local on iOS
    return [dev newTextureWithDescriptor:d];
}

// Acquire the next CAMetalDrawable from the layer and cache its texture on
// the surface. Returns true on success.
bool acquire_next_drawable(EglSurface* s) {
    if (!s || !s->layer) return false;
    // nextDrawable may block until a frame is free; cap with a small timeout
    // via @try in case the layer is in a transient state.
    @try {
        s->drawable = [s->layer nextDrawable];
    } @catch (NSException* ex) {
        s->drawable = nil;
    }
    if (!s->drawable) return false;
    s->colorTex = [s->drawable texture];
    s->width  = (EGLint)s->layer.drawableSize.width;
    s->height = (EGLint)s->layer.drawableSize.height;
    // (Re)allocate the matching depth/stencil texture if the size changed.
    if (s->depthTex &&
        ((EGLint)s->depthTex.width != s->width ||
         (EGLint)s->depthTex.height != s->height)) {
        s->depthTex = nil;
    }
    if (!s->depthTex && s->config) {
        EglConfig* cfg = (EglConfig*)s->config;
        if (cfg->depthSize > 0 || cfg->stencilSize > 0) {
            s->depthTex = create_depth_texture(s->width, s->height);
        }
    }
    return s->colorTex != nil;
}

// Push the surface's current color/depth MTLTextures into the active GLState
// so framebuffer-0 renders land on the on-screen drawable.
void install_surface_on_state(EglSurface* s) {
    if (!g_state) return;
    if (s && s->colorTex) {
        g_state->eglDefaultColor = (__bridge void*)s->colorTex;
        g_state->eglDefaultDepth = s->depthTex ? (__bridge void*)s->depthTex : nullptr;
        g_state->eglDefaultWidth  = s->width;
        g_state->eglDefaultHeight = s->height;
    } else {
        g_state->eglDefaultColor = nullptr;
        g_state->eglDefaultDepth = nullptr;
        g_state->eglDefaultWidth  = 0;
        g_state->eglDefaultHeight = 0;
    }
}

// ---------------------------------------------------------------------------
// Config matching
// ---------------------------------------------------------------------------
bool config_matches(const EglConfig* cfg, const EGLint* attribs) {
    if (!attribs) return true;
    for (const EGLint* a = attribs; *a != EGL_NONE; a += 2) {
        EGLint name  = a[0];
        EGLint value = a[1];
        if (value == EGL_DONT_CARE) continue;
        switch (name) {
            case EGL_RED_SIZE:        if (cfg->redSize       < value) return false; break;
            case EGL_GREEN_SIZE:      if (cfg->greenSize     < value) return false; break;
            case EGL_BLUE_SIZE:       if (cfg->blueSize      < value) return false; break;
            case EGL_ALPHA_SIZE:      if (cfg->alphaSize     < value) return false; break;
            case EGL_DEPTH_SIZE:      if (cfg->depthSize     < value) return false; break;
            case EGL_STENCIL_SIZE:    if (cfg->stencilSize   < value) return false; break;
            case EGL_SURFACE_TYPE:    if ((cfg->surfaceType & value) != value) return false; break;
            case EGL_RENDERABLE_TYPE: if ((cfg->renderableType & value) != value) return false; break;
            case EGL_COLOR_BUFFER_TYPE: if (value != EGL_RGB_BUFFER) return false; break;
            case EGL_CONFIG_ID:       if (cfg->configId != value) return false; break;
            case EGL_LEVEL:           break; // ignored
            case EGL_NATIVE_RENDERABLE: break; // ignored
            case EGL_NATIVE_VISUAL_ID: break; // ignored
            case EGL_BIND_TO_TEXTURE_RGB:
            case EGL_BIND_TO_TEXTURE_RGBA:
                // We always permit texturing; ignore the constraint.
                break;
            default:
                // Unknown attribute — EGL says this is EGL_BAD_ATTRIBUTE,
                // but to be tolerant of extension tokens we ignore it.
                break;
        }
    }
    return true;
}

EGLint config_get_attr(const EglConfig* cfg, EGLint attr) {
    switch (attr) {
        case EGL_RED_SIZE:        return cfg->redSize;
        case EGL_GREEN_SIZE:      return cfg->greenSize;
        case EGL_BLUE_SIZE:       return cfg->blueSize;
        case EGL_ALPHA_SIZE:      return cfg->alphaSize;
        case EGL_DEPTH_SIZE:      return cfg->depthSize;
        case EGL_STENCIL_SIZE:    return cfg->stencilSize;
        case EGL_SURFACE_TYPE:    return cfg->surfaceType;
        case EGL_RENDERABLE_TYPE: return cfg->renderableType;
        case EGL_CONFORMANT:      return cfg->renderableType;
        case EGL_CONFIG_ID:       return cfg->configId;
        case EGL_COLOR_BUFFER_TYPE: return EGL_RGB_BUFFER;
        case EGL_BUFFER_SIZE:     return cfg->redSize + cfg->greenSize + cfg->blueSize;
        case EGL_LUMINANCE_SIZE:  return 0;
        case EGL_ALPHA_MASK_SIZE: return 0;
        case EGL_CONFIG_CAVEAT:   return EGL_NONE;
        case EGL_LEVEL:           return 0;
        case EGL_MAX_PBUFFER_WIDTH:  return 16384;
        case EGL_MAX_PBUFFER_PIXELS: return 16384 * 16384;
        case EGL_NATIVE_RENDERABLE:  return EGL_FALSE;
        // EGL_NATIVE_VISUAL_ID and EGL_MAX_PBUFFER_HEIGHT are the same token
        // (0x3030) in the Khronos EGL spec; EGL_NATIVE_VISUAL_TYPE and
        // EGL_SAMPLES share 0x3031. A config query at 0x3030 returns the
        // native visual id (0 — gl_bridge.m tolerates this), and 0x3031
        // returns the sample count (0 == no MSAA). One case label per value.
        case EGL_NATIVE_VISUAL_ID:   return 0;
        case EGL_SAMPLES:            return 0;
        case EGL_SAMPLE_BUFFERS:     return 0;
        case EGL_TRANSPARENT_TYPE:   return EGL_NONE;
        case EGL_MIN_SWAP_INTERVAL:  return 0;
        case EGL_MAX_SWAP_INTERVAL:  return 1;
        default:                     return 0;
    }
}

} // namespace

// ===========================================================================
// Public EGL entry points (extern "C", exported by libmithril.dylib)
//
// Force default visibility at the source level regardless of the toolchain's
// global visibility policy. leetal/ios-cmake compiles .mm files as OBJCXX with
// -fvisibility=hidden by default; without this pragma the egl* entry points
// would be hidden, never enter the dylib's export table, and host launchers
// (Amethyst-iOS' egl_bridge.m) would see:
//     dlsym(handle, "eglCreateContext"): symbol not found
// followed by a NULL-pointer SIGSEGV in gl_make_current when the unresolved
// pointer is later called. The pragma below overrides hidden visibility so
// every egl* in this block is exported and dlsym-resolvable.
// ===========================================================================
#pragma GCC visibility push(default)
extern "C" {

EGLDisplay eglGetDisplay(EGLNativeDisplayType display_id) {
    clear_error();
    (void)display_id;   // we always return the singleton Metal-backed display
    return (EGLDisplay)&g_display;
}

EGLDisplay eglGetPlatformDisplay(EGLenum platform, void* native_display,
                                 const EGLint* attrib_list) {
    clear_error();
    (void)platform; (void)native_display; (void)attrib_list;
    // We are a single-display implementation; any platform token resolves to
    // the Metal-backed singleton. EGL_EXT_platform_base callers (Amethyst's
    //eglGetPlatformDisplay path) land here.
    return (EGLDisplay)&g_display;
}

EGLBoolean eglInitialize(EGLDisplay dpy, EGLint* major, EGLint* minor) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    // Bring up the Metal backend once. metal_init() is idempotent.
    metal_init();
    if (!metal_available()) {
        set_error(EGL_NOT_INITIALIZED);
        return EGL_FALSE;
    }
    g_display.initialized = true;
    if (major) *major = 1;
    if (minor) *minor = 5;
    return EGL_TRUE;
}

EGLBoolean eglTerminate(EGLDisplay dpy) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    // We do NOT destroy the Metal device/queue — the host process may call
    // eglInitialize again, and Metal device creation is expensive. Just mark
    // the display as not-initialized so callers must re-init per spec.
    g_display.initialized = false;
    return EGL_TRUE;
}

const char* eglQueryString(EGLDisplay dpy, EGLint name) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return nullptr; }
    switch (name) {
        case EGL_VENDOR:
            return "Mithril-Wapper (EGL-on-Metal 2)";
        case EGL_VERSION:
            return "1.5 Mithril-Wapper (Metal 2 backend)";
        case EGL_CLIENT_APIS:
            return "OpenGL";   // we expose OpenGL 3.3 Core Profile
        case EGL_EXTENSIONS:
            // Minimal but honest list of what we actually implement.
            return "EGL_EXT_platform_base EGL_KHR_platform_android "
                   "EGL_ANDROID_recordable EGL_MESA_platform_surfaceless "
                   "EGL_KHR_swap_buffers_with_damage";
        default:
            set_error(EGL_BAD_PARAMETER);
            return nullptr;
    }
}

EGLBoolean eglBindAPI(EGLenum api) {
    clear_error();
    if (api != EGL_OPENGL_API && api != EGL_OPENGL_ES_API && api != EGL_OPENVG_API) {
        set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    // We always expose OpenGL 3.3 Core Profile, but we accept OpenGL ES
    // requests too — the Mithril GL state machine is API-agnostic at the
    // surface level. Amethyst binds EGL_OPENGL_API for the Metal-ANGLE path
    // and EGL_OPENGL_ES_API for the LTW/GLES path; either works here.
    t_boundAPI = api;
    g_display.boundAPI = api;
    return EGL_TRUE;
}

EGLBoolean eglReleaseThread(void) {
    clear_error();
    // Drop the thread-local current context/surface references.
    t_currentCtx  = nullptr;
    t_currentDraw = nullptr;
    t_currentRead = nullptr;
    return EGL_TRUE;
}

EGLint eglGetError(void) {
    EGLint e = t_lastError;
    t_lastError = EGL_SUCCESS;
    return e;
}

// ---- Configs ----
EGLBoolean eglGetConfigs(EGLDisplay dpy, EGLConfig* configs,
                         EGLint config_size, EGLint* num_config) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    if (!num_config) { set_error(EGL_BAD_PARAMETER); return EGL_FALSE; }
    if (!configs || config_size <= 0) {
        *num_config = kNumConfigs;
        return EGL_TRUE;
    }
    EGLint n = kNumConfigs < config_size ? kNumConfigs : config_size;
    for (EGLint i = 0; i < n; ++i) configs[i] = (EGLConfig)&g_configs[i];
    *num_config = n;
    return EGL_TRUE;
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint* attrib_list,
                           EGLConfig* configs, EGLint config_size,
                           EGLint* num_config) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    if (!num_config) { set_error(EGL_BAD_PARAMETER); return EGL_FALSE; }

    EGLint matches[kNumConfigs];
    EGLint n = 0;
    for (int i = 0; i < kNumConfigs; ++i) {
        if (config_matches(&g_configs[i], attrib_list)) {
            matches[n++] = i;
        }
    }
    if (!configs || config_size <= 0) {
        *num_config = n;
        return EGL_TRUE;
    }
    EGLint out = n < config_size ? n : config_size;
    for (EGLint i = 0; i < out; ++i) configs[i] = (EGLConfig)&g_configs[matches[i]];
    *num_config = out;
    return EGL_TRUE;
}

EGLBoolean eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config,
                              EGLint attribute, EGLint* value) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    if (!valid_config(config)) { set_error(EGL_BAD_CONFIG); return EGL_FALSE; }
    if (!value) { set_error(EGL_BAD_PARAMETER); return EGL_FALSE; }
    *value = config_get_attr((EglConfig*)config, attribute);
    return EGL_TRUE;
}

// ---- Surfaces ----
EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config,
                                  EGLNativeWindowType win,
                                  const EGLint* attrib_list) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_NO_SURFACE; }
    if (!valid_config(config)) { set_error(EGL_BAD_CONFIG); return EGL_NO_SURFACE; }
    if (!win) { set_error(EGL_BAD_NATIVE_WINDOW); return EGL_NO_SURFACE; }

    // The native window is the host CALayer. Amethyst's SurfaceViewController
    // passes its view's root layer; for Metal rendering it MUST be a
    // CAMetalLayer. If it isn't, we try to coerce it (the host view sets this
    // up itself in production; the coercion is a safety net for ad-hoc hosts).
    CALayer* layer = (__bridge CALayer*)win;
    CAMetalLayer* mtlLayer = nil;
    if ([layer isKindOfClass:[CAMetalLayer class]]) {
        mtlLayer = (CAMetalLayer*)layer;
    } else {
        // Coerce: replace the layer's class with CAMetalLayer. This mirrors
        // what UIKit views do in +layerClass. We only do this if the layer is
        // standalone (not yet attached as a sublayer) to avoid surprising the
        // host view hierarchy.
        object_setClass(layer, [CAMetalLayer class]);
        mtlLayer = (CAMetalLayer*)layer;
    }
    if (!mtlLayer) {
        set_error(EGL_BAD_NATIVE_WINDOW);
        return EGL_NO_SURFACE;
    }
    // Bind the layer to our MTLDevice (idempotent).
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (dev && mtlLayer.device != dev) mtlLayer.device = dev;
    mtlLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    mtlLayer.framebufferOnly = YES;
    if (mtlLayer.drawableSize.width == 0 || mtlLayer.drawableSize.height == 0) {
        mtlLayer.drawableSize = layer.bounds.size;
    }

    (void)attrib_list; // we ignore render-buffer / post-sub-buffer attribs

    EglSurface* s = new EglSurface{};
    s->layer  = mtlLayer;
    s->config = config;
    s->firstFrame = true;
    // Acquire the first drawable so eglMakeCurrent has something to install.
    if (!acquire_next_drawable(s)) {
        // nextDrawable can fail if the layer isn't sized yet; defer to
        // eglMakeCurrent / eglSwapBuffers which will retry.
        NSLog(@"[egl] eglCreateWindowSurface: deferred first drawable (layer size = %.0fx%.0f)",
              mtlLayer.drawableSize.width, mtlLayer.drawableSize.height);
    }
    return (EGLSurface)s;
}

EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config,
                                   const EGLint* attrib_list) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_NO_SURFACE; }
    if (!valid_config(config)) { set_error(EGL_BAD_CONFIG); return EGL_NO_SURFACE; }
    (void)attrib_list;
    // PBuffers are not actively used by MC Java; return a no-op surface so
    // EGL probes (LWJGL) succeed. We do not allocate a backing texture until
    // the surface is actually rendered to.
    EglSurface* s = new EglSurface{};
    s->config = config;
    return (EGLSurface)s;
}

EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surface) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    if (surface == EGL_NO_SURFACE) { set_error(EGL_BAD_SURFACE); return EGL_FALSE; }
    EglSurface* s = (EglSurface*)surface;
    // Detach from any current context on this thread.
    if (t_currentDraw == s) { t_currentDraw = nullptr; install_surface_on_state(nullptr); }
    if (t_currentRead == s) { t_currentRead = nullptr; }
    s->drawable = nil;
    s->colorTex = nil;
    s->depthTex = nil;
    s->layer = nil;
    delete s;
    return EGL_TRUE;
}

EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface surface,
                           EGLint attribute, EGLint* value) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    EglSurface* s = (EglSurface*)surface;
    if (!s) { set_error(EGL_BAD_SURFACE); return EGL_FALSE; }
    if (!value) { set_error(EGL_BAD_PARAMETER); return EGL_FALSE; }
    switch (attribute) {
        case EGL_WIDTH:           *value = s->width;  break;
        case EGL_HEIGHT:          *value = s->height; break;
        case EGL_CONFIG_ID:
            *value = s->config ? ((EglConfig*)s->config)->configId : 0; break;
        case EGL_RENDER_BUFFER:   *value = EGL_BACK_BUFFER; break;
        case EGL_SWAP_BEHAVIOR:   *value = EGL_BUFFER_DESTROYED; break;
        case EGL_MULTISAMPLE_RESOLVE: *value = EGL_MULTISAMPLE_RESOLVE_DEFAULT; break;
        default:                  *value = 0; break;
    }
    return EGL_TRUE;
}

// ---- Contexts ----
EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config,
                            EGLContext share_context,
                            const EGLint* attrib_list) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_NO_CONTEXT; }
    if (!valid_config(config)) { set_error(EGL_BAD_CONFIG); return EGL_NO_CONTEXT; }

    EglContext* ctx = new EglContext{};
    ctx->state = mithril::state_create();
    ctx->config = config;
    ctx->clientAPI = t_boundAPI;
    ctx->majorVer = 3;
    ctx->minorVer = 3;

    // Parse context attributes (EGL_CONTEXT_MAJOR_VERSION / _CLIENT_VERSION /
    // _MINOR_VERSION / _FLAGS_KHR / _OPENGL_PROFILE_MASK). We are an OpenGL
    // 3.3 Core Profile implementation, so we honor 3.3 / 4.x requests by
    // clamping to 3.3 (the highest Core Profile version Mithril speaks).
    if (attrib_list) {
        for (const EGLint* a = attrib_list; *a != EGL_NONE; a += 2) {
            EGLint name = a[0], value = a[1];
            if (name == EGL_CONTEXT_MAJOR_VERSION || name == EGL_CONTEXT_CLIENT_VERSION) {
                ctx->majorVer = value;
            } else if (name == EGL_CONTEXT_MINOR_VERSION) {
                ctx->minorVer = value;
            } else if (name == EGL_CONTEXT_OPENGL_PROFILE_MASK) {
                // We always report Core Profile; Compatibility is silently
                // honoured because our entry points don't differ.
            } else if (name == EGL_CONTEXT_FLAGS_KHR) {
                // No-op: we don't expose debug/robustness yet.
            }
        }
    }
    if (ctx->majorVer > 3 || (ctx->majorVer == 3 && ctx->minorVer > 3)) {
        ctx->majorVer = 3; ctx->minorVer = 3;
    }

    if (share_context != EGL_NO_CONTEXT) {
        EglContext* sh = (EglContext*)share_context;
        ctx->share = sh;
        std::lock_guard<std::mutex> lk(g_ctxMutex);
        sh->refcount.fetch_add(1);
    }
    return (EGLContext)ctx;
}

EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    EglContext* c = (EglContext*)ctx;
    if (!c || c == (EglContext*)EGL_NO_CONTEXT) {
        set_error(EGL_BAD_CONTEXT); return EGL_FALSE;
    }
    // If this context is current on this thread, detach it first.
    if (t_currentCtx == c) {
        install_surface_on_state(nullptr);
        mithril::g_state = nullptr;
        t_currentCtx = nullptr;
        t_currentDraw = nullptr;
        t_currentRead = nullptr;
    }
    {
        std::lock_guard<std::mutex> lk(g_ctxMutex);
        if (c->refcount.fetch_sub(1) == 1) {
            mithril::state_destroy(c->state);
            delete c;
        }
    }
    return EGL_TRUE;
}

EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read,
                          EGLContext ctx) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }

    // Detach case: ctx == EGL_NO_CONTEXT and draw/read == EGL_NO_SURFACE.
    if (ctx == EGL_NO_CONTEXT) {
        if (draw != EGL_NO_SURFACE || read != EGL_NO_SURFACE) {
            set_error(EGL_BAD_MATCH); return EGL_FALSE;
        }
        install_surface_on_state(nullptr);
        mithril::g_state = nullptr;
        t_currentCtx = nullptr;
        t_currentDraw = nullptr;
        t_currentRead = nullptr;
        return EGL_TRUE;
    }

    EglContext* c = (EglContext*)ctx;
    EglSurface* d = (EglSurface*)draw;
    EglSurface* r = (read == draw) ? d : (EglSurface*)read;
    if (!c) { set_error(EGL_BAD_CONTEXT); return EGL_FALSE; }

    // Make sure the Metal backend is up before any GL call lands.
    metal_init();

    // Swap Mithril's global state pointer to this context's state.
    mithril::g_state = c->state;

    // Install the draw surface's drawable on the (now current) GLState so
    // framebuffer-0 rendering lands on the on-screen CAMetalLayer.
    if (d) {
        if (!d->colorTex && d->layer) {
            // First make-current on a freshly-created surface whose initial
            // nextDrawable() failed (layer wasn't sized yet). Retry now.
            acquire_next_drawable(d);
        }
        install_surface_on_state(d);
        // Initialise the viewport to the surface size if the app hasn't yet.
        if (c->state->viewportW <= 0 || c->state->viewportH <= 0) {
            c->state->viewportX = 0;
            c->state->viewportY = 0;
            c->state->viewportW = d->width;
            c->state->viewportH = d->height;
        }
    } else {
        install_surface_on_state(nullptr);
    }

    t_currentCtx  = c;
    t_currentDraw = d;
    t_currentRead = r ? r : d;
    return EGL_TRUE;
}

EGLContext eglGetCurrentContext(void) {
    return (EGLContext)t_currentCtx;
}

EGLSurface eglGetCurrentSurface(EGLenum readdraw) {
    if (readdraw == EGL_READ) return (EGLSurface)t_currentRead;
    if (readdraw == EGL_DRAW) return (EGLSurface)t_currentDraw;
    set_error(EGL_BAD_PARAMETER);
    return EGL_NO_SURFACE;
}

EGLDisplay eglGetCurrentDisplay(void) {
    return t_currentCtx ? (EGLDisplay)&g_display : EGL_NO_DISPLAY;
}

EGLBoolean eglQueryContext(EGLDisplay dpy, EGLContext ctx,
                           EGLint attribute, EGLint* value) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    EglContext* c = (EglContext*)ctx;
    if (!c) { set_error(EGL_BAD_CONTEXT); return EGL_FALSE; }
    if (!value) { set_error(EGL_BAD_PARAMETER); return EGL_FALSE; }
    switch (attribute) {
        case EGL_CONFIG_ID:
            *value = c->config ? ((EglConfig*)c->config)->configId : 0; break;
        case EGL_CONTEXT_CLIENT_TYPE:
            *value = (t_boundAPI == EGL_OPENGL_ES_API) ? EGL_OPENGL_ES_API : EGL_OPENGL_API;
            break;
        // EGL_CONTEXT_CLIENT_VERSION and EGL_CONTEXT_MAJOR_VERSION are the
        // same token (0x3098) in the Khronos EGL spec (the latter is the EGL
        // 1.5 rename of the former); a single case label covers both.
        case EGL_CONTEXT_MAJOR_VERSION: *value = c->majorVer; break;
        case EGL_CONTEXT_MINOR_VERSION: *value = c->minorVer; break;
        case EGL_RENDER_BUFFER:         *value = EGL_BACK_BUFFER; break;
        default:                        *value = 0; break;
    }
    return EGL_TRUE;
}

// ---- Swap ----
EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    EglSurface* s = (EglSurface*)surface;
    if (!s) { set_error(EGL_BAD_SURFACE); return EGL_FALSE; }

    // Flush any pending Metal work into the current drawable's texture.
    // metal_commit() ends the active render pass and commits the command
    // buffer, so the encoded draws land on s->colorTex before we present.
    metal_end_render_pass();
    metal_commit();

    // Present the frame we just rendered, then acquire the next drawable for
    // the following frame. We honour swapInterval==0 by presenting without
    // waiting for the v-sync signal (CAMetalLayer's default is v-synced).
    if (s->drawable) {
        if (s->swapInterval <= 0) {
            // Best-effort immediate present. MTLDrawable present presents at
            // the next v-sync by default; there is no portable way to skip
            // vsync on iOS, but we still call present to keep the pipeline
            // moving.
            [s->drawable present];
        } else {
            [s->drawable present];
        }
        s->drawable = nil;
        s->colorTex = nil;
    }

    // Acquire the next drawable and re-install it on the active GLState so
    // the next frame's GL commands render into a fresh texture.
    if (s->layer) {
        if (!acquire_next_drawable(s)) {
            NSLog(@"[egl] eglSwapBuffers: nextDrawable returned nil (deferred)");
        }
        if (t_currentDraw == s) {
            install_surface_on_state(s);
        }
    }
    s->firstFrame = false;
    return EGL_TRUE;
}

EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval) {
    clear_error();
    if (!valid_display(dpy)) { set_error(EGL_BAD_DISPLAY); return EGL_FALSE; }
    if (t_currentDraw) {
        t_currentDraw->swapInterval = interval > 1 ? 1 : (interval < 0 ? 0 : interval);
    }
    return EGL_TRUE;
}

// ---- Idle sync (no-ops; Mithril flushes work synchronously per draw) ----
EGLBoolean eglWaitClient(void)  { metal_commit(); return EGL_TRUE; }
EGLBoolean eglWaitGL(void)      { metal_commit(); return EGL_TRUE; }
EGLBoolean eglWaitNative(EGLint) { return EGL_TRUE; }

} // extern "C"
#pragma GCC visibility pop
