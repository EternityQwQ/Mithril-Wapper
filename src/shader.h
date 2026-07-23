// Mithril-Wapper - src/shader.h
// GLSL -> SPIR-V (glslang) -> MSL (spirv-cross) translation, with a cache.
#ifndef MITHRIL_SHADER_H
#define MITHRIL_SHADER_H

#include <string>

#include <GL/gl.h>

namespace mithril {

// Translate a desktop GLSL Core Profile source string into Metal Shading
// Language. Returns true on success. On failure, out_info_log is populated.
// Results are cached by (stage, source hash).
bool shader_translate(GLenum gl_stage, const std::string& glsl_source,
                      std::string& out_msl, std::string& out_info_log);

} // namespace mithril

#endif // MITHRIL_SHADER_H
