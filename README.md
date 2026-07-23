# Mithril-Wapper

> 在 Metal API 之上实现的 **OpenGL Core Profile**，目标平台仅限 **iOS**（arm64）。
> 主要场景：在 iOS 设备上运行 **Minecraft: Java Edition**。

`Mithril-Wapper` 以动态库（`libmithril.dylib`）形式提供 OpenGL Core Profile 的 C 符号，
在进程内拦截 GL 调用，并将其翻译为 Apple **Metal** API。着色器走
**GLSL → SPIR-V → MSL**（Metal Shading Language）管线，与底层 GPU 直接对接，
不再依赖任何 OpenGL ES / ANGLE 中间层。



---

## 与参考实现的关系

| 维度 | MobileGlues（参考） | Mithril-Wapper（本项目） |
| --- | --- | --- |
| 后端 | 宿主 OpenGL ES 3.x（iOS 上经 libEGL/libGLESv2 间接上 Metal） | **直接对接 Metal** |
| 着色器链路 | GLSL → SPIR-V → GLSL ES（spirv-cross MSL 关闭） | **GLSL → SPIR-V → MSL**（spirv-cross MSL 开启） |
| 产物 | `libmobileglues.dylib` | `libmithril.dylib` |
| 平台 | Android / iOS | **仅 iOS** |
| 状态机 | `gl_state`（program / tex unit / draw fbo 等） | 独立 `gl_state`，结构参考其健壮性设计 |

---

## 开发计划

> 完成一项以 ✅ 标记，进行中为 🔄，未开始为 ☐。

- ✅ 1. 项目初始化：创建 `MobileGlues` 只读参考分支并推送至远端（不修改其源码）
- ✅ 2. 构建系统：`CMakeLists.txt` + `ios-cmake` 工具链，`glslang` / `SPIRV-Cross` 经 `FetchContent` 拉取
- ✅ 3. OpenGL Core Profile C API 拦截层：导出 GL 符号；旧式固定管线函数以 stub 形式提供
- ✅ 4. GLSL → SPIR-V → MSL 着色器转换管线（glslang 编译 + spirv-cross MSL 后端 + 编译缓存）
- ✅ 5. Metal 后端：`MTLDevice` / `MTLCommandQueue` / `MTLCommandBuffer` / `MTLRenderCommandEncoder` 封装
- ✅ 6. OpenGL Core Profile 状态机：program / VAO / FBO / texture / blend / depth / viewport / cap 开关
- ✅ 7. 核心绘制路径：`glDrawArrays` / `glDrawElements` → Metal 渲染编码；pipeline state 缓存；顶点属性绑定；uniform buffer
- ✅ 8. glX 符号查找：`glXGetProcAddress` / `glXGetProcAddressARB`（经 `dlsym` 解析本库符号）
- ✅ 9. GitHub Actions CI：iOS arm64 构建、ad-hoc 签名、上传 `libmithril.dylib` 产物
- ✅ 10. README 文档（仅 iOS）

---

## 目录结构

```
.
├── CMakeLists.txt                 # 顶层构建脚本（iOS arm64, Metal, glslang+spirv-cross）
├── README.md
├── .github/workflows/build.yml    # CI: 构建 libmithril.dylib 并上传
├── include/
│   ├── GL/gl.h                    # OpenGL Core Profile 类型与原型
│   ├── GL/glcorearb.h
│   └── KHR/khrplatform.h
└── src/
    ├── includes.h
    ├── init.cpp                   # 静态初始化 → proc_init()
    ├── log.{h,cpp}                # 日志（stderr / os_log）
    ├── state.{h,cpp}              # gl_state 状态机
    ├── stubs.cpp                  # 旧式固定管线函数 stub
    ├── gl.cpp                     # 核心: enable/viewport/clear/blend/depth/cull...
    ├── getter.cpp                 # glGet* / glGetString / glGetStringi
    ├── program.cpp                # program / shader 对象管理
    ├── shader.cpp                 # GLSL → SPIR-V → MSL 转换 + 缓存
    ├── buffer.cpp                 # VBO / IBO
    ├── vertexattrib.cpp           # VAO / 顶点属性
    ├── texture.cpp                # 纹理
    ├── framebuffer.cpp            # FBO
    ├── drawing.cpp                # drawArrays / drawElements → Metal
    ├── glx/lookup.cpp             # glXGetProcAddress(ARB)
    └── metal/
        ├── metal_context.{h,mm}   # MTLDevice/Queue/CommandBuffer/Encoder
        ├── metal_objects.{h,mm}   # MTLBuffer/MTLTexture/MTLPipelineState 封装
        └── metal_pipeline.{h,mm}  # MSL→MTLLibrary→RenderPipelineState 缓存
```

---

## 构建（CI）

本仓库**不在本地构建**，一切构建在 GitHub Actions 中进行（`macos-latest` 运行器，
`ios-cmake` 工具链，`PLATFORM=OS64`）。产物为 iOS arm64 的 `libmithril.dylib`，
经 ad-hoc 签名后作为 artifact 上传。

## 许可

本项目自身代码采用与参考一致的开源协议方向（详见 `LICENSE`）。第三方组件
`glslang`、`SPIRV-Cross` 各自保持其原始许可证。
