// Mithril-Wapper - metal/metal_context.h
// C interface to the Metal device / command queue / render-pass lifecycle.
// Implemented in metal_context.mm. All handles are opaque void* (id<MTL...>).
#ifndef MITHRIL_METAL_CONTEXT_H
#define MITHRIL_METAL_CONTEXT_H

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/* One-time init: create MTLCreateSystemDefaultDevice() + a command queue. */
void metal_init(void);

void* metal_device(void);          /* id<MTLDevice>     (may be NULL on non-Apple) */
void* metal_command_queue(void);   /* id<MTLCommandQueue> */

/* Clear values applied to the load action of the next render pass. */
void metal_set_clear_color(float r, float g, float b, float a);
void metal_set_clear_depth(double d);
void metal_set_clear_stencil(int s);

/* Load action for the next pass: Clear (glClear) or Load (draw pass). */
void metal_set_load_clear(void);
void metal_set_load_load(void);

/*
 * Set per-attachment load actions for the next render pass, based on the GL
 * glClear mask. GL_COLOR_BUFFER_BIT -> Clear color, GL_DEPTH_BUFFER_BIT ->
 * Clear depth, GL_STENCIL_BUFFER_BIT -> Clear stencil. Attachments whose bit
 * is NOT set use Load (preserve existing content). This replaces the
 * unconditional metal_set_load_clear() which cleared everything.
 *   mask: GLbitfield of GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT
 */
void metal_set_load_clear_mask(unsigned mask);

/*
 * Begin a render pass against the given attachments.
 *   color_textures : array of id<MTLTexture> (nullable entries allowed), length color_count
 *   depth_texture  : id<MTLTexture> (may be NULL)
 *   width/height   : render area
 *   samples        : 1 for now
 * If a pass is already active, it is a no-op (coalesce draws into one pass).
 */
void metal_begin_render_pass(void** color_textures, int color_count,
                             void* depth_texture, int width, int height, int samples);

/* End + commit the active render pass / command buffer. */
void metal_end_render_pass(void);
void metal_commit(void);

/*
 * End the active render pass, register a present for the given drawable on
 * the current command buffer, then commit. This is the correct Metal way to
 * present a CAMetalLayer drawable: the present is scheduled inside the command
 * buffer so the GPU finishes all encoded rendering before the drawable is
 * shown on screen. `drawable` is an id<CAMetalDrawable> (opaque void*).
 */
void metal_commit_and_present(void* drawable);

/* Current encoder (id<MTLRenderCommandEncoder>), may be NULL. */
void* metal_current_encoder(void);

/*
 * Encoder-side state setters. Each is a no-op when no render pass is active.
 * Stage: 0 = vertex, 1 = fragment (used for buffer/texture/sampler binding).
 */
void metal_encoder_set_pipeline(void* pipeline);
void metal_encoder_set_viewport(int x, int y, int w, int h, double znear, double zfar);
void metal_encoder_set_scissor(int x, int y, int w, int h);
void metal_encoder_set_vertex_buffer(int slot, void* buffer, int offset);
void metal_encoder_set_fragment_buffer(int slot, void* buffer, int offset);
void metal_encoder_set_vertex_texture(int slot, void* texture);
void metal_encoder_set_vertex_sampler(int slot, void* sampler);
void metal_encoder_set_fragment_texture(int slot, void* texture);
void metal_encoder_set_fragment_sampler(int slot, void* sampler);
void metal_encoder_set_blend_color(float r, float g, float b, float a);
void metal_encoder_set_depth_bias(float slope, float clamp);
void metal_encoder_set_cull_mode(int mode); /* 0=None,1=Front,2=Back */
void metal_encoder_set_front_facing(int ccw); /* 1=CCW, 0=CW */
void metal_encoder_set_triangle_fill_mode(int fill); /* 0=Fill,1=Lines,2=Points */
void metal_encoder_set_depth_test(int enabled, int write_mask, int compare_func);
void metal_encoder_set_color_write_mask(int r, int g, int b, int a);

/*
 * Create or fetch a cached MTLDepthStencilState matching the given parameters
 * and bind it on the current render encoder. Metal requires a depth-stencil
 * state object to be bound for depth testing/writing to take effect — the
 * pipeline's depthAttachmentPixelFormat merely allocates the attachment.
 *   enabled      : 0/1 — enable depth test
 *   write_mask   : 0/1 — enable depth writes (glDepthMask)
 *   compare_func : GL compare function (GL_NEVER=0x200, GL_LESS=0x201, ...)
 * Returns the state handle (id<MTLDepthStencilState>) or NULL.
 */
void metal_encoder_set_depth_stencil(int enabled, int write_mask, int compare_func);

/* Draw primitives. `index_type` 0=U16, 1=U32. */
void metal_encoder_draw_arrays(int primitive, int first, int count);
void metal_encoder_draw_indexed(int primitive, int count, int index_type,
                                void* index_buffer, int index_offset);
void metal_encoder_draw_arrays_instanced(int primitive, int first, int count, int primcount);
void metal_encoder_draw_indexed_instanced(int primitive, int count, int index_type,
                                          void* index_buffer, int index_offset, int primcount);

/*
 * Blit (copy) a region of a source MTLTexture to a destination MTLTexture
 * using a Metal blit encoder. Ends any active render pass first. The copy is
 * a full surface copy within the given rectangle (no scaling). This backs
 * glBlitFramebuffer(GL_NEAREST) — the common Minecraft path that copies an
 * off-screen FBO's colour attachment to the default framebuffer (drawable).
 *   src/dst : id<MTLTexture> (opaque void*)
 *   sx,sy,sw,sh : source rect (Metal top-left origin coordinates)
 *   dx,dy       : destination top-left corner
 *   level/layer : mipmap level / array layer (0 for 2D)
 */
void metal_blit_texture(void* src, void* dst,
                       int sx, int sy, int sw, int sh,
                       int dx, int dy, int level, int layer);

/* True if the Metal backend is available (i.e. compiled with Metal). */
int metal_available(void);

#ifdef __cplusplus
}
#endif

#endif // MITHRIL_METAL_CONTEXT_H
