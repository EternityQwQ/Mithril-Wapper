// Mithril-Wapper - metal/metal_objects.h
// C interface for managing MTLBuffer / MTLTexture objects keyed by GL names.
#ifndef MITHRIL_METAL_OBJECTS_H
#define MITHRIL_METAL_OBJECTS_H

#include <cstdint>
#include <cstddef>

#include <GL/gl.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Buffers ---- */
void* metal_get_or_create_buffer(GLuint name, const void* data, size_t size);
void  metal_buffer_upload(GLuint name, GLintptr offset, const void* data, size_t size);
void* metal_get_buffer(GLuint name);
void  metal_delete_buffer(GLuint name);

/*
 * Shared 16-byte zero-filled buffer for binding to unbound vertex attribute
 * slots (see metal_pipeline.mm vertex descriptor defaults + drawing.cpp).
 */
void* metal_get_zero_buffer(void);

/* ---- Textures ---- */
void* metal_get_or_create_texture(GLuint name, int width, int height, int depth,
                                  int levels, GLenum internal_format, GLenum target,
                                  int samples);
void  metal_texture_upload(GLuint name, int level, int x, int y, int z,
                           int w, int h, int d, GLenum format, GLenum type,
                           const void* pixels, int unpack_alignment);
void  metal_texture_set_params(GLuint name, GLint min_filter, GLint mag_filter,
                               GLint wrap_s, GLint wrap_t, GLint wrap_r,
                               const float* border_color);
void* metal_get_texture(GLuint name);
void  metal_delete_texture(GLuint name);

/* ---- Sampler helpers ---- */
void* metal_get_or_create_sampler(GLuint name, GLint min_filter, GLint mag_filter,
                                  GLint wrap_s, GLint wrap_t, GLint wrap_r,
                                  const float* border_color);

/*
 * Return the MTLPixelFormat (as an int) that corresponds to a GL internal
 * format. Returns 0 when the format is unsupported. Used by the drawing path
 * to describe pipeline color/depth attachment formats.
 */
int metal_pixel_format_for_gl(GLenum internal_format);

/*
 * Query the actual MTLPixelFormat of a Metal texture handle (as an int).
 * Used by the drawing path to get the real pixel format of the EGL default
 * framebuffer's depth attachment (which is a raw MTLTexture, not tracked
 * in the GL texture table). Returns 0 if the handle is null.
 */
int metal_texture_pixel_format(void* texture_handle);

#ifdef __cplusplus
}
#endif

#endif // MITHRIL_METAL_OBJECTS_H
