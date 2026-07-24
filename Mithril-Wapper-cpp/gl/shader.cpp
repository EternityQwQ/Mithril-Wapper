// Mithril-Wapper - shader.cpp
// GLSL (desktop Core Profile) -> SPIR-V -> MSL translation pipeline.
//   * glslang compiles GLSL to SPIR-V (OpenGL client, not Vulkan — mirrors
//     MobileGlues' approach so desktop GLSL 150+ shaders like Minecraft's
//     blit_screen compile without requiring explicit layout(location=N))
//   * spirv-cross transpiles SPIR-V to Metal Shading Language (MSL backend)
// Mirrors the MobileGlues pipeline but targets MSL instead of GLSL ES.
#include "shader.h"
#include "log.h"

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_cross_c.h>

#include <cstdint>
#include <functional>
#include <mutex>
#include <regex>
#include <unordered_map>

namespace mithril {
namespace {

struct GlslangInit {
    GlslangInit()  { glslang::InitializeProcess(); }
    ~GlslangInit() { /* process-lifetime; no finalize needed */ }
};
GlslangInit& glslang_init() {
    static GlslangInit g;
    return g;
}

EShLanguage to_esh_stage(GLenum gl) {
    switch (gl) {
        case GL_VERTEX_SHADER:          return EShLangVertex;
        case GL_FRAGMENT_SHADER:        return EShLangFragment;
        case GL_GEOMETRY_SHADER:        return EShLangGeometry;
        case GL_TESS_CONTROL_SHADER:    return EShLangTessControl;
        case GL_TESS_EVALUATION_SHADER: return EShLangTessEvaluation;
        case GL_COMPUTE_SHADER:         return EShLangCompute;
        default:                        return EShLangCount;
    }
}

// Extract the GLSL #version number. Returns -1 if not found.
int get_glsl_version(const std::string& src) {
    static std::regex version_pattern(R"(#version\s+(\d{3}))");
    std::smatch match;
    if (std::regex_search(src, match, version_pattern)) {
        return std::stoi(match[1].str());
    }
    return -1;
}

// Ensure the GLSL source has a usable version. If missing, prepend #version 150.
// If below 140, upgrade to 150 (mirrors MobileGlues' get_or_add_glsl_version).
int ensure_glsl_version(std::string& src) {
    int ver = get_glsl_version(src);
    if (ver == -1) {
        ver = 150;
        src.insert(0, "#version 150\n");
    } else if (ver < 140) {
        // Force upgrade: replace the #version line.
        size_t pos = src.find("#version");
        size_t line_end = src.find('\n', pos);
        if (line_end == std::string::npos) line_end = src.length();
        src.replace(pos, line_end - pos, "#version 150 compatibility");
        ver = 150;
    }
    return ver;
}

/*
 * Inject `layout(location=N)` qualifiers into GLSL `in` declarations based on
 * the application's glBindAttribLocation() mappings. Minecraft 1.21 shaders
 * use `#version 150` with bare `in vec3 Position;` declarations and rely on
 * glBindAttribLocation to assign locations at runtime. If we let glslang
 * auto-map locations (setAutoMapLocations), the resulting SPIR-V locations may
 * not match the application's vertex descriptor, causing attribute misbinding
 * in Metal. This function rewrites each `in` declaration that has a binding
 * into `layout(location=N) in ...` so the SPIR-V location is fixed.
 *
 * Only vertex shaders are affected. The rewrite is conservative: it matches
 * declarations of the form `in <type> <name>;` and skips lines that already
 * have a layout() qualifier.
 */
void apply_attrib_bindings(std::string& src, GLenum gl_stage,
                           const std::unordered_map<std::string, GLuint>* bindings) {
    if (!bindings || bindings->empty()) return;
    if (gl_stage != GL_VERTEX_SHADER) return;

    static std::regex in_decl_re(
        R"(^\s*(?:layout\s*\([^)]*\)\s*)?(in|attribute)\s+(\w+)\s+(\w+)\s*(\[[^\]]*\])?\s*;)",
        std::regex::optimize);

    std::string out;
    out.reserve(src.size() + bindings->size() * 24);
    std::string::const_iterator search_start(src.cbegin());
    std::smatch m;
    size_t last_pos = 0;

    while (std::regex_search(search_start, src.cend(), m, in_decl_re)) {
        size_t match_pos = m.position(0) + (search_start - src.cbegin());
        out.append(src, last_pos, match_pos - last_pos);

        const std::string& keyword = m[1].str();   // "in" or "attribute"
        const std::string& vartype = m[2].str();
        const std::string& varname = m[3].str();
        const std::string& array_suffix = m[4].matched ? m[4].str() : std::string();

        auto it = bindings->find(varname);
        if (it != bindings->end()) {
            out += "layout(location=";
            out += std::to_string(it->second);
            out += ") in ";
            out += vartype;
            out += ' ';
            out += varname;
            if (!array_suffix.empty()) out += array_suffix;
            out += ';';
        } else {
            out += m[0].str();
        }

        last_pos = match_pos + m[0].length();
        search_start = m.suffix().first;
    }
    out.append(src, last_pos, std::string::npos);
    src.swap(out);
}

// FNV-1a 64-bit hash for cache keying.
uint64_t fnv1a(const std::string& s) {
    uint64_t h = 1469598103934665603ULL;
    for (char c : s) { h ^= (uint8_t)c; h *= 1099511628211ULL; }
    return h;
}

struct Cache {
    std::mutex mu;
    std::unordered_map<uint64_t, std::string> entries; // key -> MSL
};
Cache& cache() { static Cache c; return c; }

bool glsl_to_spirv(GLenum gl_stage, const std::string& src,
                   std::vector<uint32_t>& spirv, std::string& info,
                   const std::unordered_map<std::string, GLuint>* attrib_bindings) {
    glslang_init();
    EShLanguage stage = to_esh_stage(gl_stage);
    if (stage == EShLangCount) { info = "unsupported shader stage"; return false; }

    // Ensure the source has a usable GLSL version (mirrors MobileGlues'
    // get_or_add_glsl_version). Minecraft's blit_screen uses #version 150,
    // which is fine for the OpenGL SPIR-V client.
    std::string source = src;
    int glsl_version = ensure_glsl_version(source);

    // Inject layout(location=N) from glBindAttribLocation mappings so the
    // SPIR-V stage_input locations match the application's vertex descriptor.
    apply_attrib_bindings(source, gl_stage, attrib_bindings);

    glslang::TShader shader(stage);
    const char* s = source.c_str();
    shader.setStrings(&s, 1);

    // Use OpenGL client (not Vulkan) — this is the critical difference from
    // the previous implementation. With EShClientOpenGL:
    //   * GLSL 150+ is accepted (Vulkan requires 330+)
    //   * setAutoMapLocations(true) auto-assigns locations so shaders without
    //     explicit layout(location=N) compile (fixes the blit_screen error)
    //   * setPreamble("#undef VULKAN\n") prevents Vulkan-only code paths
    // Mirrors MobileGlues' glsl_to_spirv() exactly.
    shader.setEnvInput(glslang::EShSourceGlsl, stage, glslang::EShClientVulkan, glsl_version);
    shader.setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_5);
    shader.setAutoMapLocations(true);
    shader.setPreamble("#undef VULKAN\n");
    shader.setAutoMapBindings(true);

