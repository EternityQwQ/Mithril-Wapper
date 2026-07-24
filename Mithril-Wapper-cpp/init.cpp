// Mithril-Wapper - init.cpp
// Static initialisation: ensures the state machine + Metal backend come up
// before any GL call is serviced (mirrors MobileGlues' static-block pattern).
#include "includes.h"

#if MITHRIL_METAL
extern "C" const char* mithril_get_gpu_renderer_string(void);
extern "C" void* metal_device(void);
#endif

namespace {
struct static_block_t {
    static_block_t() { proc_init(); }
};
static static_block_t g_static_block;
}

extern "C" {

void proc_init(void) {
    static bool done = false;
    if (done) return;
    done = true;

    ::mithril::state_init();
    metal_init();

    MITHRIL_LOG_INFO("init", "Mithril-Wapper initialised (Metal backend)");

#if MITHRIL_METAL
    // Log renderer info at startup so the GPU identity is visible in the
    // launch log (mirrors MobileGlues' LOG_V("Initializing %s ...") pattern).
    // mithril_get_gpu_renderer_string() queries the live MTLDevice and caches
    // the result, so the same string later appears in GL_RENDERER queries.
    const char* gpu_info = mithril_get_gpu_renderer_string();
    MITHRIL_LOG_INFO("renderer", "GPU: %s", gpu_info ? gpu_info : "(unknown)");

    if (void* dev = metal_device(); dev) {
        MITHRIL_LOG_INFO("renderer", "Metal device available: yes");
    } else {
        MITHRIL_LOG_WARN("renderer", "Metal device available: no");
    }
#endif
}

} // extern "C"
