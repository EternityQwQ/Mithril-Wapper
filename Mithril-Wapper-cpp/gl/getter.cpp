// Mithril-Wapper - getter.cpp
// GL state getters: glGet*v, glGetString / glGetStringi, glGetError.
#include "includes.h"

/* ---- GPU info (Metal backend) ----
 * On Metal builds the GL_RENDERER string is built from the live MTLDevice so
 * Minecraft's F3 screen and crash reports show real GPU info. The helper is
 * implemented in getter_gpu.mm (Objective-C++) so it can call MTLDevice
 * directly. On non-Apple builds a static fallback is used.
 */
#if MITHRIL_METAL
extern "C" const char* mithril_get_gpu_renderer_string(void);
#endif

/* ---- Strings ---- */
// Vendor string lists the project developers (mirrors MobileGlues' pattern of
// putting the maintainer names in GL_VENDOR).
static const char* kVendor   = "EternityQwQ, yitenchen123";
#if MITHRIL_METAL
// GL_RENDERER is built on first query from the live MTLDevice (see above).
// Falls back to the static string if Metal is unavailable.
#else
static const char* kRenderer = "Mithril-Wapper (Metal backend)";
#endif
// Target desktop GL 3.3 Core Profile (the minimum required by Minecraft:
// Java Edition's modern pipeline). The Metal backend implements the subset
// of Core Profile 3.3 actually exercised by the host.
static const char* kVersion  = "3.3.0 Mithril-Wapper 1.0 (Metal)";
static const char* kShadingLangVer = "3.30";

// Sparse extensions list — applications usually only need the count and the
// GL_ARB_* strings they probe for. Kept within the GL 3.3 Core Profile scope
// (no GL 4.x-only extensions).
static const char* kExtensions[] = {
    "GL_ARB_vertex_buffer_object",
    "GL_ARB_vertex_array_object",
    "GL_ARB_framebuffer_object",
    "GL_ARB_shader_objects",
    "GL_ARB_vertex_shader",
    "GL_ARB_fragment_shader",
    "GL_ARB_geometry_shader4",
    "GL_ARB_uniform_buffer_object",
    "GL_ARB_draw_elements_base_vertex",
    "GL_ARB_instanced_arrays",
    "GL_ARB_texture_multisample",
    "GL_ARB_texture_buffer_object",
    "GL_ARB_texture_cube_map_array",
    "GL_ARB_texture_rg",
    "GL_ARB_texture_float",
    "GL_ARB_depth_buffer_float",
    "GL_ARB_depth_texture",
    "GL_ARB_depth_clamp",
    "GL_ARB_seamless_cube_map",
    "GL_ARB_seamless_cubemap_per_texture",
    "GL_ARB_sync",
    "GL_ARB_internalformat_query",
    "GL_ARB_internalformat_query2",
    "GL_ARB_robustness",
    "GL_KHR_debug",
};

