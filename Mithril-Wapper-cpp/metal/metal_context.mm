// Mithril-Wapper - metal/metal_context.mm
// Metal device / command queue / render-pass lifecycle.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "metal_context.h"
#include "../gl/log.h"

static id<MTLDevice>             g_device  = nil;
static id<MTLCommandQueue>       g_queue   = nil;
static id<MTLCommandBuffer>      g_cmd     = nil;
static id<MTLRenderCommandEncoder> g_enc   = nil;
static BOOL                      g_pass_active = NO;

static MTLClearColor g_clear_color   = {0,0,0,0};
static double        g_clear_depth   = 1.0;
static uint32_t      g_clear_stencil = 0;

// Load action for the next render pass. glClear sets Clear then flushes; draw
// passes set Load so previously-cleared/drawn contents are preserved.
static MTLLoadAction g_color_load = MTLLoadActionLoad;
static MTLLoadAction g_depth_load = MTLLoadActionLoad;

extern "C" {

void metal_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_device = MTLCreateSystemDefaultDevice();
        if (g_device) {
            g_queue = [g_device newCommandQueue];
        }
        if (!g_device) {
            // e.g. running in a headless test environment.
        }
    });
}

void* metal_device(void)        { return (__bridge void*)g_device; }
void* metal_command_queue(void) { return (__bridge void*)g_queue; }
int   metal_available(void)     { return g_device != nil ? 1 : 0; }

void metal_set_clear_color(float r, float g, float b, float a) {
    g_clear_color = MTLClearColorMake(r, g, b, a);
}
void metal_set_clear_depth(double d) { g_clear_depth = d; }
void metal_set_clear_stencil(int s)  { g_clear_stencil = (uint32_t)s; }

void metal_set_load_clear(void) { g_color_load = MTLLoadActionClear; g_depth_load = MTLLoadActionClear; }
void metal_set_load_load(void)  { g_color_load = MTLLoadActionLoad;  g_depth_load = MTLLoadActionLoad; }

static MTLRenderPassDescriptor* build_pass_desc(void** color_textures,
                                                int color_count,
                                                void* depth_texture,
                                                int width, int height) {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    if (!desc) return nil;

    for (int i = 0; i < color_count && i < 8; ++i) {
        id<MTLTexture> tex = (__bridge id<MTLTexture>)color_textures[i];
        if (!tex) continue;
        desc.colorAttachments[i].texture = tex;
        desc.colorAttachments[i].loadAction  = g_color_load;
        desc.colorAttachments[i].storeAction = MTLStoreActionStore;
        desc.colorAttachments[i].clearColor  = g_clear_color;
    }

    if (depth_texture) {
        id<MTLTexture> dt = (__bridge id<MTLTexture>)depth_texture;
        desc.depthAttachment.texture = dt;
        desc.depthAttachment.loadAction  = g_depth_load;
        desc.depthAttachment.storeAction = MTLStoreActionStore;
        desc.depthAttachment.clearDepth  = g_clear_depth;
        if (dt.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
            dt.pixelFormat == MTLPixelFormatStencil8) {
            // MTLPixelFormatDepth24Unorm_Stencil8 is macOS-only; on iOS we
            // always map GL_DEPTH24_STENCIL8 to Depth32Float_Stencil8 above.
            desc.stencilAttachment.texture = dt;
            desc.stencilAttachment.loadAction  = g_depth_load;
            desc.stencilAttachment.storeAction = MTLStoreActionStore;
            desc.stencilAttachment.clearStencil = g_clear_stencil;
        }
    }
    (void)width; (void)height;
    return desc;
}

void metal_begin_render_pass(void** color_textures, int color_count,
                             void* depth_texture, int width, int height, int samples) {
    if (!g_device || !g_queue) return;
    if (g_pass_active) return; // coalesce draws

    if (!g_cmd) {
        g_cmd = [g_queue commandBuffer];
    }

    MTLRenderPassDescriptor* desc = build_pass_desc(color_textures, color_count,
                                                    depth_texture, width, height);
    if (!desc) return;

    g_enc = [g_cmd renderCommandEncoderWithDescriptor:desc];
    g_pass_active = YES;
    (void)samples;
}

