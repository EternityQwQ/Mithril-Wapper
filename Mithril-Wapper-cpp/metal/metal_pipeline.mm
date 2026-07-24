// Mithril-Wapper - metal/metal_pipeline.mm
// MSL -> MTLLibrary -> MTLRenderPipelineState, cached by a signature of
// (program, vertex format, color/depth pixel formats, primitive mode).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "metal_context.h"
#include "metal_pipeline.h"
#include "../gl/log.h"

#include <string>
#include <sstream>

static NSMutableDictionary<NSNumber*, id<MTLLibrary>>* g_vert_libs() {
    static NSMutableDictionary* d = [NSMutableDictionary new]; return d;
}
static NSMutableDictionary<NSNumber*, id<MTLLibrary>>* g_frag_libs() {
    static NSMutableDictionary* d = [NSMutableDictionary new]; return d;
}
static NSMutableDictionary<NSString*, id<MTLRenderPipelineState>>* g_pipelines() {
    static NSMutableDictionary* d = [NSMutableDictionary new]; return d;
}

static MTLVertexFormat gl_vertex_format(GLenum type, int size, int normalized, int integer) {
    if (integer) {
        switch (type) {
            case GL_UNSIGNED_BYTE:
                switch (size) { case 1: return MTLVertexFormatUChar;  case 2: return MTLVertexFormatUChar2;
                               case 3: return MTLVertexFormatUChar3; case 4: return MTLVertexFormatUChar4; }
                break;
            case GL_UNSIGNED_SHORT:
                switch (size) { case 1: return MTLVertexFormatUShort;  case 2: return MTLVertexFormatUShort2;
                               case 3: return MTLVertexFormatUShort3; case 4: return MTLVertexFormatUShort4; }
                break;
            case GL_UNSIGNED_INT:
                switch (size) { case 1: return MTLVertexFormatUInt;  case 2: return MTLVertexFormatUInt2;
                               case 3: return MTLVertexFormatUInt3; case 4: return MTLVertexFormatUInt4; }
                break;
            case GL_INT:
                switch (size) { case 1: return MTLVertexFormatInt;  case 2: return MTLVertexFormatInt2;
                               case 3: return MTLVertexFormatInt3; case 4: return MTLVertexFormatInt4; }
                break;
        }
        return MTLVertexFormatInvalid;
    }
    if (normalized) {
        switch (type) {
            case GL_UNSIGNED_BYTE:
                switch (size) { case 1: return MTLVertexFormatUCharNormalized;  case 2: return MTLVertexFormatUChar2Normalized;
                               case 3: return MTLVertexFormatUChar3Normalized; case 4: return MTLVertexFormatUChar4Normalized; }
                break;
            case GL_BYTE:
                switch (size) { case 1: return MTLVertexFormatCharNormalized;  case 2: return MTLVertexFormatChar2Normalized;
                               case 3: return MTLVertexFormatChar3Normalized; case 4: return MTLVertexFormatChar4Normalized; }
                break;
            case GL_UNSIGNED_SHORT:
                switch (size) { case 1: return MTLVertexFormatUShortNormalized;  case 2: return MTLVertexFormatUShort2Normalized;
                               case 3: return MTLVertexFormatUShort3Normalized; case 4: return MTLVertexFormatUShort4Normalized; }
                break;
            case GL_SHORT:
                switch (size) { case 1: return MTLVertexFormatShortNormalized;  case 2: return MTLVertexFormatShort2Normalized;
                               case 3: return MTLVertexFormatShort3Normalized; case 4: return MTLVertexFormatShort4Normalized; }
                break;
            case GL_UNSIGNED_INT_2_10_10_10_REV: return MTLVertexFormatUInt1010102Normalized;
        }
    } else {
        switch (type) {
            case GL_FLOAT:
                switch (size) { case 1: return MTLVertexFormatFloat;  case 2: return MTLVertexFormatFloat2;
                               case 3: return MTLVertexFormatFloat3; case 4: return MTLVertexFormatFloat4; }
                break;
            case GL_HALF_FLOAT:
                switch (size) { case 1: return MTLVertexFormatHalf;  case 2: return MTLVertexFormatHalf2;
                               case 3: return MTLVertexFormatHalf3; case 4: return MTLVertexFormatHalf4; }
                break;
            case GL_UNSIGNED_BYTE:
                switch (size) { case 1: return MTLVertexFormatUChar;  case 2: return MTLVertexFormatUChar2;
                               case 3: return MTLVertexFormatUChar3; case 4: return MTLVertexFormatUChar4; }
                break;
            case GL_UNSIGNED_SHORT:
                switch (size) { case 1: return MTLVertexFormatUShort;  case 2: return MTLVertexFormatUShort2;
                               case 3: return MTLVertexFormatUShort3; case 4: return MTLVertexFormatUShort4; }
                break;
            case GL_INT:
                switch (size) { case 1: return MTLVertexFormatInt;  case 2: return MTLVertexFormatInt2;
                               case 3: return MTLVertexFormatInt3; case 4: return MTLVertexFormatInt4; }
                break;
            case GL_UNSIGNED_INT:
                switch (size) { case 1: return MTLVertexFormatUInt;  case 2: return MTLVertexFormatUInt2;
                               case 3: return MTLVertexFormatUInt3; case 4: return MTLVertexFormatUInt4; }
                break;
        }
    }
    return MTLVertexFormatInvalid;
}

