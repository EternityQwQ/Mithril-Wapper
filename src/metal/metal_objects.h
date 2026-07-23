// Mithril-Wapper - src/metal/metal_objects.h
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

#ifdef __cplusplus
}
#endif

#endif // MITHRIL_METAL_OBJECTS_H