extern "C" {

GLenum glGetError(void) {
    MITHRIL_ENSURE_INIT();
    return mithril::state_take_error();
}

void glGetBooleanv(GLenum pname, GLboolean* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    switch (pname) {
        case GL_DEPTH_WRITEMASK: *params = g_state->depthMask ? GL_TRUE : GL_FALSE; break;
        case GL_DEPTH_TEST:      *params = g_state->depthTest ? GL_TRUE : GL_FALSE; break;
        case GL_BLEND:           *params = g_state->blend ? GL_TRUE : GL_FALSE; break;
        case GL_STENCIL_TEST:    *params = g_state->stencilTest ? GL_TRUE : GL_FALSE; break;
        case GL_CULL_FACE:       *params = g_state->cullFace ? GL_TRUE : GL_FALSE; break;
        case GL_SCISSOR_TEST:    *params = g_state->scissorTest ? GL_TRUE : GL_FALSE; break;
        case GL_DITHER:          *params = g_state->dither ? GL_TRUE : GL_FALSE; break;
        case GL_COLOR_WRITEMASK:
            params[0] = g_state->colorMask[0] ? GL_TRUE : GL_FALSE;
            params[1] = g_state->colorMask[1] ? GL_TRUE : GL_FALSE;
            params[2] = g_state->colorMask[2] ? GL_TRUE : GL_FALSE;
            params[3] = g_state->colorMask[3] ? GL_TRUE : GL_FALSE;
            break;
        default: *params = GL_FALSE; break;
    }
}

void glGetIntegerv(GLenum pname, GLint* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    switch (pname) {
        case GL_MAX_TEXTURE_SIZE:             *params = 16384; break;
        case GL_MAX_3D_TEXTURE_SIZE:          *params = 2048; break;
        case GL_MAX_CUBE_MAP_TEXTURE_SIZE:    *params = 16384; break;
        case GL_MAX_ARRAY_TEXTURE_LAYERS:     *params = 2048; break;
        case GL_MAX_TEXTURE_IMAGE_UNITS:      *params = 32; break;
        case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS:*params = 32; break;
        case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS:*params = 80; break;
        case GL_MAX_VERTEX_ATTRIBS:           *params = mithril::kMaxVertexAttribs; break;
        case GL_MAX_VERTEX_UNIFORM_COMPONENTS:*params = 4096; break;
        case GL_MAX_FRAGMENT_UNIFORM_COMPONENTS:*params = 4096; break;
        case GL_MAX_VIEWPORT_DIMS:            params[0] = 16384; params[1] = 16384; break;
        case GL_MAX_RENDERBUFFER_SIZE:        *params = 16384; break;
        case GL_MAX_ELEMENTS_VERTICES:        *params = 1 << 24; break;
        case GL_MAX_ELEMENTS_INDICES:         *params = 1 << 24; break;
        case GL_SUBPIXEL_BITS:                *params = 4; break;
        case GL_RED_BITS:                     *params = 8; break;
        case GL_GREEN_BITS:                   *params = 8; break;
        case GL_BLUE_BITS:                    *params = 8; break;
        case GL_ALPHA_BITS:                   *params = 8; break;
        case GL_DEPTH_BITS:                   *params = 24; break;
        case GL_STENCIL_BITS:                 *params = 8; break;
        case GL_NUM_EXTENSIONS:
            *params = (GLint)(sizeof(kExtensions)/sizeof(kExtensions[0]));
            break;
        case GL_MAJOR_VERSION:                *params = 3; break;
        case GL_MINOR_VERSION:                *params = 3; break;
        case GL_CONTEXT_FLAGS:                *params = 0; break;
        case GL_CONTEXT_PROFILE_MASK:         *params = GL_CONTEXT_CORE_PROFILE_BIT; break;
        case GL_DOUBLEBUFFER:                 *params = GL_TRUE; break;
        case GL_STEREO:                       *params = GL_FALSE; break;
        case GL_MAX_DRAW_BUFFERS:             *params = 8; break;
        case GL_MAX_COLOR_ATTACHMENTS:        *params = mithril::kMaxColorAttachments; break;
        case GL_MAX_TEXTURE_UNITS:            *params = mithril::kMaxTextureUnits; break;
        case GL_ACTIVE_TEXTURE:               *params = (GLint)(GL_TEXTURE0 + g_state->activeTextureUnit); break;
        case GL_ARRAY_BUFFER_BINDING:         *params = (GLint)g_state->currentArrayBuffer; break;
        case GL_ELEMENT_ARRAY_BUFFER_BINDING: *params = (GLint)g_state->currentIndexBuffer; break;
        case GL_UNIFORM_BUFFER_BINDING:       *params = (GLint)g_state->currentUniformBuffer; break;
        case GL_VERTEX_ARRAY_BINDING:         *params = (GLint)g_state->currentVAO; break;
        case GL_CURRENT_PROGRAM:              *params = (GLint)g_state->currentProgram; break;
        // GL_DRAW_FRAMEBUFFER_BINDING and GL_FRAMEBUFFER_BINDING share the same
        // numeric value (0x8CA6) per the GL spec, so a single case covers both.
        case GL_FRAMEBUFFER_BINDING:          *params = (GLint)g_state->currentDrawFBO; break;
        case GL_READ_FRAMEBUFFER_BINDING:     *params = (GLint)g_state->currentReadFBO; break;
        case GL_VIEWPORT:
            params[0] = g_state->viewportX; params[1] = g_state->viewportY;
            params[2] = g_state->viewportW; params[3] = g_state->viewportH;
            break;
        case GL_SCISSOR_BOX:
            params[0] = g_state->scissorX; params[1] = g_state->scissorY;
            params[2] = g_state->scissorW; params[3] = g_state->scissorH;
            break;
        case GL_COLOR_CLEAR_VALUE:
            for (int i = 0; i < 4; ++i) params[i] = (GLint)g_state->clearColor[i];
            break;
        case GL_DEPTH_FUNC:                   *params = (GLint)g_state->depthFunc; break;
        case GL_CULL_FACE_MODE:               *params = (GLint)g_state->cullMode; break;
        case GL_FRONT_FACE:                   *params = (GLint)g_state->frontFace; break;
        case GL_POLYGON_MODE:                 params[0] = (GLint)g_state->polygonModeFront;
                                                 params[1] = (GLint)g_state->polygonModeBack; break;
        case GL_LINE_WIDTH:                   *params = (GLint)g_state->lineWidth; break;
        case GL_POINT_SIZE:                   *params = (GLint)g_state->pointSize; break;
        case GL_UNPACK_ALIGNMENT:             *params = g_state->unpackAlignment; break;
        case GL_PACK_ALIGNMENT:               *params = g_state->packAlignment; break;
        case GL_UNPACK_ROW_LENGTH:            *params = g_state->unpackRowLength; break;
        case GL_UNPACK_IMAGE_HEIGHT:          *params = g_state->unpackImageHeight; break;
        case GL_TEXTURE_BINDING_2D:           *params = (GLint)g_state->boundTextures[g_state->activeTextureUnit]; break;
        case GL_BLEND_SRC_RGB:                *params = (GLint)g_state->blendSrcRGB; break;
        case GL_BLEND_DST_RGB:                *params = (GLint)g_state->blendDstRGB; break;
        case GL_BLEND_SRC_ALPHA:              *params = (GLint)g_state->blendSrcA; break;
        case GL_BLEND_DST_ALPHA:              *params = (GLint)g_state->blendDstA; break;
        case GL_BLEND_EQUATION_RGB:           *params = (GLint)g_state->blendEqRGB; break;
        case GL_BLEND_EQUATION_ALPHA:         *params = (GLint)g_state->blendEqA; break;
        case GL_STENCIL_WRITEMASK:            *params = (GLint)g_state->stencilMask; break;
        case GL_STENCIL_BACK_WRITEMASK:       *params = (GLint)g_state->stencilBackMask; break;
        case GL_STENCIL_FUNC:                 *params = (GLint)g_state->stencilFunc; break;
        case GL_STENCIL_REF:                  *params = g_state->stencilRef; break;
        case GL_STENCIL_VALUE_MASK:           *params = (GLint)g_state->stencilValueMask; break;
        case GL_STENCIL_FAIL:                 *params = (GLint)g_state->stencilSfail; break;
        case GL_STENCIL_PASS_DEPTH_FAIL:      *params = (GLint)g_state->stencilDpfail; break;
        case GL_STENCIL_PASS_DEPTH_PASS:      *params = (GLint)g_state->stencilDppass; break;
        case GL_SHADING_LANGUAGE_VERSION:     *params = 330; break;
        default:                              *params = 0; break;
    }
}

void glGetFloatv(GLenum pname, GLfloat* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    GLint ip[4] = {0,0,0,0};
    glGetIntegerv(pname, ip);
    switch (pname) {
        case GL_COLOR_CLEAR_VALUE:
            for (int i = 0; i < 4; ++i) params[i] = g_state->clearColor[i];
            return;
        case GL_LINE_WIDTH:        *params = g_state->lineWidth; return;
        case GL_POINT_SIZE:        *params = g_state->pointSize; return;
        case GL_POLYGON_OFFSET_FACTOR: *params = g_state->polygonOffsetFactor; return;
        case GL_POLYGON_OFFSET_UNITS:  *params = g_state->polygonOffsetUnits;  return;
        case GL_BLEND_COLOR:
            for (int i = 0; i < 4; ++i) params[i] = g_state->blendColor[i];
            return;
        default:
            for (int i = 0; i < 4; ++i) params[i] = (GLfloat)ip[i];
            return;
    }
}

void glGetDoublev(GLenum pname, GLdouble* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    GLfloat f[4] = {0,0,0,0};
    glGetFloatv(pname, f);
    for (int i = 0; i < 4; ++i) params[i] = (GLdouble)f[i];
}

void glGetInteger64v(GLenum pname, GLint64* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    GLint ip[4] = {0,0,0,0};
    glGetIntegerv(pname, ip);
    for (int i = 0; i < 4; ++i) params[i] = (GLint64)ip[i];
}

void glGetIntegeri_v(GLenum pname, GLuint index, GLint* params) {
    MITHRIL_ENSURE_INIT();
    (void)pname; (void)index;
    if (params) *params = 0;
}

const GLubyte* glGetString(GLenum name) {
    MITHRIL_ENSURE_INIT();
    switch (name) {
        case GL_VENDOR:                   return (const GLubyte*)kVendor;
        case GL_RENDERER:
#if MITHRIL_METAL
            return (const GLubyte*)mithril_get_gpu_renderer_string();
#else
            return (const GLubyte*)kRenderer;
#endif
        case GL_VERSION:                  return (const GLubyte*)kVersion;
        case GL_SHADING_LANGUAGE_VERSION: return (const GLubyte*)kShadingLangVer;
        case GL_EXTENSIONS: {
            // Concatenate into a single space-separated string.
            static std::string all;
            if (all.empty()) {
                for (size_t i = 0; i < sizeof(kExtensions)/sizeof(kExtensions[0]); ++i) {
                    if (i) all += " ";
                    all += kExtensions[i];
                }
            }
            return (const GLubyte*)all.c_str();
        }
        default: return nullptr;
    }
}

const GLubyte* glGetStringi(GLenum name, GLuint index) {
    MITHRIL_ENSURE_INIT();
    if (name != GL_EXTENSIONS) return nullptr;
    if (index >= sizeof(kExtensions)/sizeof(kExtensions[0])) return nullptr;
    return (const GLubyte*)kExtensions[index];
}

} // extern "C"
