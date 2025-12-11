/**
 * JNI Bridge for Rubberband Library
 * Provides time-stretching functionality for Android audio processing
 */

#include <jni.h>
#include <android/log.h>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "rubberband/RubberBandStretcher.h"

#define LOG_TAG "RubberbandJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

using RubberBand::RubberBandStretcher;

/**
 * Wrapper class to hold stretcher instance and conversion buffers
 */
struct RubberbandContext {
    RubberBandStretcher* stretcher;
    int channels;
    int sampleRate;
    
    // Buffers for float conversion (Rubberband uses float, Android uses short)
    std::vector<float> inputFloatBuffer;
    std::vector<float> outputFloatBuffer;
    std::vector<float*> inputChannelPtrs;
    std::vector<float*> outputChannelPtrs;
    
    RubberbandContext(int sr, int ch) : sampleRate(sr), channels(ch) {
        // Create stretcher with real-time options optimized for music
        RubberBandStretcher::Options options = 
            RubberBandStretcher::OptionProcessRealTime |
            RubberBandStretcher::OptionPitchHighConsistency |
            RubberBandStretcher::OptionChannelsTogether;
        
        stretcher = new RubberBandStretcher(sr, ch, options);
        
        // Pre-allocate channel pointer arrays
        inputChannelPtrs.resize(ch);
        outputChannelPtrs.resize(ch);
        
        LOGI("Created RubberbandContext: sampleRate=%d, channels=%d", sr, ch);
    }
    
    ~RubberbandContext() {
        if (stretcher) {
            delete stretcher;
            stretcher = nullptr;
        }
        LOGI("Destroyed RubberbandContext");
    }
    
    void setTimeRatio(double ratio) {
        if (stretcher) {
            stretcher->setTimeRatio(ratio);
            LOGI("Set time ratio: %f", ratio);
        }
    }
    
    void setPitchScale(double scale) {
        if (stretcher) {
            stretcher->setPitchScale(scale);
            LOGI("Set pitch scale: %f", scale);
        }
    }
    
    /**
     * Process interleaved short samples through Rubberband
     * Returns number of output samples available
     */
    int process(const short* input, int sampleFrames) {
        if (!stretcher || sampleFrames <= 0) return 0;
        
        // Resize input buffer if needed
        size_t totalSamples = sampleFrames * channels;
        if (inputFloatBuffer.size() < totalSamples) {
            inputFloatBuffer.resize(totalSamples);
        }
        
        // Convert short to float and deinterleave
        for (int frame = 0; frame < sampleFrames; frame++) {
            for (int ch = 0; ch < channels; ch++) {
                inputFloatBuffer[ch * sampleFrames + frame] = 
                    input[frame * channels + ch] / 32768.0f;
            }
        }
        
        // Set up channel pointers
        for (int ch = 0; ch < channels; ch++) {
            inputChannelPtrs[ch] = inputFloatBuffer.data() + ch * sampleFrames;
        }
        
        // Process through Rubberband
        stretcher->process(inputChannelPtrs.data(), sampleFrames, false);
        
        return stretcher->available();
    }
    
    /**
     * Retrieve processed samples as interleaved shorts
     * Returns actual number of sample frames retrieved
     */
    int retrieve(short* output, int maxSampleFrames) {
        if (!stretcher || maxSampleFrames <= 0) return 0;
        
        int available = stretcher->available();
        if (available <= 0) return 0;
        
        int framesToRetrieve = (available < maxSampleFrames) ? available : maxSampleFrames;
        
        // Resize output buffer if needed
        size_t totalSamples = framesToRetrieve * channels;
        if (outputFloatBuffer.size() < totalSamples) {
            outputFloatBuffer.resize(totalSamples);
        }
        
        // Set up channel pointers for output
        for (int ch = 0; ch < channels; ch++) {
            outputChannelPtrs[ch] = outputFloatBuffer.data() + ch * framesToRetrieve;
        }
        
        // Retrieve from Rubberband
        int retrieved = stretcher->retrieve(outputChannelPtrs.data(), framesToRetrieve);
        
        // Convert float to short and interleave
        for (int frame = 0; frame < retrieved; frame++) {
            for (int ch = 0; ch < channels; ch++) {
                float sample = outputChannelPtrs[ch][frame];
                // Clamp and convert
                if (sample > 1.0f) sample = 1.0f;
                if (sample < -1.0f) sample = -1.0f;
                output[frame * channels + ch] = static_cast<short>(sample * 32767.0f);
            }
        }
        
        return retrieved;
    }
    
