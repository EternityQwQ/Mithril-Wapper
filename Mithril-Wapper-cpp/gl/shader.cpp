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
                   std::vector<uint32_t>& spirv, std::string& info) {
    glslang_init();
    EShLanguage stage = to_esh_stage(gl_stage);
    if (stage == EShLangCount) { info = "unsupported shader stage"; return false; }

    // Ensure the source has a usable GLSL version (mirrors MobileGlues'
    // get_or_add_glsl_version). Minecraft's blit_screen uses #version 150,
    // which is fine for the OpenGL SPIR-V client.
    std::string source = src;
    int glsl_version = ensure_glsl_version(source);

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
     * Register vertex attribute mappings so SPIRV-Cross generates
     * [[attribute(N)]] qualifiers on the stage_in struct. Without this,
     * Metal rejects the vertex function with:
     *   "invalid type 'main0_in' of input declaration with attribute
     *    'stage_in' in a vertex function"
     * because the struct fields lack [[attribute(N)]].
     *
     * We map each SPIR-V stage_input location to the same Metal attribute
     * index (location N -> attribute N). This matches our vertex descriptor
     * layout in metal_pipeline.mm where each attribute's bufferIndex == location.
     */
    {
        spvc_resources resources = nullptr;
        if (spvc_compiler_create_shader_resources(compiler, &resources) == SPVC_SUCCESS) {
            const spvc_reflected_resource* list = nullptr;
            size_t count = 0;
            if (spvc_resources_get_resource_list_for_type(resources,
                    SPVC_RESOURCE_TYPE_STAGE_INPUT, &list, &count) == SPVC_SUCCESS) {
                // SpvDecorationLocation = 30 (from spirv.h, avoids extra include)
                const unsigned SpvDecorationLocation = 30;
                for (size_t i = 0; i < count; ++i) {
                    unsigned location = spvc_compiler_get_decoration(
                        compiler, list[i].id, (SpvDecoration)SpvDecorationLocation);
                    spvc_msl_vertex_attribute attr;
                    spvc_msl_vertex_attribute_init(&attr);
                    attr.location = location;
                    // format and builtin default to OTHER/Invalid — SPIRV-Cross
                    // will infer the correct format from the SPIR-V type.
                    spvc_compiler_msl_add_vertex_attribute(compiler, &attr);
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
                      std::string& out_msl, std::string& out_info_log) {
    const char* stage_name =
        gl_stage == GL_VERTEX_SHADER ? "vertex" :
        gl_stage == GL_FRAGMENT_SHADER ? "fragment" : "other";

    uint64_t key = fnv1a(glsl_source) ^ (uint64_t)gl_stage * 0x9E3779B97F4A7C15ULL;
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
    if (!glsl_to_spirv(gl_stage, glsl_source, spirv, out_info_log)) {
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
