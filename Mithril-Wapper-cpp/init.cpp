// Mithril-Wapper - init.cpp
// Static initialisation: ensures the state machine + Metal backend come up
// before any GL call is serviced (mirrors MobileGlues' static-block pattern).
#include "includes.h"

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
}

} // extern "C"