    int available() {
        return stretcher ? stretcher->available() : 0;
    }
    
    int getSamplesRequired() {
        return stretcher ? stretcher->getSamplesRequired() : 0;
    }
    
    void reset() {
        if (stretcher) {
            stretcher->reset();
            LOGI("Reset stretcher");
        }
    }
    
    int getLatency() {
        return stretcher ? stretcher->getLatency() : 0;
    }
};

extern "C" {

/**
 * Create a new Rubberband stretcher instance
 * Returns handle (pointer) to the context, or 0 on failure
 */
JNIEXPORT jlong JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_create(
    JNIEnv* env, jobject thiz, jint sampleRate, jint channels) {
    
    try {
        RubberbandContext* ctx = new RubberbandContext(sampleRate, channels);
        return reinterpret_cast<jlong>(ctx);
    } catch (const std::exception& e) {
        LOGE("Failed to create RubberbandContext: %s", e.what());
        return 0;
    }
}

/**
 * Destroy the stretcher instance and free resources
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_destroy(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle != 0) {
        RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
        delete ctx;
    }
}

/**
 * Set the time ratio (1.0 = normal speed, 2.0 = half speed, 0.5 = double speed)
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_setTimeRatio(
    JNIEnv* env, jobject thiz, jlong handle, jdouble ratio) {
    
    if (handle != 0) {
        RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
        ctx->setTimeRatio(ratio);
    }
}

/**
 * Set the pitch scale (1.0 = normal pitch)
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_setPitchScale(
    JNIEnv* env, jobject thiz, jlong handle, jdouble scale) {
    
    if (handle != 0) {
        RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
        ctx->setPitchScale(scale);
    }
}

/**
 * Process input samples
 * @param input Interleaved short samples
 * @param sampleFrames Number of sample frames (not total samples)
 * @return Number of output sample frames available
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_process(
    JNIEnv* env, jobject thiz, jlong handle, jshortArray input, jint sampleFrames) {
    
    if (handle == 0 || input == nullptr) return 0;
    
    RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
    
    jshort* inputPtr = env->GetShortArrayElements(input, nullptr);
    if (inputPtr == nullptr) return 0;
    
    int result = ctx->process(inputPtr, sampleFrames);
    
    env->ReleaseShortArrayElements(input, inputPtr, JNI_ABORT);
    
    return result;
}

/**
 * Retrieve processed samples
 * @param output Buffer for interleaved short samples
 * @param maxSampleFrames Maximum number of sample frames to retrieve
 * @return Actual number of sample frames retrieved
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_retrieve(
    JNIEnv* env, jobject thiz, jlong handle, jshortArray output, jint maxSampleFrames) {
    
    if (handle == 0 || output == nullptr) return 0;
    
    RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
    
    jshort* outputPtr = env->GetShortArrayElements(output, nullptr);
    if (outputPtr == nullptr) return 0;
    
    int result = ctx->retrieve(outputPtr, maxSampleFrames);
    
    env->ReleaseShortArrayElements(output, outputPtr, 0);
    
    return result;
}

/**
 * Get number of sample frames available for retrieval
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_available(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle == 0) return 0;
    
    RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
    return ctx->available();
}

/**
 * Get number of sample frames required before output is available
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_getSamplesRequired(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle == 0) return 0;
    
    RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
    return ctx->getSamplesRequired();
}

/**
 * Reset the stretcher state
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_reset(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle != 0) {
        RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
        ctx->reset();
    }
}

/**
 * Get the latency in sample frames
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_RubberbandNative_getLatency(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle == 0) return 0;
    
    RubberbandContext* ctx = reinterpret_cast<RubberbandContext*>(handle);
    return ctx->getLatency();
}

} // extern "C"

