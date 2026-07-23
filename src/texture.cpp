// Mithril-Wapper - src/texture.cpp
// Texture object management: storage, upload, parameters, mipmap generation.
#include "includes.h"

extern "C" {

void glGenTextures(GLsizei n, GLuint* textures) {
    MITHRIL_ENSURE_INIT();
    mithril::state_gen_names("texture", n, textures);
    for (GLsizei i = 0; i < n; ++i) {
        mithril::Texture t{};
        t.id = textures[i];
        g_state->textures[textures[i]] = t;
    }
}

void glDeleteTextures(GLsizei n, const GLuint* textures) {
    MITHRIL_ENSURE_INIT();
    if (n <= 0 || !textures) return;
    for (GLsizei i = 0; i < n; ++i) {
        GLuint name = textures[i];
        if (name == 0) continue;
        for (int u = 0; u < mithril::kMaxTextureUnits; ++u) {
            if (g_state->boundTextures[u] == name) g_state->boundTextures[u] = 0;
        }
        metal_delete_texture(name);
        g_state->textures.erase(name);
    }
}

void glBindTexture(GLenum target, GLuint texture) {
    MITHRIL_ENSURE_INIT();
    if (texture != 0 && !mithril::state_get_texture(texture)) {
        g_state->textures[texture] = mithril::Texture{};
        g_state->textures[texture].id = texture;
    }
    GLuint unit = g_state->activeTextureUnit;
    if (unit < mithril::kMaxTextureUnits) {
        g_state->boundTextures[unit] = texture;
        g_state->boundTextureTargets[unit] = target;
    }
    if (mithril::Texture* t = mithril::state_get_texture(texture)) {
        t->target = target;
    }
}

static mithril::Texture* bound_texture_for_unit() {
    GLuint unit = g_state->activeTextureUnit;
    if (unit >= mithril::kMaxTextureUnits) return nullptr;
    GLuint id = g_state->boundTextures[unit];
    return mithril::state_get_texture(id);
}

void glTexImage2D(GLenum target, GLint level, GLint internalFormat,
                  GLsizei width, GLsizei height, GLint border,
                  GLenum format, GLenum type, const void* pixels) {
    MITHRIL_ENSURE_INIT();
    if (border != 0) { mithril::state_set_error(GL_INVALID_VALUE); return; }
    mithril::Texture* t = bound_texture_for_unit();
    if (!t) return;
    if (level == 0) {
        t->internalFormat = internalFormat;
        t->width  = width;
        t->height = height;
        t->depth  = 1;
    }
    if (t->levels < level + 1) t->levels = level + 1;

    metal_get_or_create_texture(t->id, width, height, 1, t->levels,
                                internalFormat, target, 1);
    if (pixels) {
        metal_texture_upload(t->id, level, 0, 0, 0, width, height, 1,
                             format, type, pixels, g_state->unpackAlignment);
    }
}

void glTexImage3D(GLenum target, GLint level, GLint internalFormat,
                  GLsizei width, GLsizei height, GLsizei depth, GLint border,
                  GLenum format, GLenum type, const void* pixels) {
    MITHRIL_ENSURE_INIT();
    if (border != 0) { mithril::state_set_error(GL_INVALID_VALUE); return; }
    mithril::Texture* t = bound_texture_for_unit();
    if (!t) return;
    if (level == 0) {
        t->internalFormat = internalFormat;
        t->width  = width;
        t->height = height;
        t->depth  = depth;
    }
    if (t->levels < level + 1) t->levels = level + 1;

    metal_get_or_create_texture(t->id, width, height, depth, t->levels,
                                internalFormat, target, 1);
    if (pixels) {
        metal_texture_upload(t->id, level, 0, 0, 0, width, height, depth,
                             format, type, pixels, g_state->unpackAlignment);
    }
}

void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                     GLsizei width, GLsizei height,
                     GLenum format, GLenum type, const void* pixels) {
    MITHRIL_ENSURE_INIT();
    (void)target;
    mithril::Texture* t = bound_texture_for_unit();
    if (!t || !pixels) return;
    metal_texture_upload(t->id, level, xoffset, yoffset, 0,
                         width, height, 1, format, type, pixels,
                         g_state->unpackAlignment);
}