    const EShMessages messages = EShMsgDefault;

    if (!shader.parse(GetDefaultResources(), glsl_version, true, messages)) {
        info = shader.getInfoLog();
        info += shader.getInfoDebugLog();
        return false;
    }

    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages)) {
        info = program.getInfoLog();
        info += program.getInfoDebugLog();
        return false;
    }

    glslang::TIntermediate* inter = program.getIntermediate(stage);
    if (!inter) { info = "no intermediate after link"; return false; }

    glslang::SpvOptions spv_opts;
    spv_opts.disableOptimizer = false;
    glslang::GlslangToSpv(*inter, spirv, &spv_opts);
    if (spirv.empty()) { info = "SPIR-V generation produced no words"; return false; }
    return true;
}

bool spirv_to_msl(const std::vector<uint32_t>& spirv, std::string& out, std::string& info) {
    spvc_context ctx = nullptr;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { info = "spvc_context_create failed"; return false; }

    spvc_parsed_ir ir = nullptr;
    if (spvc_context_parse_spirv(ctx, reinterpret_cast<const SpvId*>(spirv.data()),
                                 spirv.size(), &ir) != SPVC_SUCCESS) {
        info = spvc_context_get_last_error_string(ctx) ? spvc_context_get_last_error_string(ctx) : "parse failed";
        spvc_context_destroy(ctx);
        return false;
    }

    spvc_compiler compiler = nullptr;
    if (spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir,
                                     SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
                                     &compiler) != SPVC_SUCCESS) {
        info = spvc_context_get_last_error_string(ctx) ? spvc_context_get_last_error_string(ctx) : "create_compiler failed";
        spvc_context_destroy(ctx);
        return false;
    }

    spvc_compiler_options opts = nullptr;
    spvc_compiler_create_compiler_options(compiler, &opts);
    // Target iOS Metal Shading Language. Lowest supported device is the A11 SoC
    // (iPhone 8 / 8 Plus / X) running iOS 14.0+, which exposes Metal 2 and MSL
    // 2.3. iOS 14 is the deployment floor, so MSL 2.3 is always available.
    spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_MSL_VERSION,
                                   SPVC_MAKE_MSL_VERSION(2, 3, 0));
    spvc_compiler_install_compiler_options(compiler, opts);

    /*
     * Ensure all vertex stage-in variables have a Location decoration.
     * SPIRV-Cross's MSL backend uses the SPIR-V Location decoration to
     * generate [[attribute(N)]] qualifiers on the stage_in struct. If
     * the GLSL source didn't use layout(location=N) and glslang's
     * auto-map didn't assign locations (which can happen with the OpenGL
     * client), the stage_in struct members will lack [[attribute(N)]]
     * and Metal will reject the vertex function.
     *
     * We enumerate all STAGE_INPUT resources and assign sequential
     * locations (0, 1, 2, ...) to any that lack a Location decoration.
     * This matches the vertex descriptor layout in metal_pipeline.mm
     * where attribute index == location.
     */
    {
        spvc_resources resources = nullptr;
        if (spvc_compiler_create_shader_resources(compiler, &resources) == SPVC_SUCCESS) {
            const spvc_reflected_resource* list = nullptr;
            size_t count = 0;
            if (spvc_resources_get_resource_list_for_type(resources,
                    SPVC_RESOURCE_TYPE_STAGE_INPUT, &list, &count) == SPVC_SUCCESS) {
                const unsigned SpvDecorationLocation = 30;
                unsigned next_location = 0;
                for (size_t i = 0; i < count; ++i) {
                    unsigned existing = spvc_compiler_get_decoration(
                        compiler, list[i].id, (SpvDecoration)SpvDecorationLocation);
                    if (existing == 0) {
                        // No location assigned yet — assign one sequentially.
                        spvc_compiler_set_decoration(
                            compiler, list[i].id,
                            (SpvDecoration)SpvDecorationLocation, next_location);
                        next_location++;
                    } else {
                        next_location = existing + 1;
                    }
                }
            }
        }
    }

    /*
     * Also assign sequential Location decorations to STAGE_OUTPUT resources
     * (vertex-to-fragment varyings). When vertex and fragment shaders are
     * compiled separately, glslang's auto-map may not assign matching
     * locations to corresponding `out`/`in` variables. Without consistent
     * locations, Metal's pipeline validator reports:
     *   "Fragment input(s) `user(locn0)` mismatching vertex shader output
     *    type(s) or not written by vertex shader"
     * because the vertex output and fragment input land on different
     * [[user(locn)]] slots. Assigning locations by declaration order on both
     * stages keeps them aligned (Minecraft's shaders declare varyings in the
     * same order in both .vsh and .fsh).
     */
    {
        spvc_resources resources = nullptr;
        if (spvc_compiler_create_shader_resources(compiler, &resources) == SPVC_SUCCESS) {
            const spvc_reflected_resource* list = nullptr;
            size_t count = 0;
            if (spvc_resources_get_resource_list_for_type(resources,
                    SPVC_RESOURCE_TYPE_STAGE_OUTPUT, &list, &count) == SPVC_SUCCESS) {
                const unsigned SpvDecorationLocation = 30;
                unsigned next_location = 0;
                for (size_t i = 0; i < count; ++i) {
                    unsigned existing = spvc_compiler_get_decoration(
                        compiler, list[i].id, (SpvDecoration)SpvDecorationLocation);
                    if (existing == 0) {
                        spvc_compiler_set_decoration(
                            compiler, list[i].id,
                            (SpvDecoration)SpvDecorationLocation, next_location);
                        next_location++;
                    } else {
                        next_location = existing + 1;
                    }
                }
            }
        }
    }

    const char* result = nullptr;
    if (spvc_compiler_compile(compiler, &result) != SPVC_SUCCESS) {
        info = spvc_context_get_last_error_string(ctx) ? spvc_context_get_last_error_string(ctx) : "compile failed";
        spvc_context_destroy(ctx);
        return false;
    }
    out = result ? result : "";
    spvc_context_destroy(ctx);
    return true;
}

} // namespace

