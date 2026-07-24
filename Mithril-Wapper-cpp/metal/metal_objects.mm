// Mithril-Wapper - metal/metal_objects.mm
// MTLBuffer / MTLTexture / MTLSamplerState management keyed by GL names.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "metal_context.h"
#include "metal_objects.h"
#include "../gl/log.h"

static NSMutableDictionary<NSNumber*, id<MTLBuffer>>* g_buffers() {
    static NSMutableDictionary* d = [NSMutableDictionary new];
    return d;
}
static NSMutableDictionary<NSNumber*, id<MTLTexture>>* g_textures() {
    static NSMutableDictionary* d = [NSMutableDictionary new];
    return d;
}
static NSMutableDictionary<NSNumber*, id<MTLSamplerState>>* g_samplers() {
    static NSMutableDictionary* d = [NSMutableDictionary new];
    return d;
}

static NSNumber* key(GLuint n) { return @(n); }

static MTLPixelFormat gl_internal_to_mtl(GLenum f) {
    switch (f) {
        case GL_R8:                return MTLPixelFormatR8Unorm;
        case GL_R8_SNORM:          return MTLPixelFormatR8Snorm;
        case GL_R16F:              return MTLPixelFormatR16Float;
        case GL_R32F:              return MTLPixelFormatR32Float;
        case GL_RG8:               return MTLPixelFormatRG8Unorm;
        case GL_RG8_SNORM:         return MTLPixelFormatRG8Snorm;
        case GL_RG16F:             return MTLPixelFormatRG16Float;
        case GL_RG32F:             return MTLPixelFormatRG32Float;
        case GL_RGB8:              return MTLPixelFormatRGBA8Unorm;  // expanded on upload
        case GL_RGB8_SNORM:        return MTLPixelFormatRGBA8Snorm;
        case GL_RGBA8:             return MTLPixelFormatRGBA8Unorm;
        case GL_RGBA8_SNORM:       return MTLPixelFormatRGBA8Snorm;
        case GL_SRGB8_ALPHA8:      return MTLPixelFormatRGBA8Unorm_sRGB;
        case GL_RGB10_A2:          return MTLPixelFormatRGB10A2Unorm;
        case GL_R11F_G11F_B10F:    return MTLPixelFormatRG11B10Float;
        case GL_RGBA16F:           return MTLPixelFormatRGBA16Float;
        case GL_RGB16F:            return MTLPixelFormatRGBA16Float;
        case GL_RGBA32F:           return MTLPixelFormatRGBA32Float;
        case GL_RGB32F:            return MTLPixelFormatRGBA32Float;
        case GL_DEPTH_COMPONENT16: return MTLPixelFormatDepth16Unorm;
        case GL_DEPTH_COMPONENT24: return MTLPixelFormatDepth32Float;
        case GL_DEPTH_COMPONENT32: return MTLPixelFormatDepth32Float;
        case GL_DEPTH_COMPONENT32F:return MTLPixelFormatDepth32Float;
        case GL_DEPTH24_STENCIL8:  return MTLPixelFormatDepth32Float_Stencil8;
        case GL_DEPTH32F_STENCIL8: return MTLPixelFormatDepth32Float_Stencil8;
        case GL_STENCIL_INDEX8:    return MTLPixelFormatStencil8;
        case GL_R8UI:              return MTLPixelFormatR8Uint;
        case GL_R8I:               return MTLPixelFormatR8Sint;
        case GL_RG8UI:             return MTLPixelFormatRG8Uint;
        case GL_RG8I:              return MTLPixelFormatRG8Sint;
        case GL_RGBA8UI:           return MTLPixelFormatRGBA8Uint;
        case GL_RGBA8I:            return MTLPixelFormatRGBA8Sint;
        case GL_R16UI:             return MTLPixelFormatR16Uint;
        case GL_RGBA16UI:          return MTLPixelFormatRGBA16Uint;
        case GL_R32UI:             return MTLPixelFormatR32Uint;
        case GL_RGBA32UI:          return MTLPixelFormatRGBA32Uint;
        default:                   return MTLPixelFormatRGBA8Unorm;
    }
}

