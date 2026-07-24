// Mithril-Wapper - framebuffer.cpp
// Framebuffer objects and attachment resolution.
#include "includes.h"
#include "framebuffer.h"

extern "C" {

void glGenFramebuffers(GLsizei n, GLuint* framebuffers) {
    MITHRIL_ENSURE_INIT();
    if (n <= 0 || !framebuffers) return;
    for (GLsizei i = 0; i < n; ++i) {
        GLuint name = g_state->nextName++;
        g_state->framebuffers[name] = mithril::Framebuffer{};
        g_state->framebuffers[name].id = name;
        g_state->framebuffers[name].drawBuffers[0] = GL_COLOR_ATTACHMENT0;
        g_state->framebuffers[name].drawBufferCount = 1;
        g_state->framebuffers[name].readBuffer = GL_COLOR_ATTACHMENT0;
        framebuffers[i] = name;
    }
}

void glDeleteFramebuffers(GLsizei n, const GLuint* framebuffers) {
    MITHRIL_ENSURE_INIT();
    if (n <= 0 || !framebuffers) return;
    for (GLsizei i = 0; i < n; ++i) {
        GLuint name = framebuffers[i];
        if (name == 0) continue;
        if (g_state->currentDrawFBO == name) g_state->currentDrawFBO = 0;
        if (g_state->currentReadFBO == name) g_state->currentReadFBO = 0;
        g_state->framebuffers.erase(name);
    }
}

void glBindFramebuffer(GLenum target, GLuint framebuffer) {
    MITHRIL_ENSURE_INIT();
    if (framebuffer != 0 && g_state->framebuffers.find(framebuffer) == g_state->framebuffers.end()) {
        g_state->framebuffers[framebuffer] = mithril::Framebuffer{};
        g_state->framebuffers[framebuffer].id = framebuffer;
        g_state->framebuffers[framebuffer].drawBuffers[0] = GL_COLOR_ATTACHMENT0;
        g_state->framebuffers[framebuffer].drawBufferCount = 1;
        g_state->framebuffers[framebuffer].readBuffer = GL_COLOR_ATTACHMENT0;
    }
    if (target == GL_READ_FRAMEBUFFER || target == GL_FRAMEBUFFER) {
        g_state->currentReadFBO = framebuffer;
    }
    if (target == GL_DRAW_FRAMEBUFFER || target == GL_FRAMEBUFFER) {
        g_state->currentDrawFBO = framebuffer;
    }
}

void glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget,
                            GLuint texture, GLint level) {
    MITHRIL_ENSURE_INIT();
    mithril::Framebuffer* fbo = (target == GL_READ_FRAMEBUFFER)
        ? mithril::state_get_framebuffer(g_state->currentReadFBO)
        : mithril::state_get_framebuffer(g_state->currentDrawFBO);
    if (!fbo) return;
    mithril::FBOAttachment a{};
    a.texture = texture;
    a.textarget = textarget;
    a.level = level;
    if (attachment >= GL_COLOR_ATTACHMENT0 && attachment <= GL_COLOR_ATTACHMENT7) {
        fbo->colors[attachment - GL_COLOR_ATTACHMENT0] = a;
    } else if (attachment == GL_DEPTH_ATTACHMENT) {
        fbo->depth = a;
    } else if (attachment == GL_STENCIL_ATTACHMENT) {
        fbo->stencil = a;
    } else if (attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        fbo->depth = a; fbo->stencil = a;
    }
}

void glFramebufferTextureLayer(GLenum target, GLenum attachment, GLuint texture,
                               GLint level, GLint layer) {
    MITHRIL_ENSURE_INIT();
    mithril::Framebuffer* fbo = (target == GL_READ_FRAMEBUFFER)
        ? mithril::state_get_framebuffer(g_state->currentReadFBO)
        : mithril::state_get_framebuffer(g_state->currentDrawFBO);
    if (!fbo) return;
    mithril::FBOAttachment a{};
    a.texture = texture;
    a.level = level;
    a.layer = layer;
    a.layered = true;
    if (attachment >= GL_COLOR_ATTACHMENT0 && attachment <= GL_COLOR_ATTACHMENT7) {
        fbo->colors[attachment - GL_COLOR_ATTACHMENT0] = a;
    } else if (attachment == GL_DEPTH_ATTACHMENT) {
        fbo->depth = a;
    } else if (attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        fbo->depth = a; fbo->stencil = a;
    }
}

void glFramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level) {
    MITHRIL_ENSURE_INIT();
    mithril::Framebuffer* fbo = (target == GL_READ_FRAMEBUFFER)
        ? mithril::state_get_framebuffer(g_state->currentReadFBO)
        : mithril::state_get_framebuffer(g_state->currentDrawFBO);
    if (!fbo) return;
    mithril::FBOAttachment a{};
    a.texture = texture;
    a.level = level;
    a.layered = true;
    if (attachment >= GL_COLOR_ATTACHMENT0 && attachment <= GL_COLOR_ATTACHMENT7) {
        fbo->colors[attachment - GL_COLOR_ATTACHMENT0] = a;
    } else if (attachment == GL_DEPTH_ATTACHMENT) {
        fbo->depth = a;
    } else if (attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        fbo->depth = a; fbo->stencil = a;
    }
}

