/**
 * JNI Bridge for Signalsmith Stretch Library
 * Provides time-stretching functionality for Android audio processing.
 * 
 * https://signalsmith-audio.co.uk/code/stretch/
 */

#include <jni.h>
#include <android/log.h>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <deque>
#include <cmath>

#include "signalsmith-stretch/signalsmith-stretch.h"

#define LOG_TAG "SignalsmithJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/**
 * Wrapper class to hold stretcher instance and conversion buffers.
 * Adapts Signalsmith's buffer-size-based API to the ratio-based API
 * expected by the existing Kotlin code.
 */
struct SignalsmithContext {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    int channels;
    int sampleRate;
    double timeRatio = 1.0;
    double pitchScale = 1.0;
    
    // Input accumulator - stores samples until we have enough to process
    std::vector<std::deque<float>> inputQueues;
    
    // Output buffer - stores processed samples for retrieval
    std::vector<std::deque<float>> outputQueues;
    
    // Temporary buffers for processing
    std::vector<std::vector<float>> inputBuffers;
    std::vector<std::vector<float>> outputBuffers;
    std::vector<float*> inputPtrs;
    std::vector<float*> outputPtrs;
    
    // Processing block size
    static constexpr int BLOCK_SIZE = 1024;
    
    SignalsmithContext(int sr, int ch) : sampleRate(sr), channels(ch) {
        // Configure with default preset optimized for real-time
        stretch.presetDefault(ch, static_cast<float>(sr));
        
        // Initialize queues and buffers for each channel
        inputQueues.resize(ch);
        outputQueues.resize(ch);
        inputBuffers.resize(ch);
        outputBuffers.resize(ch);
        inputPtrs.resize(ch);
        outputPtrs.resize(ch);
        
        for (int c = 0; c < ch; c++) {
            inputBuffers[c].resize(BLOCK_SIZE * 4);
            outputBuffers[c].resize(BLOCK_SIZE * 4);
        }
        
        LOGI("Created SignalsmithContext: sampleRate=%d, channels=%d", sr, ch);
    }
    
    ~SignalsmithContext() {
        LOGI("Destroyed SignalsmithContext");
    }
    
    void setTimeRatio(double ratio) {
        timeRatio = ratio;
        LOGI("Set time ratio: %f", ratio);
    }
    
    void setPitchScale(double scale) {
        pitchScale = scale;
        // Signalsmith uses transpose factor for pitch shifting
        stretch.setTransposeFactor(static_cast<float>(scale));
        LOGI("Set pitch scale: %f", scale);
    }
    
    /**
     * Process interleaved short samples through Signalsmith Stretch.
     * Converts from interleaved shorts to planar floats, processes,
     * and stores output in the output queues.
     * 
     * Returns number of output samples available for retrieval.
     */
    int process(const short* input, int sampleFrames) {
        if (sampleFrames <= 0) return available();
        
        // Convert short to float and deinterleave into input queues
        for (int frame = 0; frame < sampleFrames; frame++) {
            for (int ch = 0; ch < channels; ch++) {
                float sample = input[frame * channels + ch] / 32768.0f;
                inputQueues[ch].push_back(sample);
            }
        }
        
        // Process in blocks when we have enough input
        while (canProcessBlock()) {
            processBlock();
        }
        
        return available();
    }
    
    /**
     * Check if we have enough input samples to process a block
     */
    bool canProcessBlock() const {
        if (inputQueues.empty() || inputQueues[0].empty()) return false;
        return inputQueues[0].size() >= BLOCK_SIZE;
    }
    
    /**
     * Process one block of audio through Signalsmith Stretch
     */
    void processBlock() {
        int inputSamples = BLOCK_SIZE;
        
        // Calculate output samples based on time ratio
        // timeRatio = 1.0 / playbackSpeed, so:
        // - timeRatio = 2.0 means half speed -> double output samples
        // - timeRatio = 0.5 means double speed -> half output samples
        int outputSamples = static_cast<int>(std::round(inputSamples * timeRatio));
        if (outputSamples < 1) outputSamples = 1;
        
        // Ensure buffers are large enough
        for (int c = 0; c < channels; c++) {
            if (inputBuffers[c].size() < static_cast<size_t>(inputSamples)) {
                inputBuffers[c].resize(inputSamples);
            }
            if (outputBuffers[c].size() < static_cast<size_t>(outputSamples)) {
                outputBuffers[c].resize(outputSamples);
            }
            
            // Copy input samples from queue to buffer
            for (int i = 0; i < inputSamples; i++) {
                inputBuffers[c][i] = inputQueues[c].front();
                inputQueues[c].pop_front();
            }
            
            inputPtrs[c] = inputBuffers[c].data();
            outputPtrs[c] = outputBuffers[c].data();
        }
        
        // Process through Signalsmith Stretch
        stretch.process(inputPtrs.data(), inputSamples, outputPtrs.data(), outputSamples);
        
        // Copy output samples to output queues
        for (int c = 0; c < channels; c++) {
            for (int i = 0; i < outputSamples; i++) {
                outputQueues[c].push_back(outputBuffers[c][i]);
            }
        }
    }
    