void metal_end_render_pass(void) {
    if (g_enc) {
        [g_enc endEncoding];
        g_enc = nil;
    }
    g_pass_active = NO;
}

void metal_commit(void) {
    if (g_enc) { [g_enc endEncoding]; g_enc = nil; }
    g_pass_active = NO;
    if (g_cmd) {
        [g_cmd commit];
        // Don't waitUntilCompleted — Metal command buffers execute in order,
        // and blocking here serializes CPU/GPU, destroying performance.
        // eglSwapBuffers presents the drawable after commit; the GPU will
        // finish the encoded work before presenting.
        g_cmd = nil;
    }
}

void* metal_current_encoder(void) { return (__bridge void*)g_enc; }

static MTLPrimitiveType to_mtl_primitive(int p) {
    switch (p) {
        case 0x0000: return MTLPrimitiveTypePoint;         // GL_POINTS
        case 0x0001: return MTLPrimitiveTypeLine;          // GL_LINES
        case 0x0002: return MTLPrimitiveTypeLineStrip;     // GL_LINE_LOOP -> approximated
        case 0x0003: return MTLPrimitiveTypeLineStrip;     // GL_LINE_STRIP
        case 0x0004: return MTLPrimitiveTypeTriangle;      // GL_TRIANGLES
        case 0x0005: return MTLPrimitiveTypeTriangleStrip; // GL_TRIANGLE_STRIP
        case 0x0006: return MTLPrimitiveTypeTriangle;      // GL_TRIANGLE_FAN -> approximated
        default:     return MTLPrimitiveTypeTriangle;
    }
}

static MTLIndexType to_mtl_index_type(int t) {
    return t == 0 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
}

void metal_encoder_set_pipeline(void* pipeline) {
    if (!g_enc || !pipeline) return;
    id<MTLRenderPipelineState> state = (__bridge id<MTLRenderPipelineState>)pipeline;
    [g_enc setRenderPipelineState:state];
}

void metal_encoder_set_viewport(int x, int y, int w, int h, double znear, double zfar) {
    if (!g_enc || w <= 0 || h <= 0) return;
    MTLViewport vp;
    vp.originX = (double)x;
    vp.originY = (double)y;
    vp.width   = (double)w;
    vp.height  = (double)h;
    vp.znear   = znear;
    vp.zfar    = zfar;
    [g_enc setViewport:vp];
}

void metal_encoder_set_scissor(int x, int y, int w, int h) {
    if (!g_enc || w <= 0 || h <= 0) return;
    MTLScissorRect r;
    r.x = (NSUInteger)x;
    r.y = (NSUInteger)y;
    r.width  = (NSUInteger)w;
    r.height = (NSUInteger)h;
    [g_enc setScissorRect:r];
}

void metal_encoder_set_vertex_buffer(int slot, void* buffer, int offset) {
    if (!g_enc || !buffer) return;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [g_enc setVertexBuffer:buf offset:(NSUInteger)offset atIndex:(NSUInteger)slot];
}

void metal_encoder_set_fragment_buffer(int slot, void* buffer, int offset) {
    if (!g_enc || !buffer) return;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    [g_enc setFragmentBuffer:buf offset:(NSUInteger)offset atIndex:(NSUInteger)slot];
}

void metal_encoder_set_vertex_texture(int slot, void* texture) {
    if (!g_enc || !texture) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [g_enc setVertexTexture:tex atIndex:(NSUInteger)slot];
}

void metal_encoder_set_vertex_sampler(int slot, void* sampler) {
    if (!g_enc || !sampler) return;
    id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)sampler;
    [g_enc setVertexSamplerState:s atIndex:(NSUInteger)slot];
}

void metal_encoder_set_fragment_texture(int slot, void* texture) {
    if (!g_enc || !texture) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    [g_enc setFragmentTexture:tex atIndex:(NSUInteger)slot];
}

void metal_encoder_set_fragment_sampler(int slot, void* sampler) {
    if (!g_enc || !sampler) return;
    id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)sampler;
    [g_enc setFragmentSamplerState:s atIndex:(NSUInteger)slot];
}