static MTLTextureType gl_target_to_mtl(GLenum t, int samples) {
    if (samples > 1) {
        switch (t) {
            case GL_TEXTURE_2D:                 return MTLTextureType2DMultisample;
            case GL_TEXTURE_2D_ARRAY:           return MTLTextureType2DMultisampleArray;
            default:                            return MTLTextureType2DMultisample;
        }
    }
    switch (t) {
        case GL_TEXTURE_1D:               return MTLTextureType1D;
        case GL_TEXTURE_1D_ARRAY:         return MTLTextureType1DArray;
        case GL_TEXTURE_2D:               return MTLTextureType2D;
        case GL_TEXTURE_2D_ARRAY:         return MTLTextureType2DArray;
        case GL_TEXTURE_3D:               return MTLTextureType3D;
        case GL_TEXTURE_CUBE_MAP:         return MTLTextureTypeCube;
        case GL_TEXTURE_RECTANGLE:        return MTLTextureType2D;
        case GL_TEXTURE_2D_MULTISAMPLE:   return MTLTextureType2DMultisample;
        default:                          return MTLTextureType2D;
    }
}

static NSUInteger mtl_texture_usage(GLenum target) {
    NSUInteger u = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    if (target == GL_TEXTURE_BUFFER) u |= MTLTextureUsageShaderWrite;
    return u;
}

extern "C" {

/*
 * Shared zero-filled buffer (16 bytes = sizeof(float4)) used to bind to
 * vertex attribute slots that the shader references but the application
 * didn't bind. The vertex descriptor gives these slots a stride of 16 and
 * format Float4; binding this zero buffer makes the attribute read vec4(0)
 * for every vertex, which is safe.
 */
static id<MTLBuffer> s_zero_vertex_buffer = nil;
void* metal_get_zero_buffer(void) {
    if (s_zero_vertex_buffer) return (__bridge void*)s_zero_vertex_buffer;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) return nullptr;
    static const float zeros[4] = {0, 0, 0, 0};
    s_zero_vertex_buffer = [dev newBufferWithBytes:zeros length:16
                                           options:MTLResourceStorageModeShared];
    return (__bridge void*)s_zero_vertex_buffer;
}

void* metal_get_or_create_buffer(GLuint name, const void* data, size_t size) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev || name == 0) return nullptr;
    id<MTLBuffer> buf = g_buffers()[key(name)];
    if (buf && buf.length >= size) {
        if (data && size) memcpy([buf contents], data, size);
        return (__bridge void*)buf;
    }
    if (size == 0) size = 16;
    if (data) {
        buf = [dev newBufferWithBytes:data length:size
                                options:MTLResourceStorageModeShared];
    } else {
        buf = [dev newBufferWithLength:size options:MTLResourceStorageModeShared];
    }
    g_buffers()[key(name)] = buf;
    return (__bridge void*)buf;
}

void metal_buffer_upload(GLuint name, GLintptr offset, const void* data, size_t size) {
    id<MTLBuffer> buf = g_buffers()[key(name)];
    if (!buf || !data) return;
    if ((size_t)offset + size > buf.length) return;
    memcpy((uint8_t*)[buf contents] + offset, data, size);
}

void* metal_get_buffer(GLuint name) {
    id<MTLBuffer> buf = g_buffers()[key(name)];
    return (__bridge void*)buf;
}

void metal_delete_buffer(GLuint name) {
    [g_buffers() removeObjectForKey:key(name)];
}

