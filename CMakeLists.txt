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

include(FetchContent)

# ---------------------------------------------------------------------------
# glslang: GLSL front-end -> SPIR-V
# ---------------------------------------------------------------------------
set(ENABLE_RTTI                ON  CACHE BOOL "" FORCE)
set(ENABLE_HLSL                OFF CACHE BOOL "" FORCE)
set(ENABLE_OPT                 OFF CACHE BOOL "" FORCE)
set(ENABLE_GLSLANG_BINARIES    OFF CACHE BOOL "" FORCE)
set(BUILD_EXTERNAL             OFF CACHE BOOL "" FORCE)
set(SKIP_GLSLANG_INSTALL       ON  CACHE BOOL "" FORCE)
set(GLSLANG_TESTS              OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    glslang
    GIT_REPOSITORY https://github.com/KhronosGroup/glslang.git
    GIT_TAG        14.3.0
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(glslang)

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

FetchContent_Declare(
    spirv_cross
    GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Cross.git
    GIT_TAG        vulkan-sdk-1.3.290.0
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(spirv_cross)

# ---------------------------------------------------------------------------
# Mithril-Wapper shared library (iOS arm64 dylib)
# ---------------------------------------------------------------------------
set(MITHRIL_SOURCES
    src/init.cpp
    src/log.cpp
    src/state.cpp
    src/stubs.cpp
    src/gl.cpp
    src/getter.cpp
    src/program.cpp
    src/shader.cpp
    src/buffer.cpp
    src/vertexattrib.cpp
    src/texture.cpp
    src/framebuffer.cpp
    src/drawing.cpp
    src/glx/lookup.cpp
)

if(APPLE)
    list(APPEND MITHRIL_SOURCES
        src/metal/metal_context.mm
        src/metal/metal_objects.mm
        src/metal/metal_pipeline.mm
    )
endif()

add_library(${PROJECT_NAME} SHARED ${MITHRIL_SOURCES})

target_include_directories(${PROJECT_NAME}
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# glslang / SPIRV-Cross
target_link_libraries(${PROJECT_NAME} PRIVATE
    glslang::glslang
    glslang::SPIRV
    spirv-cross-c
)

if(APPLE)
    # ARC for Objective-C++ Metal backend
    set_source_files_properties(
        src/metal/metal_context.mm
        src/metal/metal_objects.mm
        src/metal/metal_pipeline.mm
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
