// Mithril-Wapper - gl/getter_gpu.mm
// Builds the GL_RENDERER string from the live Metal device so Minecraft's F3
// screen and crash reports show real GPU info instead of a static placeholder.
//
// Mirrors MobileGlues' getGpuName() pattern, but queries MTLDevice directly
// (Mithril has no ANGLE layer in between).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "../includes.h"
#include <string>
#include <cstdio>

extern "C" const char* mithril_get_gpu_renderer_string(void) {
    static std::string cached;
    if (!cached.empty()) return cached.c_str();

    id<MTLDevice> dev = (__bridge id<MTLDevice>)metal_device();
    if (!dev) {
        cached = "Mithril-Wapper (Metal backend, no device)";
        return cached.c_str();
    }

    std::string gpuName = std::string(dev.name.UTF8String ?: "Apple GPU");

    // Device family / feature set gives the Metal version tier.
    // MTLDevice's supportsFamily queries (iOS 13+) let us report the Metal
    // feature family; fall back to "Metal 2" for older OS.
    std::string metalTier = "Metal 2";
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13, *)) {
        if ([dev supportsFamily:MTLGPUFamilyApple7])      metalTier = "Metal 3 (Apple7)";
        else if ([dev supportsFamily:MTLGPUFamilyApple6]) metalTier = "Metal 2 (Apple6)";
        else if ([dev supportsFamily:MTLGPUFamilyApple5]) metalTier = "Metal 2 (Apple5)";
        else if ([dev supportsFamily:MTLGPUFamilyApple4]) metalTier = "Metal 2 (Apple4)";
        else if ([dev supportsFamily:MTLGPUFamilyApple3]) metalTier = "Metal 2 (Apple3)";
        else if ([dev supportsFamily:MTLGPUFamilyApple2]) metalTier = "Metal 2 (Apple2)";
        else if ([dev supportsFamily:MTLGPUFamilyApple1]) metalTier = "Metal 2 (Apple1)";
        else if ([dev supportsFamily:MTLGPUFamilyCommon3]) metalTier = "Metal 2 (Common3)";
        else if ([dev supportsFamily:MTLGPUFamilyCommon2]) metalTier = "Metal 2 (Common2)";
        else if ([dev supportsFamily:MTLGPUFamilyCommon1]) metalTier = "Metal 2 (Common1)";
    }
#endif

    // VRAM: MTLDevice has no direct VRAM query on iOS (unified memory), but we
    // can report the recommended max working set size (MTLDevice
    // .recommendedMaxWorkingSetSize) which approximates the GPU-accessible
    // memory budget. On macOS this is close to VRAM; on iOS (unified memory)
    // it's a fraction of total RAM.
    uint64_t workingSet = 0;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13, *)) {
        workingSet = dev.recommendedMaxWorkingSetSize;
    }
#endif
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