void* metal_get_or_create_texture(GLuint name, int width, int height, int depth,
                                  int levels, GLenum internal_format, GLenum target,
                                  int samples) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev || name == 0) return nullptr;

    id<MTLTexture> existing = g_textures()[key(name)];
    /*
     * Re-create the texture if the size or format changed since last creation.
     * glTexImage2D is allowed to resize/redefine a texture's storage (it is
     * not glTexSubImage2D). Without this, Minecraft's max-texture-size probe
     * (which creates progressively larger textures) would keep hitting the
     * first (small) MTLTexture and fail to upload, causing it to fall back to
     * GL_MAX_TEXTURE_SIZE = 1024 and then reject the window size.
     */
    if (existing) {
        bool size_changed = (int)existing.width  != MAX(1, width) ||
                            (int)existing.height != MAX(1, height);
        bool format_changed = existing.pixelFormat != gl_internal_to_mtl(internal_format);
        if (size_changed || format_changed) {
            [g_textures() removeObjectForKey:key(name)];
            existing = nil;
        } else {
            return (__bridge void*)existing;
        }
    }

    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = gl_target_to_mtl(target, samples);
    desc.pixelFormat = gl_internal_to_mtl(internal_format);
    desc.width  = MAX(1, width);
    desc.height = MAX(1, height);
    if (desc.textureType == MTLTextureType3D ||
        desc.textureType == MTLTextureType2DArray ||
        desc.textureType == MTLTextureType1DArray ||
        desc.textureType == MTLTextureTypeCube) {
        desc.depth = MAX(1, depth);
        if (desc.textureType == MTLTextureType2DArray ||
            desc.textureType == MTLTextureType1DArray) {
            desc.arrayLength = MAX(1, depth);
            desc.depth = 1;
        }
    }
    desc.mipmapLevelCount = MAX(1, levels);
    desc.sampleCount = MAX(1, samples);
    desc.usage = mtl_texture_usage(target);
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [dev newTextureWithDescriptor:desc];
    g_textures()[key(name)] = tex;
    return (__bridge void*)tex;
}

// bytes per source pixel given (format,type); 0 => unsupported/needs conversion
static size_t src_bytes_per_pixel(GLenum format, GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE:
            switch (format) {
                case GL_RED: case GL_ALPHA: case GL_LUMINANCE: case GL_R8: return 1;
                case GL_RG:  case GL_LUMINANCE_ALPHA: case GL_RG8:        return 2;
                case GL_RGB: case GL_BGR:                                  return 3;
                case GL_RGBA: case GL_BGRA:                                return 4;
                default: return 0;
            }
        case GL_UNSIGNED_SHORT_5_6_5:
        case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_5_5_5_1:
        case GL_HALF_FLOAT:       return 2;
        case GL_FLOAT:
            switch (format) {
                case GL_RED: return 4;
                case GL_RG:  return 8;
                case GL_RGB: return 12;
                case GL_RGBA:return 16;
                default: return 0;
            }
        case GL_UNSIGNED_INT_24_8: return 4;
        default: return 0;
    }
}

void metal_texture_upload(GLuint name, int level, int x, int y, int z,
                          int w, int h, int d, GLenum format, GLenum type,
                          const void* pixels, int unpack_alignment) {
    id<MTLTexture> tex = g_textures()[key(name)];
    if (!tex || !pixels || w <= 0 || h <= 0) return;

    // Bounds check: skip upload if the region exceeds the texture dimensions.
    // This prevents Metal validation errors when the app uploads to a region
    // that was valid at glTexImage2D time but the texture hasn't been resized
    // yet (or the probe created a smaller texture than expected).
    NSUInteger texW = tex.width;
    NSUInteger texH = tex.height;
    if ((NSUInteger)(x + w) > texW || (NSUInteger)(y + h) > texH) {
        // Region out of bounds — the texture is too small for this upload.
        // This is a normal occurrence during texture-size probing; just skip.
        return;
    }

    size_t bpp = src_bytes_per_pixel(format, type);
    if (bpp == 0) return; // unsupported conversion path (skipped for bring-up)

    size_t row_bytes = (size_t)w * bpp;
    size_t aligned_row = row_bytes;
    if (unpack_alignment > 1) {
        aligned_row = (row_bytes + unpack_alignment - 1) & ~((size_t)unpack_alignment - 1);
    }

    MTLRegion region = MTLRegionMake2D(x, y, w, h);
    if (tex.textureType == MTLTextureType3D) {
        region = MTLRegionMake3D(x, y, z, w, h, MAX(1,d));
        [tex replaceRegion:region
               mipmapLevel:level
                     slice:0
                 withBytes:pixels
               bytesPerRow:aligned_row
             bytesPerImage:aligned_row * (size_t)h];
    } else if (tex.textureType == MTLTextureType2DArray ||
               tex.textureType == MTLTextureTypeCube) {
        [tex replaceRegion:MTLRegionMake2D(x, y, w, h)
               mipmapLevel:level
                     slice:(NSUInteger)z
                 withBytes:pixels
               bytesPerRow:aligned_row
             bytesPerImage:aligned_row * (size_t)h];
    } else {
        [tex replaceRegion:region
               mipmapLevel:level
                     slice:0
                 withBytes:pixels
               bytesPerRow:aligned_row
             bytesPerImage:aligned_row * (size_t)h];
    }
}

