// Mithril-Wapper - metal/metal_pipeline.h
// Pipeline-state cache: MSL source -> MTLLibrary -> MTLRenderPipelineState,
// keyed by (program, vertex format signature, color/depth pixel formats).
#ifndef MITHRIL_METAL_PIPELINE_H
#define MITHRIL_METAL_PIPELINE_H

#include <cstdint>

#include <GL/gl.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Description of one bound vertex attribute used to build the vertex descriptor. */
struct MetalVertexAttrib {
    int     location;     /* GL attribute index */
    int     size;         /* 1..4 */
    GLenum  type;         /* GL_FLOAT, GL_UNSIGNED_BYTE, etc. */
    int     normalized;   /* 0/1 */
    int     integer;      /* 0/1 (integer attribs) */
    int     stride;
    int     offset;       /* byte offset within the bound vertex buffer */
    int     enabled;      /* 0/1 */
    GLuint  buffer_name;  /* GL VBO name backing this attrib */
};

/*
 * Compile MSL vertex + fragment source into MTLLibraries (cached on the
 * program) and build a render pipeline state matching the given vertex format
 * and framebuffer color/depth pixel formats.
 *
 *   vertex_msl / fragment_msl : MSL source strings (null-terminated)
 *   attribs / attrib_count    : enabled vertex attributes
 *   color_formats / color_count: MTLPixelFormat values for color attachments
 *   depth_format               : MTLPixelFormat for depth (0 = none)
 *   blend_enabled              : 0/1 — enable alpha blending on color attachment 0
 *   blend_src / blend_dst      : GL blend factor enums (GL_SRC_ALPHA, etc.)
 *   gl_primitive_mode          : GL primitive mode (not used for pipeline, only cache key)
 *
 * Returns id<MTLRenderPipelineState> (cached) or NULL on failure.
 */
void* metal_get_or_create_pipeline(GLuint program,
                                   const char* vertex_msl,
                                   const char* fragment_msl,
                                   const struct MetalVertexAttrib* attribs,
                                   int attrib_count,
                                   const int* color_formats,
                                   int color_count,
                                   int depth_format,
                                   int blend_enabled,
                                   GLenum blend_src,
                                   GLenum blend_dst,
                                   GLenum gl_primitive_mode);

/* Release all Metal resources owned by a program (libs + cached pipelines). */
void metal_delete_program_resources(GLuint program);

/* Compile-only helper: returns 1 if MSL compiles, 0 otherwise (used by tests). */
int metal_compile_msl(const char* msl, char* err_buf, int err_buf_size);

#ifdef __cplusplus
}
#endif

#endif // MITHRIL_METAL_PIPELINE_H