void glDrawBuffers(GLsizei n, const GLenum* bufs) {
    MITHRIL_ENSURE_INIT();
    mithril::Framebuffer* fbo = mithril::state_get_framebuffer(g_state->currentDrawFBO);
    if (!fbo || n <= 0 || !bufs) return;
    for (int i = 0; i < 8; ++i) fbo->drawBuffers[i] = GL_NONE;
    fbo->drawBufferCount = 0;
    for (GLsizei i = 0; i < n && i < 8; ++i) {
        fbo->drawBuffers[i] = bufs[i];
        if (bufs[i] != GL_NONE) fbo->drawBufferCount = i + 1;
    }
}

void glDrawBuffer(GLenum mode) {
    MITHRIL_ENSURE_INIT();
    mithril::Framebuffer* fbo = mithril::state_get_framebuffer(g_state->currentDrawFBO);
    if (!fbo) return;
    for (int i = 0; i < 8; ++i) fbo->drawBuffers[i] = GL_NONE;
    if (mode == GL_FRONT || mode == GL_BACK || mode == GL_NONE) {
        fbo->drawBuffers[0] = (mode == GL_NONE) ? GL_NONE : GL_COLOR_ATTACHMENT0;
        fbo->drawBufferCount = (mode == GL_NONE) ? 0 : 1;
    } else if (mode >= GL_COLOR_ATTACHMENT0 && mode <= GL_COLOR_ATTACHMENT7) {
        fbo->drawBuffers[0] = mode;
        fbo->drawBufferCount = 1;
    }
}

void glReadBuffer(GLenum mode) {
    MITHRIL_ENSURE_INIT();
    mithril::Framebuffer* fbo = mithril::state_get_framebuffer(g_state->currentReadFBO);
    if (fbo) fbo->readBuffer = mode;
}

GLenum glCheckFramebufferStatus(GLenum target) {
    MITHRIL_ENSURE_INIT();
    return GL_FRAMEBUFFER_COMPLETE;
}

void glBlitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                       GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                       GLbitfield mask, GLenum filter) {
    MITHRIL_ENSURE_INIT();
    (void)filter; // GL_LINEAR/GL_NEAREST — Metal blit is 1:1 only (no scaling).

    // We only implement the colour blit (the common Minecraft path: copy an
    // off-screen FBO's colour attachment to the default framebuffer). Depth
    // and stencil blits are rare in MC and would need a depth-specific path.
    if (!(mask & GL_COLOR_BUFFER_BIT)) return;

    // Resolve the READ framebuffer's colour attachment 0.
    void* srcTex = nullptr;
    int srcW = 0, srcH = 0;
    if (g_state->currentReadFBO == 0) {
        // Reading from the default framebuffer (drawable).
        srcTex = g_state->eglDefaultColor;
        srcW = g_state->eglDefaultWidth;
        srcH = g_state->eglDefaultHeight;
    } else {
        mithril::Framebuffer* rfbo = mithril::state_get_framebuffer(g_state->currentReadFBO);
        if (rfbo && rfbo->colors[0].texture) {
            srcTex = metal_get_texture(rfbo->colors[0].texture);
            mithril::Texture* t = mithril::state_get_texture(rfbo->colors[0].texture);
            if (t) { srcW = t->width; srcH = t->height; }
        }
    }

    // Resolve the DRAW framebuffer's colour attachment 0.
    void* dstTex = nullptr;
    int dstW = 0, dstH = 0;
    if (g_state->currentDrawFBO == 0) {
        dstTex = g_state->eglDefaultColor;
        dstW = g_state->eglDefaultWidth;
        dstH = g_state->eglDefaultHeight;
    } else {
        mithril::Framebuffer* dfbo = mithril::state_get_framebuffer(g_state->currentDrawFBO);
        if (dfbo && dfbo->colors[0].texture) {
            dstTex = metal_get_texture(dfbo->colors[0].texture);
            mithril::Texture* t = mithril::state_get_texture(dfbo->colors[0].texture);
            if (t) { dstW = t->width; dstH = t->height; }
        }
    }

    if (!srcTex || !dstTex || srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return;

    // GL framebuffer coordinates are bottom-left origin; Metal texture
    // coordinates are top-left origin. Flip the Y coordinates.
    int s_x = (srcX0 < srcX1) ? srcX0 : srcX1;
    int s_w = (srcX1 > srcX0) ? (srcX1 - srcX0) : (srcX0 - srcX1);
    int s_y = srcH - ((srcY0 > srcY1) ? srcY0 : srcY1);  // flip: top = srcH - max(y)
    int s_h = (srcY1 > srcY0) ? (srcY1 - srcY0) : (srcY0 - srcY1);

    int d_x = (dstX0 < dstX1) ? dstX0 : dstX1;
    int d_w = (dstX1 > dstX0) ? (dstX1 - dstX0) : (dstX0 - dstX1);
    int d_y = dstH - ((dstY0 > dstY1) ? dstY0 : dstY1);
    int d_h = (dstY1 > dstY0) ? (dstY1 - dstY0) : (dstY0 - dstY1);

    // Clamp to source/dest bounds to avoid Metal validation errors.
    if (s_x < 0) { s_w += s_x; d_x -= s_x; d_w += s_x; s_x = 0; }
    if (s_y < 0) { s_h += s_y; d_y -= s_y; d_h += s_y; s_y = 0; }
    if (s_x + s_w > srcW) s_w = srcW - s_x;
    if (s_y + s_h > srcH) s_h = srcH - s_y;
    if (d_x + d_w > dstW) d_w = dstW - d_x;
    if (d_y + d_h > dstH) d_h = dstH - d_y;
    if (s_w <= 0 || s_h <= 0 || d_w <= 0 || d_h <= 0) return;

    // For 1:1 blits (no scaling), Metal's copyFromTexture works directly.
    // For scaled blits (s_w != d_w), we fall back to rendering a textured quad
    // — but MC almost always uses 1:1 blits, so the blit encoder suffices.
    if (s_w == d_w && s_h == d_h) {
        metal_blit_texture(srcTex, dstTex, s_x, s_y, s_w, s_h, d_x, d_y, 0, 0);
    }
    // TODO: scaled blit via a fullscreen textured quad when s_w != d_w.
}

/* Renderbuffers are minimally supported (used rarely by MC Java). */
void glGenRenderbuffers(GLsizei n, GLuint* rbs) {
    MITHRIL_ENSURE_INIT();
    if (n <= 0 || !rbs) return;
    for (GLsizei i = 0; i < n; ++i) rbs[i] = g_state->nextName++;
}
void glDeleteRenderbuffers(GLsizei, const GLuint*) { MITHRIL_ENSURE_INIT(); }
void glBindRenderbuffer(GLenum, GLuint) { MITHRIL_ENSURE_INIT(); }
void glRenderbufferStorage(GLenum, GLenum, GLsizei, GLsizei) { MITHRIL_ENSURE_INIT(); }
void glRenderbufferStorageMultisample(GLenum, GLsizei, GLenum, GLsizei, GLsizei) { MITHRIL_ENSURE_INIT(); }
void glFramebufferRenderbuffer(GLenum, GLenum, GLenum, GLuint) { MITHRIL_ENSURE_INIT(); }

} // extern "C"