void metal_texture_set_params(GLuint name, GLint min_filter, GLint mag_filter,
                              GLint wrap_s, GLint wrap_t, GLint wrap_r,
                              const float* border_color) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev || name == 0) return;
    if (g_samplers()[key(name)]) return; // cached; params change rarely in MC

    MTLSamplerDescriptor* d = [MTLSamplerDescriptor new];
    auto mtlfilt = [](GLint f) -> MTLSamplerMinMagFilter {
        return (f == GL_LINEAR) ? MTLSamplerMinMagFilterLinear
                                : MTLSamplerMinMagFilterNearest;
    };
    auto mtlmip = [](GLint f) -> MTLSamplerMipFilter {
        if (f == GL_NEAREST_MIPMAP_NEAREST || f == GL_LINEAR_MIPMAP_NEAREST)
            return MTLSamplerMipFilterNearest;
        if (f == GL_NEAREST_MIPMAP_LINEAR  || f == GL_LINEAR_MIPMAP_LINEAR)
            return MTLSamplerMipFilterLinear;
        return MTLSamplerMipFilterNotMipmapped;
    };
    d.minFilter = mtlfilt(mag_filter);
    d.magFilter = mtlfilt(mag_filter);
    d.mipFilter = mtlmip(min_filter);
    auto mtlwrap = [](GLint w) -> MTLSamplerAddressMode {
        switch (w) {
            case GL_CLAMP_TO_EDGE:   return MTLSamplerAddressModeClampToEdge;
            case GL_CLAMP_TO_BORDER: return MTLSamplerAddressModeClampToBorderColor;
            case GL_MIRRORED_REPEAT: return MTLSamplerAddressModeMirrorRepeat;
            case GL_MIRROR_CLAMP_TO_EDGE: return MTLSamplerAddressModeMirrorClampToEdge;
            default:                 return MTLSamplerAddressModeRepeat;
        }
    };
    d.sAddressMode = mtlwrap(wrap_s);
    d.tAddressMode = mtlwrap(wrap_t);
    d.rAddressMode = mtlwrap(wrap_r);
    if (border_color) {
        if (border_color[0] == 0 && border_color[1] == 0 &&
            border_color[2] == 0 && border_color[3] == 1)
            d.borderColor = MTLSamplerBorderColorOpaqueBlack; // closest
        else
            d.borderColor = MTLSamplerBorderColorTransparentBlack;
    }
    d.maxAnisotropy = 1;
    id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:d];
    g_samplers()[key(name)] = s;
}

void* metal_get_texture(GLuint name) {
    id<MTLTexture> tex = g_textures()[key(name)];
    return (__bridge void*)tex;
}

void metal_delete_texture(GLuint name) {
    [g_textures() removeObjectForKey:key(name)];
    [g_samplers() removeObjectForKey:key(name)];
}

void* metal_get_or_create_sampler(GLuint name, GLint min_filter, GLint mag_filter,
                                  GLint wrap_s, GLint wrap_t, GLint wrap_r,
                                  const float* border_color) {
    id<MTLSamplerState> s = g_samplers()[key(name)];
    if (s) return (__bridge void*)s;
    metal_texture_set_params(name, min_filter, mag_filter, wrap_s, wrap_t, wrap_r, border_color);
    return (__bridge void*)g_samplers()[key(name)];
}

int metal_pixel_format_for_gl(GLenum internal_format) {
    return (int)gl_internal_to_mtl(internal_format);
}

int metal_texture_pixel_format(void* texture_handle) {
    if (!texture_handle) return 0;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture_handle;
    return (int)tex.pixelFormat;
}

} // extern "C"