static id<MTLLibrary> compile_msl_lib(id<MTLDevice> dev, const char* src, NSString* kind,
                                      GLuint program, BOOL is_vert) {
    if (!src || !*src) return nil;
    @try {
        NSError* err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&err];
        if (err) {
            // Log a trimmed compile error so shader bugs are visible.
            NSString* msg = err.localizedDescription;
            if (msg.length > 1024) msg = [msg substringToIndex:1024];
            MITHRIL_LOG_ERROR("metal_pipeline", "MSL compile error (%s, program %u): %s",
                              kind.UTF8String, program, msg.UTF8String);
        }
        return lib;
    } @catch (NSException* e) {
        MITHRIL_LOG_ERROR("metal_pipeline", "MSL compile exception (%s, program %u): %s",
                          kind.UTF8String, program, e.reason.UTF8String ?: "unknown");
        return nil;
    }
}

static NSString* signature(GLuint program, const struct MetalVertexAttrib* attribs, int attrib_count,
                           const int* color_formats, int color_count, int depth_format,
                           GLenum gl_primitive_mode) {
    std::ostringstream s;
    s << program << ":" << (int)gl_primitive_mode << ":" << depth_format << ":";
    for (int i = 0; i < attrib_count; ++i) {
        if (!attribs[i].enabled) continue;
        s << attribs[i].location << "," << attribs[i].type << "," << attribs[i].size << ","
          << attribs[i].normalized << "," << attribs[i].integer << ","
          << attribs[i].stride << "," << attribs[i].offset << ","
          << attribs[i].buffer_name << ";";
    }
    s << ":";
    for (int i = 0; i < color_count; ++i) s << color_formats[i] << ",";
    return @(s.str().c_str());
}