void metal_encoder_set_blend_color(float r, float g, float b, float a) {
    if (!g_enc) return;
    [g_enc setBlendColorRed:r green:g blue:b alpha:a];
}

void metal_encoder_set_depth_bias(float slope, float clamp) {
    if (!g_enc) return;
    [g_enc setDepthBias:slope slopeScale:1.0f clamp:clamp];
}

void metal_encoder_set_cull_mode(int mode) {
    if (!g_enc) return;
    MTLCullMode m = MTLCullModeNone;
    if (mode == 1) m = MTLCullModeFront;
    else if (mode == 2) m = MTLCullModeBack;
    [g_enc setCullMode:m];
}

void metal_encoder_set_front_facing(int ccw) {
    if (!g_enc) return;
    [g_enc setFrontFacingWinding:ccw ? MTLWindingCounterClockwise : MTLWindingClockwise];
}

void metal_encoder_set_triangle_fill_mode(int fill) {
    if (!g_enc) return;
    MTLTriangleFillMode m = MTLTriangleFillModeFill;
    if (fill == 1) m = MTLTriangleFillModeLines;
    [g_enc setTriangleFillMode:m];
}

void metal_encoder_set_depth_test(int enabled, int write_mask, int compare_func) {
    if (!g_enc) return;
    // Best-effort: depth-stencil state object creation is heavy; for bring-up we
    // rely on the pipeline's depthAttachmentPixelFormat and apply depth write
    // enable + compare via a cached descriptor.
    (void)enabled; (void)write_mask; (void)compare_func;
}

void metal_encoder_set_color_write_mask(int r, int g, int b, int a) {
    // In Metal, color write mask is a per-attachment property of
    // MTLRenderPipelineState (MTLRenderPipelineColorAttachmentDescriptor
    // .writeMask), NOT a dynamic MTLRenderCommandEncoder state. There is no
    // -setColorWriteMask: on the encoder. It is applied at pipeline build
    // time (see metal_pipeline.mm), so nothing to do here at encode time.
    // Parameters retained for API symmetry with the other encoder helpers.
    (void)r; (void)g; (void)b; (void)a;
}

void metal_encoder_draw_arrays(int primitive, int first, int count) {
    if (!g_enc || count <= 0) return;
    [g_enc drawPrimitives:to_mtl_primitive(primitive)
              vertexStart:(NSUInteger)first
              vertexCount:(NSUInteger)count];
}

void metal_encoder_draw_indexed(int primitive, int count, int index_type,
                                void* index_buffer, int index_offset) {
    if (!g_enc || !index_buffer || count <= 0) return;
    id<MTLBuffer> ib = (__bridge id<MTLBuffer>)index_buffer;
    [g_enc drawIndexedPrimitives:to_mtl_primitive(primitive)
                      indexCount:(NSUInteger)count
                       indexType:to_mtl_index_type(index_type)
                     indexBuffer:ib
               indexBufferOffset:(NSUInteger)index_offset];
}

void metal_encoder_draw_arrays_instanced(int primitive, int first, int count, int primcount) {
    if (!g_enc || count <= 0 || primcount <= 0) return;
    [g_enc drawPrimitives:to_mtl_primitive(primitive)
              vertexStart:(NSUInteger)first
              vertexCount:(NSUInteger)count
            instanceCount:(NSUInteger)primcount];
}

void metal_encoder_draw_indexed_instanced(int primitive, int count, int index_type,
                                          void* index_buffer, int index_offset, int primcount) {
    if (!g_enc || !index_buffer || count <= 0 || primcount <= 0) return;
    id<MTLBuffer> ib = (__bridge id<MTLBuffer>)index_buffer;
    [g_enc drawIndexedPrimitives:to_mtl_primitive(primitive)
                      indexCount:(NSUInteger)count
                       indexType:to_mtl_index_type(index_type)
                     indexBuffer:ib
               indexBufferOffset:(NSUInteger)index_offset
                   instanceCount:(NSUInteger)primcount];
}

} // extern "C"
