# Mithril-Wapper

> OpenGL 3.3 Core Profile → Metal 翻译层，让依赖桌面 OpenGL 的应用能在仅有
> Metal 后端的 Apple 平台（iOS / iPadOS / macOS Apple Silicon）上运行。

Mithril-Wapper 把宿主程序发出的 **OpenGL 3.3 Core Profile** 调用实时翻译成
**Metal API** 调用，并自带一套基于 **Metal 2 + CAMetalLayer** 的 **EGL 1.5**
实现，让 LWJGL 3 / PojavLauncher / Amethyst-iOS 这类靠 `eglCreateContext` 等
EGL 入口拉起 GL 上下文的启动器可以直接 `dlopen` 本库。着色器走
`GLSL → SPIR-V → MSL` 离线/即时转译管线：

```
GLSL 源码  ──glslang──▶  SPIR-V  ──SPIRV-Cross──▶  MSL  ──▶  MTLLibrary
```

项目结构参考了 [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) 的
`MobileGlues-cpp/` 布局，但目标 API 不同：MobileGlues 做的是
`桌面 GLSL → GLSL ES` 再交给 ANGLE；Mithril-Wapper 直接落到原生 Metal，
且自带 EGL，不再依赖 ANGLE 的 `libEGL.framework`。

## 功能概览

- 对外暴露一整套 `extern "C"` 的 OpenGL 3.3 Core 入口（`glDraw*`、
  `glBindBuffer`、`glTexImage2D`、`glUniform*`、`glGetString*` 等），
  可作为动态库 `libmithril.dylib` 被 `dlopen` 注入。
- `glGetString(GL_VERSION)` 返回 `3.3.0 Mithril-Wapper`，
  `glGetIntegerv(GL_MAJOR_VERSION/GL_MINOR_VERSION)` 返回 `3 / 3`，
  `GL_CONTEXT_PROFILE_MASK` 返回 `GL_CONTEXT_CORE_PROFILE_BIT`。
- **自带 EGL 1.5（Metal 2 后端）**：`egl/egl.mm` 导出 21 个
  `egl*` 入口（`eglGetDisplay` / `eglInitialize` / `eglChooseConfig` /
  `eglCreateContext` / `eglCreateWindowSurface` / `eglMakeCurrent` /
  `eglSwapBuffers` …），宿主启动器（如 Amethyst-iOS 的
  `Natives/ctxbridges/gl_bridge.m`）可直接 `dlsym` 解析。EGLDisplay 映射到
  单例 Metal 设备/命令队列；EGLSurface 包装 `CAMetalLayer`，每帧
  `nextDrawable` 拉取的 `MTLTexture` 直接挂到 GL 状态机的默认帧缓冲（FBO 0）
  上，GL 绘制命令因此直接渲染到屏幕 drawable；EGLContext 各自持有独立的
  `mithril::GLState`，`eglMakeCurrent` 切换 `mithril::g_state` 指向当前上下文。
- Metal 后端：
  - `metal_context` —— `MTLDevice` / `MTLCommandQueue` / `MTLCommandBuffer`
    生命周期与帧提交。
  - `metal_objects` —— `MTLBuffer` / `MTLTexture` / `MTLSamplerState` 按
    GL 名字托管。
  - `metal_pipeline` —— `MTLRenderPipelineState` 描述符组装与缓存。
- 着色器转译（`gl/shader.cpp`）：线程安全地调用 glslang 把 GLSL 3.30 编译成
  SPIR-V，再用 SPIRV-Cross 交叉编译成 MSL，最终编译进 `MTLLibrary`。

## 最低硬件 / 系统要求

| 项 | 要求 | 说明 |
|---|---|---|
| SoC | **Apple A11** 及以上 | iPhone 8 / 8 Plus / X 起步；A11 是首个支持 Metal 2 的芯片 |
| 最低Metal版本要求 | **Metal 2 API** | A11 自带；EGL 后端使用 `MTLDevice` / `MTLCommandQueue` / `CAMetalLayer`，全部 Metal 1/2 时代 API |
| 系统 | **iOS / iPadOS 14.0** 及以上 | CI 默认部署目标 `14.0`，对应 MSL 2.3 |
| MSL | 目标 **MSL 2.3** | iOS 14 对应的 Metal Shading Language 版本 |
| 宿主 | 任意支持 `dlopen` 注入渲染器的启动器 | 已验证可对接 Amethyst-iOS（`ui/fcl-versionmgr` 系） |

Metal 后端只使用 Metal 1/2 时代的基础 API（`MTLDevice` /
`MTLCommandQueue` / `MTLRenderPipelineState` / 基础 `MTLPixelFormat` /
`CAMetalLayer`），**不依赖 Metal 3 的 indirect command buffer、heap、
mesh shader、counter sampling 等新特性**，因此 A11 / Metal 2 设备在
iOS 14+ 上可完整运行 Minecraft Java Edition 的现代渲染管线。

> ⚠️ 低于 Metal 2 的设备（A7 / A8 / A8X / A9 / A10）不受支持：A7–A8 仅支持
> Metal 1.x，A9–A10 虽然能跑 Metal 2 但缺少本实现依赖的若干
> `MTLPixelFormatDepth32Float_Stencil8` 性能优化路径。最低起步即
> **iPhone 8 / iPhone X（A11, Metal 2, iOS 14）**。

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
│   ├── egl/                       # EGL 1.5（Metal 2 后端，Objective-C++ .mm）
│   │   └── egl.mm                 #   21 个 egl* 入口 + CAMetalLayer 包装
│   ├── glx/lookup.cpp             # GLX 符号导出 / 入口查找
│   ├── include/                   # 对外公共头
│   │   ├── GL/                    #   gl.h、glcorearb.h
│   │   ├── KHR/                   #   khrplatform.h
│   │   └── EGL/                   #   egl.h（自带 EGL 类型 + PFNEGL*PROC typedef）
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

构建产物是单个 `libmithril.dylib`，可注入到目标进程的 OpenGL / EGL 加载路径中。
该 dylib 同时导出 `gl*`（OpenGL 3.3 Core）与 `egl*`（EGL 1.5）符号，宿主启动器
只需 `dlopen("@rpath/libmithril.dylib", RTLD_NOW)` 即可同时拿到两套入口。

## 与 Amethyst-iOS 集成

本仓库的 EGL 实现专门用于修复
[Amethyst-iOS](https://github.com/EternityQwQ/Amethyst-iOS) 在 LTW /
Mithril 渲染器下 `eglCreateContext` dlsym 失败导致的 SIGSEGV。集成步骤：

1. 把 CI 产物 `libmithril.dylib` 放到 Amethyst 应用的 `Frameworks/` 目录。
2. 在 Amethyst 的渲染器选项里选择 `Mithril`（即 `RENDERER_NAME_MTL_ANGLE`
   对应的入口），让 `gl_bridge.m` 把 `libmithril.dylib` 当作 EGL 宿主加载。
3. `egl_bridge.m` / `gl_bridge.m` 调用 `eglGetDisplay(EGL_DEFAULT_DISPLAY)` →
   `eglInitialize` → `eglChooseConfig` → `eglCreateWindowSurface(layer)` →
   `eglCreateContext` → `eglMakeCurrent`，全部由本 dylib 解析并落到 Metal 2。

对应分支：[`Amethyst-IOS`](https://github.com/EternityQwQ/Amethyst-iOS/tree/Amethyst-IOS)
（基于 `herbrine8403/Amethyst-iOS-MyRemastered@ui/fcl-versionmgr`）。

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
