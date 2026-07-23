// Mithril-Wapper - shader.cpp
// GLSL (desktop Core Profile) -> SPIR-V -> MSL translation pipeline.
//   * glslang compiles GLSL to Vulkan SPIR-V
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

    glslang::TShader shader(stage);
    const char* s = src.c_str();
    int len = (int)src.size();
    shader.setStringsWithLengths(&s, &len, 1);
    shader.setEnvInput(glslang::EShSourceGlsl, stage, glslang::EShClientVulkan, 100);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);

    const EShMessages messages = static_cast<EShMessages>(
        EShMsgDefault | EShMsgVulkanRules | EShMsgSpvRules);

    const int defaultVersion = 330; // desktop core
    if (!shader.parse(GetDefaultResources(), defaultVersion, false, messages)) {
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

    // Pass an explicit SpvOptions pointer to disambiguate from the 4-arg
    // GlslangToSpv(intermediate, spirv, SpvBuildLogger*, SpvOptions*) overload.
    glslang::SpvOptions spv_opts;
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
    uint64_t key = fnv1a(glsl_source) ^ (uint64_t)gl_stage * 0x9E3779B97F4A7C15ULL;
    {
        std::lock_guard<std::mutex> lk(cache().mu);
        auto it = cache().entries.find(key);
        if (it != cache().entries.end()) { out_msl = it->second; return true; }
    }

    std::vector<uint32_t> spirv;
    if (!glsl_to_spirv(gl_stage, glsl_source, spirv, out_info_log)) return false;

    if (!spirv_to_msl(spirv, out_msl, out_info_log)) return false;

    std::lock_guard<std::mutex> lk(cache().mu);
    cache().entries[key] = out_msl;
    return true;
}

} // namespace mithril