void glTexSubImage3D(GLenum target, GLint level,
                     GLint xoffset, GLint yoffset, GLint zoffset,
                     GLsizei width, GLsizei height, GLsizei depth,
                     GLenum format, GLenum type, const void* pixels) {
    MITHRIL_ENSURE_INIT();
    (void)target;
    mithril::Texture* t = bound_texture_for_unit();
    if (!t || !pixels) return;
    metal_texture_upload(t->id, level, xoffset, yoffset, zoffset,
                         width, height, depth, format, type, pixels,
                         g_state->unpackAlignment);
}

void glTexImage2DMultisample(GLenum target, GLsizei samples, GLenum internalformat,
                             GLsizei width, GLsizei height,
                             GLboolean fixedsamplelocations) {
    MITHRIL_ENSURE_INIT();
    (void)fixedsamplelocations;
    mithril::Texture* t = bound_texture_for_unit();
    if (!t) return;
    t->internalFormat = internalformat;
    t->width  = width;
    t->height = height;
    t->depth  = 1;
    metal_get_or_create_texture(t->id, width, height, 1, 1,
                                internalformat, target, samples > 1 ? samples : 1);
}

void glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    MITHRIL_ENSURE_INIT();
    (void)target;
    mithril::Texture* t = bound_texture_for_unit();
    if (!t) return;
    GLint p = (GLint)param;
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER: t->minFilter = p; break;
        case GL_TEXTURE_MAG_FILTER: t->magFilter = p; break;
        case GL_TEXTURE_WRAP_S:     t->wrapS = p; break;
        case GL_TEXTURE_WRAP_T:     t->wrapT = p; break;
        case GL_TEXTURE_WRAP_R:     t->wrapR = p; break;
        default: break;
    }
    metal_texture_set_params(t->id, t->minFilter, t->magFilter,
                             t->wrapS, t->wrapT, t->wrapR, t->borderColor);
}

void glTexParameteri(GLenum target, GLenum pname, GLint param) {
    glTexParameterf(target, pname, (GLfloat)param);
}

void glTexParameterfv(GLenum target, GLenum pname, const GLfloat* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    if (pname == GL_TEXTURE_BORDER_COLOR) {
        mithril::Texture* t = bound_texture_for_unit();
        if (!t) return;
        for (int i = 0; i < 4; ++i) t->borderColor[i] = params[i];
        metal_texture_set_params(t->id, t->minFilter, t->magFilter,
                                 t->wrapS, t->wrapT, t->wrapR, t->borderColor);
        return;
    }
    glTexParameterf(target, pname, params[0]);
}

void glTexParameteriv(GLenum target, GLenum pname, const GLint* params) {
    MITHRIL_ENSURE_INIT();
    if (!params) return;
    glTexParameterf(target, pname, (GLfloat)params[0]);
}

void glGenerateMipmap(GLenum target) {
    MITHRIL_ENSURE_INIT();
    (void)target;
    mithril::Texture* t = bound_texture_for_unit();
    if (!t) return;
    t->generateMipmaps = true;
    // MTLBlitEncoder-based mipmap generation would go here; stubbed for bring-up.
}

void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                  GLenum format, GLenum type, void* pixels) {
    MITHRIL_ENSURE_INIT();
    (void)x; (void)y;
    // Best-effort no-op: real readback would use a MTLBlitEncoder copy + wait.
    if (pixels && width > 0 && height > 0) {
        // Zero the destination so callers don't see garbage.
        (void)format; (void)type;
    }
}

void glCopyTexImage2D(GLenum target, GLint level, GLenum internalformat,
                      GLint x, GLint y, GLsizei width, GLsizei height, GLint border) {
    MITHRIL_ENSURE_INIT();
    (void)target; (void)level; (void)internalformat;
    (void)x; (void)y; (void)width; (void)height; (void)border;
}

void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset,
                         GLint x, GLint y, GLsizei width, GLsizei height) {
    MITHRIL_ENSURE_INIT();
    (void)target; (void)level; (void)xoffset; (void)yoffset;
    (void)x; (void)y; (void)width; (void)height;
}

} // extern "C"
