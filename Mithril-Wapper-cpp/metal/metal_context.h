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

/* Draw primitives. `index_type` 0=U16, 1=U32. */
void metal_encoder_draw_arrays(int primitive, int first, int count);
void metal_encoder_draw_indexed(int primitive, int count, int index_type,
                                void* index_buffer, int index_offset);
void metal_encoder_draw_arrays_instanced(int primitive, int first, int count, int primcount);
void metal_encoder_draw_indexed_instanced(int primitive, int count, int index_type,
                                          void* index_buffer, int index_offset, int primcount);

/* True if the Metal backend is available (i.e. compiled with Metal). */
int metal_available(void);

#ifdef __cplusplus
}
#endif

#endif // MITHRIL_METAL_CONTEXT_H