    /**
     * Retrieve processed samples as interleaved shorts.
     * Returns actual number of sample frames retrieved.
     */
    int retrieve(short* output, int maxSampleFrames) {
        if (maxSampleFrames <= 0) return 0;
        
        int availableFrames = available();
        if (availableFrames <= 0) return 0;
        
        int framesToRetrieve = std::min(availableFrames, maxSampleFrames);
        
        // Convert float to short and interleave
        for (int frame = 0; frame < framesToRetrieve; frame++) {
            for (int ch = 0; ch < channels; ch++) {
                float sample = outputQueues[ch].front();
                outputQueues[ch].pop_front();
                
                // Clamp and convert
                if (sample > 1.0f) sample = 1.0f;
                if (sample < -1.0f) sample = -1.0f;
                output[frame * channels + ch] = static_cast<short>(sample * 32767.0f);
            }
        }
        
        return framesToRetrieve;
    }
    
    /**
     * Get number of sample frames available for retrieval
     */
    int available() const {
        if (outputQueues.empty() || channels <= 0) return 0;
        return static_cast<int>(outputQueues[0].size());
    }
    
    /**
     * Get minimum samples required before output is available.
     * This is an estimate based on the block size and latency.
     */
    int getSamplesRequired() const {
        int queuedInput = inputQueues.empty() ? 0 : static_cast<int>(inputQueues[0].size());
        int needed = BLOCK_SIZE - queuedInput;
        return needed > 0 ? needed : 0;
    }
    
    void reset() {
        stretch.reset();
        for (int c = 0; c < channels; c++) {
            inputQueues[c].clear();
            outputQueues[c].clear();
        }
        LOGI("Reset stretcher");
    }
    
    int getLatency() const {
        return stretch.inputLatency() + stretch.outputLatency();
    }
};

extern "C" {

/**
 * Create a new Signalsmith stretcher instance.
 * Returns handle (pointer) to the context, or 0 on failure.
 */
JNIEXPORT jlong JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_create(
    JNIEnv* env, jobject thiz, jint sampleRate, jint channels) {
    
    try {
        SignalsmithContext* ctx = new SignalsmithContext(sampleRate, channels);
        return reinterpret_cast<jlong>(ctx);
    } catch (const std::exception& e) {
        LOGE("Failed to create SignalsmithContext: %s", e.what());
        return 0;
    }
}

/**
 * Destroy the stretcher instance and free resources.
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_destroy(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle != 0) {
        SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
        delete ctx;
    }
}

/**
 * Set the time ratio (1.0 = normal speed, 2.0 = half speed, 0.5 = double speed).
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_setTimeRatio(
    JNIEnv* env, jobject thiz, jlong handle, jdouble ratio) {
    
    if (handle != 0) {
        SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
        ctx->setTimeRatio(ratio);
    }
}

/**
 * Set the pitch scale (1.0 = normal pitch).
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_setPitchScale(
    JNIEnv* env, jobject thiz, jlong handle, jdouble scale) {
    
    if (handle != 0) {
        SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
        ctx->setPitchScale(scale);
    }
}

/**
 * Process input samples.
 * @param input Interleaved short samples
 * @param sampleFrames Number of sample frames (not total samples)
 * @return Number of output sample frames available
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_process(
    JNIEnv* env, jobject thiz, jlong handle, jshortArray input, jint sampleFrames) {
    
    if (handle == 0 || input == nullptr) return 0;
    
    SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
    
    jshort* inputPtr = env->GetShortArrayElements(input, nullptr);
    if (inputPtr == nullptr) return 0;
    
    int result = ctx->process(inputPtr, sampleFrames);
    
    env->ReleaseShortArrayElements(input, inputPtr, JNI_ABORT);
    
    return result;
}

/**
 * Retrieve processed samples.
 * @param output Buffer for interleaved short samples
 * @param maxSampleFrames Maximum number of sample frames to retrieve
 * @return Actual number of sample frames retrieved
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_retrieve(
    JNIEnv* env, jobject thiz, jlong handle, jshortArray output, jint maxSampleFrames) {
    
    if (handle == 0 || output == nullptr) return 0;
    
    SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
    
    jshort* outputPtr = env->GetShortArrayElements(output, nullptr);
    if (outputPtr == nullptr) return 0;
    
    int result = ctx->retrieve(outputPtr, maxSampleFrames);
    
    env->ReleaseShortArrayElements(output, outputPtr, 0);
    
    return result;
}

/**
 * Get number of sample frames available for retrieval.
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_available(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle == 0) return 0;
    
    SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
    return ctx->available();
}

/**
 * Get number of sample frames required before output is available.
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_getSamplesRequired(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle == 0) return 0;
    
    SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
    return ctx->getSamplesRequired();
}

/**
 * Reset the stretcher state.
 */
JNIEXPORT void JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_reset(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle != 0) {
        SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
        ctx->reset();
    }
}

/**
 * Get the latency in sample frames.
 */
JNIEXPORT jint JNICALL
Java_xyz_luan_audioplayers_player_SignalsmithNative_getLatency(
    JNIEnv* env, jobject thiz, jlong handle) {
    
    if (handle == 0) return 0;
    
    SignalsmithContext* ctx = reinterpret_cast<SignalsmithContext*>(handle);
    return ctx->getLatency();
}

} // extern "C"

