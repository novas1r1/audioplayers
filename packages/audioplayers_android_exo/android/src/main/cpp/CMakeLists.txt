cmake_minimum_required(VERSION 3.22.1)
project(rubberband_jni)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Rubberband source directory
set(RUBBERBAND_DIR ${CMAKE_CURRENT_SOURCE_DIR}/rubberband)

# Check if Rubberband source exists
if(NOT EXISTS ${RUBBERBAND_DIR}/rubberband/RubberBandStretcher.h)
    message(FATAL_ERROR "Rubberband source not found. Please run setup_rubberband.ps1 first or download Rubberband to ${RUBBERBAND_DIR}")
endif()

# Rubberband compile definitions for Android
add_definitions(
    -DUSE_PTHREADS
    -DUSE_OWN_ALIGNED_MALLOC
    -DNO_THREAD_CHECKS
    -DUSE_BUILTIN_FFT
    -DUSE_BQRESAMPLER
    -DNO_TIMING
    -DNDEBUG
)

# Rubberband source files - corrected paths based on actual source structure
set(RUBBERBAND_SOURCES
    # Core
    ${RUBBERBAND_DIR}/src/rubberband-c.cpp
    ${RUBBERBAND_DIR}/src/RubberBandStretcher.cpp
    
    # Faster engine (R2)
    ${RUBBERBAND_DIR}/src/faster/AudioCurveCalculator.cpp
    ${RUBBERBAND_DIR}/src/faster/CompoundAudioCurve.cpp
    ${RUBBERBAND_DIR}/src/faster/HighFrequencyAudioCurve.cpp
    ${RUBBERBAND_DIR}/src/faster/SilentAudioCurve.cpp
    ${RUBBERBAND_DIR}/src/faster/PercussiveAudioCurve.cpp
    ${RUBBERBAND_DIR}/src/faster/R2Stretcher.cpp
    ${RUBBERBAND_DIR}/src/faster/StretcherChannelData.cpp
    ${RUBBERBAND_DIR}/src/faster/StretcherProcess.cpp
    
    # Finer engine (R3)
    ${RUBBERBAND_DIR}/src/finer/R3Stretcher.cpp
    
    # Common utilities
    ${RUBBERBAND_DIR}/src/common/Allocators.cpp
    ${RUBBERBAND_DIR}/src/common/BQResampler.cpp
    ${RUBBERBAND_DIR}/src/common/FFT.cpp
    ${RUBBERBAND_DIR}/src/common/Log.cpp
    ${RUBBERBAND_DIR}/src/common/Profiler.cpp
    ${RUBBERBAND_DIR}/src/common/Resampler.cpp
    ${RUBBERBAND_DIR}/src/common/StretchCalculator.cpp
    ${RUBBERBAND_DIR}/src/common/sysutils.cpp
    ${RUBBERBAND_DIR}/src/common/mathmisc.cpp
    ${RUBBERBAND_DIR}/src/common/Thread.cpp
    ${RUBBERBAND_DIR}/src/common/VectorOpsComplex.cpp
)

# JNI wrapper source
set(JNI_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/rubberband_jni.cpp
)

# Create shared library
add_library(rubberband_jni SHARED
    ${RUBBERBAND_SOURCES}
    ${JNI_SOURCES}
)

# Include directories - JNI headers are automatically available in Android NDK
target_include_directories(rubberband_jni PRIVATE
    ${RUBBERBAND_DIR}
    ${RUBBERBAND_DIR}/rubberband
    ${RUBBERBAND_DIR}/src
    ${RUBBERBAND_DIR}/src/common
)

# Link Android log library
find_library(log-lib log)
target_link_libraries(rubberband_jni
    ${log-lib}
)

# Compiler flags
target_compile_options(rubberband_jni PRIVATE
    -O2
    -fvisibility=hidden
    -ffunction-sections
    -fdata-sections
)

# Linker flags to reduce size
target_link_options(rubberband_jni PRIVATE
    -Wl,--gc-sections
)
