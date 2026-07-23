// Mithril-Wapper - src/framebuffer.h
#ifndef MITHRIL_FRAMEBUFFER_H
#define MITHRIL_FRAMEBUFFER_H

namespace mithril {

// Resolve the current draw framebuffer's attachments into Metal texture
// handles. Returns the number of valid color attachments (<=8). *out_depth is
// set to the depth MTLTexture or nullptr. *out_w/*out_h are the render area.
int collect_draw_fbo_attachments(void* out_color[8], void** out_depth,
                                 int* out_w, int* out_h);

} // namespace mithril

#endif // MITHRIL_FRAMEBUFFER_H
