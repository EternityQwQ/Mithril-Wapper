cmake_minimum_required(VERSION 3.22.1)
project("mithril" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Objective-C++ (.mm) standard for the Metal backend
if(APPLE)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 20)
    set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
endif()

# GL symbols must be exported (the dylib is a drop-in OpenGL replacement)
set(CMAKE_CXX_VISIBILITY_PRESET default)
set(CMAKE_C_VISIBILITY_PRESET default)
set(CMAKE_VISIBILITY_INLINES_HIDDEN OFF)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fvisibility=default")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=default")

# ---------------------------------------------------------------------------
# glslang: GLSL front-end -> SPIR-V  (submodule under 3rdparty/, mirrors the
# MobileGlues layout which uses add_subdirectory(3rdparty/glslang) instead of
# FetchContent so the sources are available for local hacking).
# ---------------------------------------------------------------------------
set(ENABLE_RTTI                ON  CACHE BOOL "" FORCE)
set(ENABLE_HLSL                OFF CACHE BOOL "" FORCE)
set(ENABLE_OPT                 OFF CACHE BOOL "" FORCE)
set(ENABLE_GLSLANG_BINARIES    OFF CACHE BOOL "" FORCE)
set(BUILD_EXTERNAL             OFF CACHE BOOL "" FORCE)
set(SKIP_GLSLANG_INSTALL       ON  CACHE BOOL "" FORCE)
set(GLSLANG_TESTS              OFF CACHE BOOL "" FORCE)
add_subdirectory(Mithril-Wapper-cpp/3rdparty/glslang)

# ---------------------------------------------------------------------------
# SPIRV-Cross: SPIR-V -> MSL (Metal Shading Language)
# ---------------------------------------------------------------------------
set(SPIRV_CROSS_ENABLE_C_API   ON  CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_GLSL    ON  CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_MSL     ON  CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL    OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_CPP     OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_CLI            OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_UTIL    OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_STATIC         ON  CACHE BOOL "" FORCE)
set(SPIRV_CROSS_FORCE_PIC      ON  CACHE BOOL "" FORCE)
set(SPIRV_CROSS_SKIP_INSTALL   ON  CACHE BOOL "" FORCE)
add_subdirectory(Mithril-Wapper-cpp/3rdparty/SPIRV-Cross)

# ---------------------------------------------------------------------------
# Mithril-Wapper shared library (iOS arm64 dylib)
# ---------------------------------------------------------------------------
set(MITHRIL_SOURCES
    Mithril-Wapper-cpp/init.cpp
    Mithril-Wapper-cpp/gl/log.cpp
    Mithril-Wapper-cpp/gl/state.cpp
    Mithril-Wapper-cpp/gl/stubs.cpp
    Mithril-Wapper-cpp/gl/gl.cpp
    Mithril-Wapper-cpp/gl/getter.cpp
    Mithril-Wapper-cpp/gl/program.cpp
    Mithril-Wapper-cpp/gl/shader.cpp
    Mithril-Wapper-cpp/gl/buffer.cpp
    Mithril-Wapper-cpp/gl/vertexattrib.cpp
    Mithril-Wapper-cpp/gl/texture.cpp
    Mithril-Wapper-cpp/gl/framebuffer.cpp
    Mithril-Wapper-cpp/gl/drawing.cpp
    Mithril-Wapper-cpp/glx/lookup.cpp
)

if(APPLE)
    list(APPEND MITHRIL_SOURCES
        Mithril-Wapper-cpp/metal/metal_context.mm
        Mithril-Wapper-cpp/metal/metal_objects.mm
        Mithril-Wapper-cpp/metal/metal_pipeline.mm
        # EGL 1.5 surface backed by Metal 2 (CAMetalLayer). On iOS this is
        # the layer Amethyst-iOS' gl_bridge.m dlsym's eglCreateContext etc.
        # against. Compiled as Objective-C++ so it can talk to CAMetalLayer
        # and MTLDevice directly.
        Mithril-Wapper-cpp/egl/egl.mm
    )
endif()

add_library(${PROJECT_NAME} SHARED ${MITHRIL_SOURCES})

target_include_directories(${PROJECT_NAME}
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/Mithril-Wapper-cpp
        ${CMAKE_CURRENT_SOURCE_DIR}/Mithril-Wapper-cpp/include
)

# glslang / SPIRV-Cross.
# NOTE: glslang-default-resource-limits provides GetDefaultResources() which
# lives in ResourceLimits/ResourceLimits.cpp. Without it the link fails with
# "Undefined symbols: GetDefaultResources()" when ENABLE_GLSLANG_BINARIES=OFF
# (the standalone glslangValidator that used to host it is disabled).
target_link_libraries(${PROJECT_NAME} PRIVATE
    glslang::glslang
    glslang::SPIRV
    glslang::glslang-default-resource-limits
    spirv-cross-c
)

if(APPLE)
    # ARC for Objective-C++ Metal + EGL-on-Metal backend
    set_source_files_properties(
        Mithril-Wapper-cpp/metal/metal_context.mm
        Mithril-Wapper-cpp/metal/metal_objects.mm
        Mithril-Wapper-cpp/metal/metal_pipeline.mm
        Mithril-Wapper-cpp/egl/egl.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc"
    )
    target_link_libraries(${PROJECT_NAME} PRIVATE
        "-framework Metal"
        "-framework Foundation"
        "-framework QuartzCore"
    )
    target_compile_definitions(${PROJECT_NAME} PRIVATE MITHRIL_METAL=1)
else()
    target_link_libraries(${PROJECT_NAME} PRIVATE ${CMAKE_DL_LIBS})
endif()

# Reasonable warnings, no -Werror (CI must be tolerant during bring-up)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable)
endif()

set_target_properties(${PROJECT_NAME} PROPERTIES
    OUTPUT_NAME "mithril"
    PREFIX "lib"
    SUFFIX ".dylib"
)
