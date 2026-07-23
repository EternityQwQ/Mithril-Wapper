// Mithril-Wapper - src/drawing.cpp
// Core drawing path: glDrawArrays / glDrawElements / instanced variants ->
// Metal render-pass + encoder orchestration.
//
// Pipeline: resolve VAO + program + FBO attachments -> get-or-create
// MTLRenderPipelineState -> begin render pass (Load action) -> bind vertex
// buffers + set viewport/scissor/cull/depth/mask -> issue draw -> end pass.
#include "includes.h"
#include "framebuffer.h"

#include <algorithm>
#include <cstring>

extern "C" {

static void prepare_draw(GLenum mode) {
    (void)mode;

    // Resolve current program + its MSL.
    mithril::Program* prog = mithril::state_get_program(g_state->currentProgram);
    if (!prog || !prog->linked) return;

    // Resolve current draw FBO attachments (color + depth textures + size).
    void* colors[8] = {nullptr};
    void* depth_tex = nullptr;
    int w = 0, h = 0;
    int color_count = mithril::collect_draw_fbo_attachments(colors, &depth_tex, &w, &h);

    // Compute color attachment MTLPixelFormats.
    int color_formats[8] = {0,0,0,0,0,0,0,0};
    mithril::Framebuffer* fbo = mithril::state_get_framebuffer(g_state->currentDrawFBO);
    if (fbo) {
        for (int i = 0; i < color_count; ++i) {
            GLuint t = fbo->colors[i].texture;
            mithril::Texture* tex = mithril::state_get_texture(t);
            if (tex) color_formats[i] = metal_pixel_format_for_gl((GLenum)tex->internalFormat);
        }
    }
    // Depth format from the bound depth texture.
    int depth_format = 0;
    if (fbo && fbo->depth.texture) {
        mithril::Texture* dt = mithril::state_get_texture(fbo->depth.texture);
        if (dt) depth_format = metal_pixel_format_for_gl((GLenum)dt->internalFormat);
    }

    // Build the vertex attribute descriptor array.
    mithril::VertexArray* vao = mithril::state_get_vao(g_state->currentVAO);
    if (!vao) vao = mithril::state_get_vao(0);
    MetalVertexAttrib attribs[mithril::kMaxVertexAttribs];
    int attrib_count = 0;
    for (int i = 0; i < mithril::kMaxVertexAttribs; ++i) {
        const mithril::VertexAttrib& a = vao->attribs[i];
        if (!a.enabled) continue;
        MetalVertexAttrib& m = attribs[attrib_count++];
        m.location     = i;
        m.size         = a.size;
        m.type         = a.type;
        m.normalized   = a.normalized ? 1 : 0;
        m.integer      = a.integer ? 1 : 0;
        m.stride       = a.stride;
        m.offset       = (int)(intptr_t)a.pointer;
        m.enabled      = 1;
        m.buffer_name  = a.boundBuffer;
    }

    // Get-or-create the render pipeline state.
    void* pipeline = metal_get_or_create_pipeline(
        prog->id,
        prog->vertexMSL.c_str(),
        prog->fragmentMSL.c_str(),
        attribs, attrib_count,
        color_formats, color_count,
        depth_format, mode);
    if (!pipeline) return;

    // Begin render pass (Load action preserves previous contents).
    metal_set_load_load();
    metal_begin_render_pass(colors, color_count, depth_tex, w, h, 1);

    // Bind pipeline + encoder state.
    metal_encoder_set_pipeline(pipeline);
    metal_encoder_set_viewport(g_state->viewportX, g_state->viewportY,
                               g_state->viewportW, g_state->viewportH,
                               g_state->depthNear, g_state->depthFar);
    if (g_state->scissorTest) {
        metal_encoder_set_scissor(g_state->scissorX, g_state->scissorY,
                                  g_state->scissorW, g_state->scissorH);
    }
    if (g_state->cullFace) {
        int mode_cull = 0;
        if (g_state->cullMode == GL_FRONT) mode_cull = 1;
        else if (g_state->cullMode == GL_BACK) mode_cull = 2;
        metal_encoder_set_cull_mode(mode_cull);
        metal_encoder_set_front_facing(g_state->frontFace == GL_CCW ? 1 : 0);
    }
    metal_encoder_set_color_write_mask(
        g_state->colorMask[0], g_state->colorMask[1],
        g_state->colorMask[2], g_state->colorMask[3]);
    metal_encoder_set_depth_test(
        g_state->depthTest ? 1 : 0,
        g_state->depthMask ? 1 : 0,
        (int)g_state->depthFunc);
    if (g_state->polygonOffsetFill) {
        metal_encoder_set_depth_bias(g_state->polygonOffsetUnits, 0.0f);
    }
    if (g_state->blend) {
        metal_encoder_set_blend_color(
            g_state->blendColor[0], g_state->blendColor[1],
            g_state->blendColor[2], g_state->blendColor[3]);
    }

    // Bind vertex buffers — one MTLBuffer per enabled attribute, at index
    // == attribute location (matches the vertex descriptor layout).
    for (int i = 0; i < attrib_count; ++i) {
        MetalVertexAttrib& m = attribs[i];
        void* buf = metal_get_buffer(m.buffer_name);
        if (buf) {
            metal_encoder_set_vertex_buffer(m.location, buf, m.offset);
        }
    }

    // Bind textures bound to the current program (best-effort: bind the first
    // few texture units to fragment-stage texture/sampler slots).
    for (int u = 0; u < mithril::kMaxTextureUnits && u < 32; ++u) {
        GLuint tex_id = g_state->boundTextures[u];
        if (!tex_id) continue;
        void* tex = metal_get_texture(tex_id);
        void* samp = metal_get_or_create_sampler(
            tex_id, GL_LINEAR, GL_LINEAR, GL_REPEAT, GL_REPEAT, GL_REPEAT, nullptr);
        if (tex)  metal_encoder_set_fragment_texture(u, tex);
        if (samp) metal_encoder_set_fragment_sampler(u, samp);
    }
}

static void end_draw(void) {
    metal_end_render_pass();
    metal_commit();
}

static int index_type_to_int(GLenum type) {
    return (type == GL_UNSIGNED_INT) ? 1 : 0;
}

void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    MITHRIL_ENSURE_INIT();
    prepare_draw(mode);
    metal_encoder_draw_arrays((int)mode, (int)first, (int)count);
    end_draw();
}

void glDrawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei primcount) {
    MITHRIL_ENSURE_INIT();
    prepare_draw(mode);
    metal_encoder_draw_arrays_instanced((int)mode, (int)first, (int)count, (int)primcount);
    end_draw();
}

void glDrawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count,
                                       GLsizei primcount, GLuint baseinstance) {
    MITHRIL_ENSURE_INIT();
    (void)baseinstance; // base-instance is not exposed by the current encoder wrapper
    prepare_draw(mode);
    metal_encoder_draw_arrays_instanced((int)mode, (int)first, (int)count, (int)primcount);
    end_draw();
}

void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices) {
    MITHRIL_ENSURE_INIT();
    prepare_draw(mode);
    // If a VBO is bound for GL_ELEMENT_ARRAY_BUFFER, indices is an offset into it.
    mithril::VertexArray* vao = mithril::state_get_vao(g_state->currentVAO);
    GLuint ib_name = vao ? vao->elementArrayBuffer : 0;
    void* ib = metal_get_buffer(ib_name);
    if (ib) {
        metal_encoder_draw_indexed((int)mode, (int)count, index_type_to_int(type),
                                   ib, (int)(intptr_t)indices);
    } else if (indices) {
        // Client-space index pointer: stage into a transient MTLBuffer.
        size_t elem = (type == GL_UNSIGNED_INT) ? 4 : 2;
        GLuint transient = (GLuint)(uintptr_t)indices; // use address as throwaway name
        void* staged = metal_get_or_create_buffer(transient | 0x80000000u,
                                                  indices, (size_t)count * elem);
        metal_encoder_draw_indexed((int)mode, (int)count, index_type_to_int(type),
                                   staged, 0);
    }
    end_draw();
}

void glDrawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type,
                              const void* indices, GLint basevertex) {
    MITHRIL_ENSURE_INIT();
    (void)basevertex; // base-vertex not exposed by the current encoder wrapper
    glDrawElements(mode, count, type, indices);
}

void glDrawElementsInstanced(GLenum mode, GLsizei count, GLenum type,
                             const void* indices, GLsizei primcount) {
    MITHRIL_ENSURE_INIT();
    prepare_draw(mode);
    mithril::VertexArray* vao = mithril::state_get_vao(g_state->currentVAO);
    GLuint ib_name = vao ? vao->elementArrayBuffer : 0;
    void* ib = metal_get_buffer(ib_name);
    if (ib) {
        metal_encoder_draw_indexed_instanced((int)mode, (int)count,
                                             index_type_to_int(type), ib,
                                             (int)(intptr_t)indices, (int)primcount);
    } else if (indices) {
        size_t elem = (type == GL_UNSIGNED_INT) ? 4 : 2;
        GLuint transient = (GLuint)(uintptr_t)indices;
        void* staged = metal_get_or_create_buffer(transient | 0x80000000u,
                                                  indices, (size_t)count * elem);
        metal_encoder_draw_indexed_instanced((int)mode, (int)count,
                                             index_type_to_int(type), staged, 0,
                                             (int)primcount);
    }
    end_draw();
}

void glDrawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type,
                                       const void* indices, GLsizei primcount,
                                       GLint basevertex) {
    MITHRIL_ENSURE_INIT();
    (void)basevertex;
    glDrawElementsInstanced(mode, count, type, indices, primcount);
}

void glDrawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type,
                                         const void* indices, GLsizei primcount,
                                         GLuint baseinstance) {
    MITHRIL_ENSURE_INIT();
    (void)baseinstance;
    glDrawElementsInstanced(mode, count, type, indices, primcount);
}

void glDrawRangeElements(GLenum mode, GLuint start, GLuint end, GLsizei count,
                         GLenum type, const void* indices) {
    MITHRIL_ENSURE_INIT();
    (void)start; (void)end;
    glDrawElements(mode, count, type, indices);
}

void glDrawElementsBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type,
                                          const void* indices, GLint basevertex,
                                          GLuint baseinstance) {
    MITHRIL_ENSURE_INIT();
    (void)basevertex; (void)baseinstance;
    glDrawElements(mode, count, type, indices);
}

void glMultiDrawArrays(GLenum mode, const GLint* first, const GLsizei* count, GLsizei drawcount) {
    MITHRIL_ENSURE_INIT();
    if (!first || !count || drawcount <= 0) return;
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) glDrawArrays(mode, first[i], count[i]);
    }
}

void glMultiDrawElements(GLenum mode, const GLsizei* count, GLenum type,
                         const void* const* indices, GLsizei drawcount) {
    MITHRIL_ENSURE_INIT();
    if (!count || !indices || drawcount <= 0) return;
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) glDrawElements(mode, count[i], type, indices[i]);
    }
}

/* ---- Sync objects ---- */
GLsync glFenceSync(GLenum condition, GLbitfield flags) {
    MITHRIL_ENSURE_INIT();
    (void)condition; (void)flags;
    // Return a non-null sentinel pointer. Real implementation would create an
    // MTLSharedEvent or MTLFence; sufficient for the sync-id pattern used by
    // most GL apps (glClientWaitSync returning ALREADY_SIGNALED immediately).
    return (GLsync)0x1;
}

void glDeleteSync(GLsync sync) {
    MITHRIL_ENSURE_INIT();
    (void)sync;
}

GLenum glClientWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout) {
    MITHRIL_ENSURE_INIT();
    (void)sync; (void)flags; (void)timeout;
    return GL_ALREADY_SIGNALED;
}

void glWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout) {
    MITHRIL_ENSURE_INIT();
    (void)sync; (void)flags; (void)timeout;
}

GLboolean glIsSync(GLsync sync) {
    MITHRIL_ENSURE_INIT();
    return sync ? GL_TRUE : GL_FALSE;
}

} // extern "C"