bool shader_translate(GLenum gl_stage, const std::string& glsl_source,
                      std::string& out_msl, std::string& out_info_log,
                      const std::unordered_map<std::string, GLuint>* attrib_bindings) {
    const char* stage_name =
        gl_stage == GL_VERTEX_SHADER ? "vertex" :
        gl_stage == GL_FRAGMENT_SHADER ? "fragment" : "other";

    // Cache key includes the bindings so that re-linking with different
    // attribute bindings (e.g. a different VertexFormat) produces fresh MSL.
    uint64_t key = fnv1a(glsl_source) ^ (uint64_t)gl_stage * 0x9E3779B97F4A7C15ULL;
    if (attrib_bindings) {
        for (const auto& kv : *attrib_bindings) {
            key ^= fnv1a(kv.first) ^ ((uint64_t)kv.second * 0x100000001B3ULL);
        }
    }
    {
        std::lock_guard<std::mutex> lk(cache().mu);
        auto it = cache().entries.find(key);
        if (it != cache().entries.end()) {
            out_msl = it->second;
            MITHRIL_LOG_DEBUG("shader", "Cache hit for %s shader (hash %016llx)",
                              stage_name, (unsigned long long)key);
            return true;
        }
    }

    MITHRIL_LOG_INFO("shader", "Translating %s shader (%zu bytes GLSL)",
                     stage_name, glsl_source.size());

    std::vector<uint32_t> spirv;
    if (!glsl_to_spirv(gl_stage, glsl_source, spirv, out_info_log, attrib_bindings)) {
        MITHRIL_LOG_ERROR("shader", "GLSL->SPIR-V failed for %s shader: %s",
                          stage_name, out_info_log.c_str());
        return false;
    }

    MITHRIL_LOG_DEBUG("shader", "SPIR-V generated: %zu words", spirv.size());

    if (!spirv_to_msl(spirv, out_msl, out_info_log)) {
        MITHRIL_LOG_ERROR("shader", "SPIR-V->MSL failed for %s shader: %s",
                          stage_name, out_info_log.c_str());
        return false;
    }

    MITHRIL_LOG_INFO("shader", "Translated %s shader: %zu bytes MSL",
                     stage_name, out_msl.size());

    std::lock_guard<std::mutex> lk(cache().mu);
    cache().entries[key] = out_msl;
    return true;
}

} // namespace mithril
