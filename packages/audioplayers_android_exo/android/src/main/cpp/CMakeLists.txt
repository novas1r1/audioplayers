cmake_minimum_required(VERSION 3.22.1)
project(signalsmith_jni)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Signalsmith Stretch is header-only, just need to set up include paths
set(SIGNALSMITH_STRETCH_DIR ${CMAKE_CURRENT_SOURCE_DIR}/signalsmith-stretch)
set(SIGNALSMITH_LINEAR_DIR ${CMAKE_CURRENT_SOURCE_DIR}/signalsmith-linear)

# Check if Signalsmith Stretch header exists
if(NOT EXISTS ${SIGNALSMITH_STRETCH_DIR}/signalsmith-stretch.h)
    message(FATAL_ERROR "Signalsmith Stretch header not found at ${SIGNALSMITH_STRETCH_DIR}/signalsmith-stretch.h")
endif()

# Check if Signalsmith Linear (dependency) exists
if(NOT EXISTS ${SIGNALSMITH_LINEAR_DIR}/include/signalsmith-linear/stft.h)
    message(FATAL_ERROR "Signalsmith Linear (dependency) not found at ${SIGNALSMITH_LINEAR_DIR}")
endif()

# JNI wrapper source
set(JNI_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/signalsmith_jni.cpp
)

# Create shared library
add_library(signalsmith_jni SHARED
    ${JNI_SOURCES}
)

# Include directories
# - signalsmith-stretch.h includes "signalsmith-linear/stft.h"
# - So we need the parent of signalsmith-linear in the include path
target_include_directories(signalsmith_jni PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${SIGNALSMITH_STRETCH_DIR}
    ${SIGNALSMITH_LINEAR_DIR}/include
)

# Link Android log library
find_library(log-lib log)
target_link_libraries(signalsmith_jni
    ${log-lib}
)

# Compiler flags - optimization is important for audio processing
target_compile_options(signalsmith_jni PRIVATE
    -O2
    -fvisibility=hidden
    -ffunction-sections
    -fdata-sections
)

# Linker flags to reduce size and support 16KB page sizes (Android 15+)
target_link_options(signalsmith_jni PRIVATE
    -Wl,--gc-sections
    -Wl,-z,max-page-size=16384
)
