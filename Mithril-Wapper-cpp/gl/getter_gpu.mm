// Mithril-Wapper - gl/getter_gpu.mm
// Builds the GL_RENDERER string from the live Metal device so Minecraft's F3
// screen and crash reports show real GPU info instead of a static placeholder.
//
// Mirrors MobileGlues' getGpuName() pattern, but queries MTLDevice directly
// (Mithril has no ANGLE layer in between).
//
// Also provides:
//   mithril_get_metal_device_name() — raw GPU name (for backend bypass queries)
//   mithril_get_metal_tier_string() — Metal feature family tier
//   mithril_get_vram_bytes()        — recommended working set size
//   mithril_get_settings_dump()     — multi-line config dump for F3 screen
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "../includes.h"
#include <string>
#include <sstream>
#include <cstdio>

static std::string get_metal_tier(id<MTLDevice> dev) {
    std::string tier = "Metal 2";
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13, *)) {
        if ([dev supportsFamily:MTLGPUFamilyApple7])      tier = "Metal 3 (Apple7)";
        else if ([dev supportsFamily:MTLGPUFamilyApple6]) tier = "Metal 2 (Apple6)";
        else if ([dev supportsFamily:MTLGPUFamilyApple5]) tier = "Metal 2 (Apple5)";
        else if ([dev supportsFamily:MTLGPUFamilyApple4]) tier = "Metal 2 (Apple4)";
        else if ([dev supportsFamily:MTLGPUFamilyApple3]) tier = "Metal 2 (Apple3)";
        else if ([dev supportsFamily:MTLGPUFamilyApple2]) tier = "Metal 2 (Apple2)";
        else if ([dev supportsFamily:MTLGPUFamilyApple1]) tier = "Metal 2 (Apple1)";
        else if ([dev supportsFamily:MTLGPUFamilyCommon3]) tier = "Metal 2 (Common3)";
        else if ([dev supportsFamily:MTLGPUFamilyCommon2]) tier = "Metal 2 (Common2)";
        else if ([dev supportsFamily:MTLGPUFamilyCommon1]) tier = "Metal 2 (Common1)";
    }
#endif
    return tier;
}

static uint64_t get_vram(id<MTLDevice> dev) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13, *)) {
        return dev.recommendedMaxWorkingSetSize;
    }
#endif
    return 0;
}

extern "C" const char* mithril_get_gpu_renderer_string(void) {
    static std::string cached;
    if (!cached.empty()) return cached.c_str();

    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) {
        cached = "Mithril-Wapper (Metal backend, no device)";
        return cached.c_str();
    }

    std::string gpuName = std::string(dev.name.UTF8String ?: "Apple GPU");
    std::string metalTier = get_metal_tier(dev);
    uint64_t workingSet = get_vram(dev);

    char vramBuf[48] = {0};
    if (workingSet > 0) {
        snprintf(vramBuf, sizeof(vramBuf), ", %llu MB VRAM",
                 workingSet / (1024ULL * 1024ULL));
    }

    bool unifiedMem = dev.hasUnifiedMemory;
    if (unifiedMem) {
        cached = gpuName + " | " + metalTier + " | Mithril-Wapper (Unified Memory"
               + vramBuf + ")";
    } else {
        cached = gpuName + " | " + metalTier + " | Mithril-Wapper" + vramBuf;
    }
    return cached.c_str();
}

extern "C" const char* mithril_get_metal_device_name(void) {
    static std::string name;
    if (!name.empty()) return name.c_str();
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) { name = "Apple GPU"; return name.c_str(); }
    name = dev.name.UTF8String ?: "Apple GPU";
    return name.c_str();
}

extern "C" const char* mithril_get_metal_tier_string(void) {
    static std::string tier;
    if (!tier.empty()) return tier.c_str();
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) { tier = "Metal 2"; return tier.c_str(); }
    tier = get_metal_tier(dev);
    return tier.c_str();
}

extern "C" uint64_t mithril_get_vram_bytes(void) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) return 0;
    return get_vram(dev);
}

/*
 * Multi-line config dump displayed on Minecraft's F3 debug screen when a mod
 * queries glGetString(MITHRIL_SETTINGS) (= glGetString(0x0402)).
 * Mirrors MobileGlues' dump_settings_string() output.
 */
extern "C" const char* mithril_get_settings_dump(void) {
    static std::string dump;
    if (!dump.empty()) return dump.c_str();

    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    std::ostringstream ss;

    ss << "Mithril-Wapper 1.0 (OpenGL 3.3 -> Metal 2)\n";
    ss << "  Backend: Metal 2 (native)\n";

    if (dev) {
        ss << "  GPU: " << (dev.name.UTF8String ?: "Apple GPU") << "\n";
        ss << "  Metal tier: " << get_metal_tier(dev) << "\n";
        uint64_t vram = get_vram(dev);
        if (vram > 0) {
            ss << "  VRAM: " << (vram / (1024ULL * 1024ULL)) << " MB";
            if (dev.hasUnifiedMemory) ss << " (unified memory)";
            ss << "\n";
        }
        ss << "  Unified memory: " << (dev.hasUnifiedMemory ? "Yes" : "No") << "\n";
    } else {
        ss << "  GPU: (no Metal device)\n";
    }

    ss << "  Shader pipeline: GLSL -> SPIR-V (glslang) -> MSL (SPIRV-Cross)\n";
    ss << "  Depth/stencil: Depth32Float_Stencil8\n";
    ss << "  Color format: BGRA8Unorm (CAMetalLayer)\n";
    ss << "  EGL: 1.5 (Metal-backed)\n";
    ss << "  GL version: 3.3 Core Profile\n";
    ss << "  GLSL version: 3.30\n";

    dump = ss.str();
    return dump.c_str();
}