extern "C" {

void* metal_get_or_create_pipeline(GLuint program,
                                   const char* vertex_msl,
                                   const char* fragment_msl,
                                   const struct MetalVertexAttrib* attribs,
                                   int attrib_count,
                                   const int* color_formats,
                                   int color_count,
                                   int depth_format,
                                   GLenum gl_primitive_mode) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) return nullptr;

    NSString* sig = signature(program, attribs, attrib_count, color_formats,
                              color_count, depth_format, gl_primitive_mode);
    id<MTLRenderPipelineState> cached = g_pipelines()[sig];
    if (cached) return (__bridge void*)cached;

    id<MTLLibrary> vlib = g_vert_libs()[@(program)];
    id<MTLLibrary> flib = g_frag_libs()[@(program)];
    if (!vlib && vertex_msl) {
        vlib = compile_msl_lib(dev, vertex_msl, @"vertex", program, YES);
        if (vlib) g_vert_libs()[@(program)] = vlib;
    }
    if (!flib && fragment_msl) {
        flib = compile_msl_lib(dev, fragment_msl, @"fragment", program, NO);
        if (flib) g_frag_libs()[@(program)] = flib;
    }

    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = vlib ? [vlib newFunctionWithName:@"main0"] : nil;
    pd.fragmentFunction = flib ? [flib newFunctionWithName:@"main0"] : nil;

    // Metal requires a non-nil vertexFunction. If the vertex shader failed to
    // compile or the main0 function wasn't found, skip pipeline creation
    // entirely rather than triggering a validation assertion.
    if (!pd.vertexFunction) {
        MITHRIL_LOG_ERROR("metal_pipeline", "Cannot create pipeline: vertex function is nil "
                          "(program %u). Vertex MSL was %s.", program,
                          vertex_msl && *vertex_msl ? "provided but failed to compile" : "empty");
        return nullptr;
    }

    // Vertex descriptor: each enabled attribute reads from its own buffer
    // at index == attribute location. Additionally, supply default (zero-stride)
    // entries for attribute indices 0..7 that the VAO didn't enable, so Metal
    // doesn't reject the pipeline with "Vertex attribute N is not defined in
    // the vertex descriptor." This happens when a shader declares more inputs
    // than the application binds (e.g. Minecraft's blit_screen declares 4
    // attributes but some draw paths only bind 3). A zero-stride layout makes
    // Metal read a constant value (all zeros) for the missing attribute.
    if (pd.vertexFunction) {
        MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
        for (int i = 0; i < attrib_count; ++i) {
            if (!attribs[i].enabled) continue;
            int loc = attribs[i].location;
            MTLVertexFormat fmt = gl_vertex_format(attribs[i].type, attribs[i].size,
                                                   attribs[i].normalized, attribs[i].integer);
            if (fmt == MTLVertexFormatInvalid) continue;
            vd.attributes[loc].format      = fmt;
            vd.attributes[loc].bufferIndex = loc;
            vd.attributes[loc].offset      = attribs[i].offset;
            NSUInteger stride = attribs[i].stride > 0 ? attribs[i].stride : 0;
            vd.layouts[loc].stride       = stride;
            vd.layouts[loc].stepFunction = attribs[i].buffer_name && attribs[i].stride > 0
                                             ? MTLVertexStepFunctionPerVertex
                                             : MTLVertexStepFunctionPerVertex;
        }
        // Fill in zero-stride defaults for any attribute index 0..7 not set
        // by the VAO. Zero-stride means all vertices read the same value
        // (zeros from an unbound buffer), which is safe and prevents Metal
        // pipeline validation failures when the shader references an
        // attribute the app didn't bind.
        for (int loc = 0; loc < 8; ++loc) {
            if (vd.attributes[loc].format == MTLVertexFormatInvalid) {
                vd.attributes[loc].format      = MTLVertexFormatFloat4;
                vd.attributes[loc].bufferIndex = loc;
                vd.attributes[loc].offset      = 0;
                vd.layouts[loc].stride       = 0;
                vd.layouts[loc].stepFunction = MTLVertexStepFunctionPerVertex;
            }
        }
        pd.vertexDescriptor = vd;
    }

    for (int i = 0; i < color_count && i < 8; ++i) {
        if (color_formats[i] == 0) continue;
        pd.colorAttachments[i].pixelFormat = (MTLPixelFormat)color_formats[i];
        pd.colorAttachments[i].blendingEnabled = NO; // blending toggled at encode time
    }
    // Only set depth attachment if the format is actually a depth-renderable
    // MTLPixelFormat. Setting a non-depth format (e.g. RGBA8Unorm) triggers:
    //   validateWithDevice: failed assertion `Render Pipeline Descriptor
    //   Validation - depthAttachmentPixelFormat MTLPixelFormatRGBA8Unorm
    //   is not depth renderable.'
    if (depth_format) {
        MTLPixelFormat mtlDepth = (MTLPixelFormat)depth_format;
        if (mtlDepth == MTLPixelFormatDepth16Unorm      ||
            mtlDepth == MTLPixelFormatDepth32Float      ||
            mtlDepth == MTLPixelFormatDepth32Float_Stencil8) {
            pd.depthAttachmentPixelFormat = mtlDepth;
            if (mtlDepth == MTLPixelFormatDepth32Float_Stencil8) {
                // Depth+stencil packed format: set stencil attachment too.
                // MTLPixelFormatDepth24Unorm_Stencil8 is macOS-only; iOS uses
                // Depth32Float_Stencil8 for GL_DEPTH24_STENCIL8.
                pd.stencilAttachmentPixelFormat = mtlDepth;
            }
        } else {
            MITHRIL_LOG_ERROR("metal_pipeline", "Ignoring non-depth-renderable pixel format %d "
                              "for depth attachment (program %u).", depth_format, program);
        }
    }

    NSError* err = nil;
    id<MTLRenderPipelineState> state = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (err) {
        MITHRIL_LOG_ERROR("metal_pipeline", "Pipeline creation failed (program %u): %s",
                          program, err.localizedDescription.UTF8String ?: "unknown");
        return nullptr;
    }
    g_pipelines()[sig] = state;
    return (__bridge void*)state;
}

void metal_delete_program_resources(GLuint program) {
    [g_vert_libs() removeObjectForKey:@(program)];
    [g_frag_libs() removeObjectForKey:@(program)];
    // Pipeline cache entries are keyed by signature including the program id;
    // purge any whose key starts with "<program>:".
    NSString* prefix = [NSString stringWithFormat:@"%u:", program];
    NSArray* keys = [g_pipelines() allKeys];
    for (NSString* k in keys) {
        if ([k hasPrefix:prefix]) [g_pipelines() removeObjectForKey:k];
    }
}

int metal_compile_msl(const char* msl, char* err_buf, int err_buf_size) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev || !msl) {
        if (err_buf && err_buf_size > 0) err_buf[0] = 0;
        return 0;
    }
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(msl) options:nil error:&err];
    if (err) {
        if (err_buf && err_buf_size > 0) {
            strncpy(err_buf, err.localizedDescription.UTF8String, err_buf_size - 1);
            err_buf[err_buf_size - 1] = 0;
        }
        return 0;
    }
    if (err_buf && err_buf_size > 0) err_buf[0] = 0;
    return lib ? 1 : 0;
}

} // extern "C"
