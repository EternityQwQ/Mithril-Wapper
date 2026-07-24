// Mithril-Wapper - shader.h
// GLSL -> SPIR-V (glslang) -> MSL (spirv-cross) translation, with a cache.
#ifndef MITHRIL_SHADER_H
#define MITHRIL_SHADER_H

#include <string>
#include <unordered_map>
#include <vector>

#include <GL/gl.h>

namespace mithril {

// One reflected uniform's Metal binding info.
//   name        : GLSL uniform name (e.g. "ProjMat")
//   msl_buffer  : Metal buffer index ([[buffer(N)]]) the MSL shader expects
//   msl_offset  : byte offset within the buffer (0 for standalone uniforms)
//   is_sampler  : true if this is a sampler (texture), not a plain uniform.
//                 Samplers use [[texture(N)]] in MSL, not [[buffer(N)]].
//                 The texture slot is stored in msl_buffer.
struct ReflectedUniform {
    std::string name;
    GLenum      type = 0;
    GLint       size = 0;
    unsigned    msl_buffer = 0;
    unsigned    msl_offset = 0;
    bool        is_sampler = false;
};

// Translate a desktop GLSL Core Profile source string into Metal Shading
// Language. Returns true on success. On failure, out_info_log is populated.
// Results are cached by (stage, source hash).
//
// attrib_bindings maps attribute names to the location the application
// requested via glBindAttribLocation(). When non-empty, the translator injects
// `layout(location=N)` qualifiers into the GLSL source before compilation so
// that the SPIR-V (and thus the generated MSL [[attribute(N)]]) matches the
// application's vertex descriptor layout. Pass nullptr when no explicit
// bindings are needed (falls back to glslang auto-mapping).
bool shader_translate(GLenum gl_stage, const std::string& glsl_source,
                      std::string& out_msl, std::string& out_info_log,
                      const std::unordered_map<std::string, GLuint>* attrib_bindings = nullptr);

/*
 * Reflect the Metal buffer binding info for every standalone (non-block)
 * uniform in the given GLSL source. This compiles the GLSL to SPIR-V then
 * asks SPIRV-Cross's MSL backend which [[buffer(N)]] slot it assigned to each
 * uniform. The result is used by drawing.cpp to bind uniform MTLBuffers to the
 * exact slots the MSL shader reads from, instead of guessing slot 30+idx.
 *
 * Returns true on success. out_uniforms is cleared and filled.
 */
bool shader_reflect_uniforms(GLenum gl_stage, const std::string& glsl_source,
                            std::vector<ReflectedUniform>& out_uniforms,
                            std::string& out_info_log,
                            const std::unordered_map<std::string, GLuint>* attrib_bindings = nullptr);

} // namespace mithril

#endif // MITHRIL_SHADER_H
