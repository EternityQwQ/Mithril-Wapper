# Mithril-Wapper

> OpenGL 3.3 Core Profile → Metal 翻译层，让依赖桌面 OpenGL 的应用能在仅有
> Metal 后端的 Apple 平台（iOS / iPadOS / macOS Apple Silicon）上运行。

Mithril-Wapper 把宿主程序发出的 **OpenGL 3.3 Core Profile** 调用实时翻译成
**Metal API** 调用。着色器走 `GLSL → SPIR-V → MSL` 离线/即时转译管线：

```
GLSL 源码  ──glslang──▶  SPIR-V  ──SPIRV-Cross──▶  MSL  ──▶  MTLLibrary
```

项目结构参考了 [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) 的
`MobileGlues-cpp/` 布局，但目标 API 不同：MobileGlues 做的是
`桌面 GLSL → GLSL ES` 再交给 ANGLE；Mithril-Wapper 直接落到原生 Metal。

## 功能概览

- 对外暴露一整套 `extern "C"` 的 OpenGL 3.3 Core 入口（`glDraw*`、
  `glBindBuffer`、`glTexImage2D`、`glUniform*`、`glGetString*` 等），
  可作为动态库 `libmithril.dylib` 被 `dlopen` 注入。
- `glGetString(GL_VERSION)` 返回 `3.3.0 Mithril-Wapper`，
  `glGetIntegerv(GL_MAJOR_VERSION/GL_MINOR_VERSION)` 返回 `3 / 3`，
  `GL_CONTEXT_PROFILE_MASK` 返回 `GL_CONTEXT_CORE_PROFILE_BIT`。
- Metal 后端：
  - `metal_context` —— `MTLDevice` / `MTLCommandQueue` / `MTLCommandBuffer`
    生命周期与帧提交。
  - `metal_objects` —— `MTLBuffer` / `MTLTexture` / `MTLSamplerState` 按
    GL 名字托管。
  - `metal_pipeline` —— `MTLRenderPipelineState` 描述符组装与缓存。
- 着色器转译（`gl/shader.cpp`）：线程安全地调用 glslang 把 GLSL 3.30 编译成
  SPIR-V，再用 SPIRV-Cross 交叉编译成 MSL，最终编译进 `MTLLibrary`。

## 目录结构

```
.
├── CMakeLists.txt                 # 顶层构建脚本（add_subdirectory 子模块）
├── .gitmodules                    # glslang / SPIRV-Cross / SPIRV-Headers
├── .github/workflows/build.yml    # CI：macOS arm64 交叉编译 iOS dylib
├── Mithril-Wapper-cpp/            # 源码根（参考 MobileGlues 的布局）
│   ├── includes.h                 # 全局内部头
│   ├── init.cpp                   # 库加载/初始化
│   ├── gl/                        # OpenGL 3.3 Core Profile 实现
│   │   ├── gl.cpp  getter.cpp  program.cpp  shader.cpp
│   │   ├── buffer.cpp  texture.cpp  framebuffer.cpp  drawing.cpp
│   │   ├── vertexattrib.cpp  state.cpp  stubs.cpp  log.cpp
│   │   └── *.h
│   ├── metal/                     # Metal 后端（Objective-C++ .mm）
│   │   ├── metal_context.{h,mm}
│   │   ├── metal_objects.{h,mm}
│   │   └── metal_pipeline.{h,mm}
│   ├── glx/lookup.cpp             # GLX 符号导出 / 入口查找
│   ├── include/                   # 对外公共头（GL/gl.h、glcorearb.h、KHR/）
│   └── 3rdparty/                  # Git 子模块
│       ├── glslang                # GLSL → SPIR-V 前端
│       ├── SPIRV-Cross            # SPIR-V → MSL 交叉编译
│       └── SPIRV-Headers          # SPIR-V 规范头
```

## 依赖

- **CMake ≥ 3.22**
- **C++20** 编译器（clang / Apple clang）
- **Apple Metal 框架**（仅在 Apple 平台编译 Metal 后端）
- Git 子模块（glslang / SPIRV-Cross / SPIRV-Headers），见 `.gitmodules`

## 本地构建

### 1. 克隆（带子模块）

```bash
git clone --recursive https://github.com/EternityQwQ/Mithril-Wapper.git
cd Mithril-Wapper

# 如果已经克隆但忘了带 --recursive：
git submodule update --init --recursive
```

### 2. 配置 & 构建（macOS 原生）

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
# 产物：build/libmithril.dylib
```

### 3. 交叉编译 iOS arm64 dylib

CI 使用的就是这条路径。借助
[leetal/ios-cmake](https://github.com/leetal/ios-cmake) 工具链：

```bash
# 下载工具链
curl -fsSL -o ios.toolchain.cmake \
  https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake

# 配置（iOS arm64，默认仅设备架构）
cmake -S . -B build-ios \
  -DCMAKE_TOOLCHAIN_FILE=../ios.toolchain.cmake \
  -DPLATFORM=OS64 \
  -DDEPLOYMENT_TARGET=14.0 \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build-ios -j
# 产物：build-ios/libmithril.dylib （arm64 iOS）
```

构建产物是单个 `libmithril.dylib`，可注入到目标进程的 OpenGL 加载路径中。

## CI

GitHub Actions 工作流 [`.github/workflows/build.yml`](.github/workflows/build.yml)
会在 `macos-latest` runner 上用 ios-cmake 工具链交叉编译 iOS arm64 的
`libmithril.dylib`，并上传构建树为 artifact。每次推送到 `main` 都会触发。

## 致谢

- [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) —— 目录结构与
  GL 状态管理思路的参考。
- [KhronosGroup/glslang](https://github.com/KhronosGroup/glslang) ——
  GLSL 参考编译器前端。
- [KhronosGroup/SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) ——
  SPIR-V 交叉编译器。
- [KhronosGroup/SPIRV-Headers](https://github.com/KhronosGroup/SPIRV-Headers) ——
  SPIR-V 规范头文件。
- [leetal/ios-cmake](https://github.com/leetal/ios-cmake) —— iOS CMake 工具链。

## 开发者

- **EternityQwQ**
- **yitenchen123**

## 许可

详见 [LICENSE](LICENSE)。
