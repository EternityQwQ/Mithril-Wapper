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

static MTLBlendFactor mtl_blend_factor(GLenum gl) {
    switch (gl) {
        case GL_ZERO:                return MTLBlendFactorZero;
        case GL_ONE:                 return MTLBlendFactorOne;
        case GL_SRC_COLOR:           return MTLBlendFactorSourceColor;
        case GL_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
        case GL_DST_COLOR:           return MTLBlendFactorDestinationColor;
        case GL_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
        case GL_SRC_ALPHA:           return MTLBlendFactorSourceAlpha;
        case GL_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
        case GL_DST_ALPHA:           return MTLBlendFactorDestinationAlpha;
        case GL_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
        case GL_CONSTANT_COLOR:      return MTLBlendFactorBlendColor;
        case GL_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case GL_CONSTANT_ALPHA:      return MTLBlendFactorBlendAlpha;
        case GL_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        case GL_SRC_ALPHA_SATURATE:  return MTLBlendFactorSourceAlphaSaturated;
        default:                     return MTLBlendFactorOne;
    }
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
                           int blend_enabled, GLenum blend_src, GLenum blend_dst,
                           GLenum gl_primitive_mode) {
    std::ostringstream s;
    s << program << ":" << (int)gl_primitive_mode << ":" << depth_format << ":"
      << blend_enabled << ":" << (int)blend_src << ":" << (int)blend_dst << ":";
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
                                   int blend_enabled,
                                   GLenum blend_src,
                                   GLenum blend_dst,
                                   GLenum gl_primitive_mode) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) return nullptr;

    NSString* sig = signature(program, attribs, attrib_count, color_formats,
                              color_count, depth_format, blend_enabled,
                              blend_src, blend_dst, gl_primitive_mode);
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

    // Vertex descriptor: define attributes the VAO has enabled. Then parse
    // the vertex MSL source to find any [[attribute(N)]] the shader references
    // that the VAO didn't cover, and supply matching default entries for those
    // so Metal doesn't reject the pipeline with "Vertex attribute N is not
    // defined in the vertex descriptor."
    //
    // We parse the MSL stage_in struct to determine the correct MTLVertexFormat
    // for each attribute, so there are no type mismatches (a fixed Float4
    // broke int attributes). A shared zero-filled buffer is bound at draw time.
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
            NSUInteger stride = attribs[i].stride > 0 ? attribs[i].stride : 16;
            vd.layouts[loc].stride       = stride;
            vd.layouts[loc].stepFunction = MTLVertexStepFunctionPerVertex;
        }

        // Parse the vertex MSL source to find [[attribute(N)]] declarations
        // in the stage_in struct. For any index the VAO didn't set, add a
        // default entry with a format matching the MSL type.
        if (vertex_msl && *vertex_msl) {
            NSString* mslStr = @(vertex_msl);
            // Match lines like:  float3 Position [[attribute(0)]];
            // or                int2 UV1 [[attribute(3)]];
            NSRegularExpression* re = [NSRegularExpression
                regularExpressionWithPattern:
                    @"(float|half|int|uint|short|ushort|uchar)([2-4]?)\\s+\\w+\\s+\\[\\[attribute\\((\\d+)\\)\\]\\]"
                options:0 error:nil];
            [re enumerateMatchesInString:mslStr options:0
                                   range:NSMakeRange(0, mslStr.length)
                              usingBlock:^(NSTextCheckingResult* m, NSMatchingFlags, BOOL* stop) {
                if (m.numberOfRanges < 4) return;
                NSString* baseType = [mslStr substringWithRange:[m rangeAtIndex:1]];
                NSString* vecSize  = [mslStr substringWithRange:[m rangeAtIndex:2]];
                NSUInteger idx = (NSUInteger)[[mslStr substringWithRange:[m rangeAtIndex:3]] integerValue];
                if (idx >= 16) return;
                // Always use the shader-declared type, even if the VAO already
                // set this index. OpenGL allows float→int conversion at the
                // GPU level, but Metal rejects type mismatches ("Cannot
                // convert attribute from FloatN to intN"). The shader's type
                // is authoritative.

                // Map MSL type -> MTLVertexFormat
                MTLVertexFormat fmt = MTLVertexFormatInvalid;
                int n = vecSize.length > 0 ? [vecSize intValue] : 1;
                if ([baseType isEqualToString:@"float"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatFloat; break;
                        case 2: fmt = MTLVertexFormatFloat2; break;
                        case 3: fmt = MTLVertexFormatFloat3; break;
                        case 4: fmt = MTLVertexFormatFloat4; break;
                    }
                } else if ([baseType isEqualToString:@"half"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatHalf; break;
                        case 2: fmt = MTLVertexFormatHalf2; break;
                        case 3: fmt = MTLVertexFormatHalf3; break;
                        case 4: fmt = MTLVertexFormatHalf4; break;
                    }
                } else if ([baseType isEqualToString:@"int"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatInt; break;
                        case 2: fmt = MTLVertexFormatInt2; break;
                        case 3: fmt = MTLVertexFormatInt3; break;
                        case 4: fmt = MTLVertexFormatInt4; break;
                    }
                } else if ([baseType isEqualToString:@"uint"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatUInt; break;
                        case 2: fmt = MTLVertexFormatUInt2; break;
                        case 3: fmt = MTLVertexFormatUInt3; break;
                        case 4: fmt = MTLVertexFormatUInt4; break;
                    }
                } else if ([baseType isEqualToString:@"short"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatShort; break;
                        case 2: fmt = MTLVertexFormatShort2; break;
                        case 3: fmt = MTLVertexFormatShort3; break;
                        case 4: fmt = MTLVertexFormatShort4; break;
                    }
                } else if ([baseType isEqualToString:@"ushort"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatUShort; break;
                        case 2: fmt = MTLVertexFormatUShort2; break;
                        case 3: fmt = MTLVertexFormatUShort3; break;
                        case 4: fmt = MTLVertexFormatUShort4; break;
                    }
                } else if ([baseType isEqualToString:@"uchar"]) {
                    switch (n) {
                        case 1: fmt = MTLVertexFormatUChar; break;
                        case 2: fmt = MTLVertexFormatUChar2; break;
                        case 3: fmt = MTLVertexFormatUChar3; break;
                        case 4: fmt = MTLVertexFormatUChar4; break;
                    }
                }
                if (fmt == MTLVertexFormatInvalid) return;

                vd.attributes[idx].format      = fmt;
                vd.attributes[idx].bufferIndex = idx;
                vd.attributes[idx].offset      = 0;
                vd.layouts[idx].stride       = 16;
                vd.layouts[idx].stepFunction = MTLVertexStepFunctionPerVertex;
            }];
        }

        pd.vertexDescriptor = vd;
    }

    for (int i = 0; i < color_count && i < 8; ++i) {
        if (color_formats[i] == 0) continue;
        pd.colorAttachments[i].pixelFormat = (MTLPixelFormat)color_formats[i];
        if (blend_enabled) {
            pd.colorAttachments[i].blendingEnabled = YES;
            pd.colorAttachments[i].sourceRGBBlendFactor        = mtl_blend_factor(blend_src);
            pd.colorAttachments[i].destinationRGBBlendFactor   = mtl_blend_factor(blend_dst);
            pd.colorAttachments[i].sourceAlphaBlendFactor      = mtl_blend_factor(blend_src);
            pd.colorAttachments[i].destinationAlphaBlendFactor = mtl_blend_factor(blend_dst);
            pd.colorAttachments[i].rgbBlendOperation   = MTLBlendOperationAdd;
            pd.colorAttachments[i].alphaBlendOperation = MTLBlendOperationAdd;
        } else {
            pd.colorAttachments[i].blendingEnabled = NO;
        }
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
    if (!state) {
        MITHRIL_LOG_ERROR("metal_pipeline", "Pipeline creation returned nil (program %u, no error)",
                          program);
        return nullptr;
    }
    static int s_pipeline_count = 0;
    s_pipeline_count++;
    if (s_pipeline_count <= 10) {
        MITHRIL_LOG_INFO("metal_pipeline", "Pipeline #%d created OK (program %u, vertFn=%d fragFn=%d colorCount=%d depthFmt=%d)",
                         s_pipeline_count, program,
                         pd.vertexFunction != nil ? 1 : 0,
                         pd.fragmentFunction != nil ? 1 : 0,
                         color_count, depth_format);
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
