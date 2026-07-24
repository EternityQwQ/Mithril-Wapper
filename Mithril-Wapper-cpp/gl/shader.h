// Mithril-Wapper - shader.h
// GLSL -> SPIR-V (glslang) -> MSL (spirv-cross) translation, with a cache.
#ifndef MITHRIL_SHADER_H
#define MITHRIL_SHADER_H

#include <string>
#include <unordered_map>

#include <GL/gl.h>

namespace mithril {

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

} // namespace mithril

#endif // MITHRIL_SHADER_H