namespace mithril {

int collect_draw_fbo_attachments(void* out_color[8], void** out_depth,
                                 int* out_w, int* out_h) {
    for (int i = 0; i < 8; ++i) out_color[i] = nullptr;
    *out_depth = nullptr;
    if (out_w) *out_w = g_state->viewportW;
    if (out_h) *out_h = g_state->viewportH;

    /*
     * EGL-backed default framebuffer: when an EGLSurface is current, the
     * CAMetalLayer drawable's MTLTexture is installed on the GLState. GL
     * commands against framebuffer 0 render straight into the on-screen
     * drawable. EGL swaps the texture per-frame (eglSwapBuffers acquires the
     * next drawable and replaces this pointer).
     */
    if (g_state->currentDrawFBO == 0 && g_state->eglDefaultColor) {
        out_color[0] = g_state->eglDefaultColor;
        if (g_state->eglDefaultDepth) *out_depth = g_state->eglDefaultDepth;
        if (g_state->eglDefaultWidth > 0 && out_w) *out_w = g_state->eglDefaultWidth;
        if (g_state->eglDefaultHeight > 0 && out_h) *out_h = g_state->eglDefaultHeight;
        return 1;
    }

    Framebuffer* fbo = state_get_framebuffer(g_state->currentDrawFBO);
    if (!fbo) return 0;

    int count = 0;
    int w = 0, h = 0;
    for (int i = 0; i < 8; ++i) {
        if (i >= fbo->drawBufferCount) break;
        if (fbo->drawBuffers[i] == GL_NONE) break;
        GLuint tex = fbo->colors[i].texture;
        if (tex == 0) { out_color[i] = nullptr; continue; }
        void* mt = metal_get_texture(tex);
        out_color[i] = mt;
        if (mt) { count = i + 1; }
        if (w == 0) {
            Texture* t = state_get_texture(tex);
            if (t) { w = t->width; h = t->height; }
        }
    }
    if (fbo->depth.texture) {
        *out_depth = metal_get_texture(fbo->depth.texture);
        if (w == 0) {
            Texture* t = state_get_texture(fbo->depth.texture);
            if (t) { w = t->width; h = t->height; }
        }
    }
    if (w > 0 && out_w) *out_w = w;
    if (h > 0 && out_h) *out_h = h;
    return count;
}

} // namespace mithril
