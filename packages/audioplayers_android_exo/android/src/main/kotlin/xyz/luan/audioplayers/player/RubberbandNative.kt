package xyz.luan.audioplayers.player

/**
 * JNI interface for the Rubberband time-stretching library.
 * Provides native functions for real-time audio time-stretching while preserving pitch.
 */
object RubberbandNative {
    
    private var isLoaded = false
    
    /**
     * Load the native library. Safe to call multiple times.
     */
    @Synchronized
    fun ensureLoaded() {
        if (!isLoaded) {
            try {
                System.loadLibrary("rubberband_jni")
                isLoaded = true
            } catch (e: UnsatisfiedLinkError) {
                throw RuntimeException("Failed to load rubberband_jni native library", e)
            }
        }
    }
    
    /**
     * Create a new Rubberband stretcher instance.
     * @param sampleRate Audio sample rate in Hz (e.g., 44100, 48000)
     * @param channels Number of audio channels (1 for mono, 2 for stereo)
     * @return Handle to the native instance, or 0 on failure
     */
    external fun create(sampleRate: Int, channels: Int): Long
    
    /**
     * Destroy the stretcher instance and free all resources.
     * @param handle Handle returned by create()
     */
    external fun destroy(handle: Long)
    
    /**
     * Set the time ratio for time-stretching.
     * @param handle Handle returned by create()
     * @param ratio Time ratio: 1.0 = normal speed, 2.0 = half speed (slower), 0.5 = double speed (faster)
     *              To convert from playback speed: ratio = 1.0 / speed
     */
    external fun setTimeRatio(handle: Long, ratio: Double)
    
    /**
     * Set the pitch scale for pitch-shifting.
     * @param handle Handle returned by create()
     * @param scale Pitch scale: 1.0 = normal pitch, 2.0 = one octave up, 0.5 = one octave down
     */
    external fun setPitchScale(handle: Long, scale: Double)
    
    /**
     * Process input audio samples through the stretcher.
     * @param handle Handle returned by create()
     * @param input Interleaved audio samples as signed 16-bit shorts
     * @param sampleFrames Number of sample frames (total samples / channels)
     * @return Number of output sample frames available for retrieval
     */
    external fun process(handle: Long, input: ShortArray, sampleFrames: Int): Int
    
    /**
     * Retrieve processed audio samples.
     * @param handle Handle returned by create()
     * @param output Buffer to receive interleaved audio samples as signed 16-bit shorts
     * @param maxSampleFrames Maximum number of sample frames to retrieve
     * @return Actual number of sample frames retrieved
     */
    external fun retrieve(handle: Long, output: ShortArray, maxSampleFrames: Int): Int
    
    /**
     * Get the number of sample frames available for retrieval.
     * @param handle Handle returned by create()
     * @return Number of sample frames available
     */
    external fun available(handle: Long): Int
    
    /**
     * Get the number of sample frames required before output is available.
     * @param handle Handle returned by create()
     * @return Minimum number of sample frames to process before output
     */
    external fun getSamplesRequired(handle: Long): Int
    
    /**
     * Reset the stretcher state, clearing all internal buffers.
     * Call this when seeking or changing tracks.
     * @param handle Handle returned by create()
     */
    external fun reset(handle: Long)
    
    /**
     * Get the latency introduced by the stretcher in sample frames.
     * @param handle Handle returned by create()
     * @return Latency in sample frames
     */
    external fun getLatency(handle: Long): Int
}

