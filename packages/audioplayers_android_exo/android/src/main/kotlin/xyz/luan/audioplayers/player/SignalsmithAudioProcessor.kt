package xyz.luan.audioplayers.player

import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.AudioProcessor.UnhandledAudioFormatException
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * ExoPlayer AudioProcessor that uses the Signalsmith Stretch library for time-stretching.
 * This allows changing playback speed while preserving pitch.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class SignalsmithAudioProcessor : BaseAudioProcessor() {
    
    companion object {
        private const val TAG = "SignalsmithAudioProc"
        private const val DEFAULT_BUFFER_SIZE = 4096 // Sample frames
    }
    
    private var handle: Long = 0
    private var speed: Float = 1.0f
    private var enabled: Boolean = true
    
    // Buffers for audio processing
    private var inputShortBuffer: ShortArray = ShortArray(DEFAULT_BUFFER_SIZE * 2) // Stereo
    private var outputShortBuffer: ShortArray = ShortArray(DEFAULT_BUFFER_SIZE * 4) // Extra space for stretching
    
    // Track configuration
    private var configuredSampleRate: Int = 0
    private var configuredChannels: Int = 0
    
    private var nativeLibraryLoaded = false
    
    init {
        try {
            SignalsmithNative.ensureLoaded()
            nativeLibraryLoaded = true
            Log.i(TAG, "Signalsmith native library loaded successfully!")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load Signalsmith native library", e)
            nativeLibraryLoaded = false
            enabled = false
        }
    }
    
    /**
     * Set the playback speed.
     * @param speed Playback speed multiplier: 1.0 = normal, 0.5 = half speed, 2.0 = double speed
     */
    fun setSpeed(speed: Float) {
        val previousSpeed = this.speed
        this.speed = speed.coerceIn(0.1f, 4.0f) // Limit to reasonable range
        
        Log.i(TAG, "setSpeed called: $previousSpeed -> ${this.speed}, handle=$handle, enabled=$enabled, nativeLoaded=$nativeLibraryLoaded")
        
        if (handle != 0L && enabled) {
            // Time ratio is inverse of speed: slower playback = higher ratio
            val timeRatio = 1.0 / this.speed
            SignalsmithNative.setTimeRatio(handle, timeRatio)
            Log.i(TAG, "Applied Signalsmith timeRatio: $timeRatio for speed ${this.speed}")
        } else {
            Log.w(TAG, "Cannot apply speed: handle=$handle, enabled=$enabled")
        }
    }
    
    /**
     * Enable or disable the Signalsmith processing.
     * When disabled, audio passes through unchanged.
     */
    fun setEnabled(enabled: Boolean) {
        this.enabled = enabled
        Log.d(TAG, "Signalsmith processing ${if (enabled) "enabled" else "disabled"}")
    }
    
    /**
     * Check if Signalsmith processing is active.
     * Returns true if enabled and speed != 1.0
     */
    fun isSignalsmithActive(): Boolean {
        return enabled && handle != 0L && speed != 1.0f
    }
    
    @Throws(UnhandledAudioFormatException::class)
    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        // Only handle 16-bit PCM audio
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw UnhandledAudioFormatException(inputAudioFormat)
        }
        
        // Destroy previous instance if configuration changed
        if (handle != 0L && 
            (configuredSampleRate != inputAudioFormat.sampleRate || 
             configuredChannels != inputAudioFormat.channelCount)) {
            SignalsmithNative.destroy(handle)
            handle = 0
        }
        
        // Create new Signalsmith instance
        if (handle == 0L && enabled) {
            handle = SignalsmithNative.create(
                inputAudioFormat.sampleRate,
                inputAudioFormat.channelCount
            )
            
            if (handle != 0L) {
                configuredSampleRate = inputAudioFormat.sampleRate
                configuredChannels = inputAudioFormat.channelCount
                
                // Resize buffers based on channel count
                val bufferSamples = DEFAULT_BUFFER_SIZE * inputAudioFormat.channelCount
                inputShortBuffer = ShortArray(bufferSamples)
                outputShortBuffer = ShortArray(bufferSamples * 4)
                
                // Apply current speed setting
                val timeRatio = 1.0 / speed
                SignalsmithNative.setTimeRatio(handle, timeRatio)
                
                Log.d(TAG, "Configured: sampleRate=${inputAudioFormat.sampleRate}, " +
                        "channels=${inputAudioFormat.channelCount}, speed=$speed")
            } else {
                Log.e(TAG, "Failed to create Signalsmith instance")
                enabled = false
            }
        }
        
        // Output format is the same as input (we don't change sample rate or channels)
        return inputAudioFormat
    }
    
    private var frameCounter = 0L
    
    override fun queueInput(inputBuffer: ByteBuffer) {
        frameCounter++
        
        // Log every 100 frames to avoid spam
        if (frameCounter % 100 == 0L) {
            Log.d(TAG, "queueInput: frame=$frameCounter, active=${isSignalsmithActive()}, speed=$speed, handle=$handle, bytes=${inputBuffer.remaining()}")
        }
        
        // Pass through if not active or no input
        if (!isSignalsmithActive() || !inputBuffer.hasRemaining()) {
            val remaining = inputBuffer.remaining()
            val outputBuffer = replaceOutputBuffer(remaining)
            // Copy byte-by-byte to avoid "source buffer is this buffer" error
            // when ExoPlayer reuses buffers
            while (inputBuffer.hasRemaining()) {
                outputBuffer.put(inputBuffer.get())
            }
            outputBuffer.flip()
            return
        }
        
        val bytesPerSample = 2 // 16-bit
        val channels = configuredChannels
        val totalBytes = inputBuffer.remaining()
        val totalSamples = totalBytes / bytesPerSample
        val sampleFrames = totalSamples / channels
        
        // Ensure input buffer is large enough
        if (inputShortBuffer.size < totalSamples) {
            inputShortBuffer = ShortArray(totalSamples)
        }
        
        // Convert bytes to shorts
        val originalOrder = inputBuffer.order()
        inputBuffer.order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until totalSamples) {
            inputShortBuffer[i] = inputBuffer.short
        }
        inputBuffer.order(originalOrder)
        
        // Process through Signalsmith
        SignalsmithNative.process(handle, inputShortBuffer, sampleFrames)
        
        // Retrieve available output
        val availableFrames = SignalsmithNative.available(handle)
        if (availableFrames > 0) {
            // Ensure output buffer is large enough
            val outputSamples = availableFrames * channels
            if (outputShortBuffer.size < outputSamples) {
                outputShortBuffer = ShortArray(outputSamples)
            }
            
            val retrievedFrames = SignalsmithNative.retrieve(handle, outputShortBuffer, availableFrames)
            val retrievedSamples = retrievedFrames * channels
            val outputBytes = retrievedSamples * bytesPerSample
            
            // Convert shorts back to bytes
            val outputBuffer = replaceOutputBuffer(outputBytes)
            outputBuffer.order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until retrievedSamples) {
                outputBuffer.putShort(outputShortBuffer[i])
            }
            outputBuffer.flip()
        } else {
            // No output available yet, output silence (or could buffer)
            // For real-time, we just output an empty buffer
            val outputBuffer = replaceOutputBuffer(0)
            outputBuffer.flip()
        }
    }
    
    override fun onQueueEndOfStream() {
        // Flush remaining samples
        if (handle != 0L && enabled) {
            // Process an empty buffer to signal end
            val channels = configuredChannels
            val bytesPerSample = 2
            
            // Retrieve any remaining output
            var availableFrames = SignalsmithNative.available(handle)
            if (availableFrames > 0) {
                val outputSamples = availableFrames * channels
                if (outputShortBuffer.size < outputSamples) {
                    outputShortBuffer = ShortArray(outputSamples)
                }
                
                val retrievedFrames = SignalsmithNative.retrieve(handle, outputShortBuffer, availableFrames)
                val retrievedSamples = retrievedFrames * channels
                val outputBytes = retrievedSamples * bytesPerSample
                
                val outputBuffer = replaceOutputBuffer(outputBytes)
                outputBuffer.order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until retrievedSamples) {
                    outputBuffer.putShort(outputShortBuffer[i])
                }
                outputBuffer.flip()
            }
        }
        
        super.onQueueEndOfStream()
    }
    
    override fun onFlush() {
        super.onFlush()
        if (handle != 0L) {
            SignalsmithNative.reset(handle)
            Log.d(TAG, "Flushed Signalsmith state")
        }
    }
    
    override fun onReset() {
        super.onReset()
        if (handle != 0L) {
            SignalsmithNative.destroy(handle)
            handle = 0
            Log.d(TAG, "Reset: destroyed Signalsmith instance")
        }
        configuredSampleRate = 0
        configuredChannels = 0
    }
    
    /**
     * Get the latency introduced by Signalsmith in milliseconds.
     */
    fun getLatencyMs(): Int {
        if (handle == 0L || configuredSampleRate == 0) return 0
        val latencyFrames = SignalsmithNative.getLatency(handle)
        return (latencyFrames * 1000) / configuredSampleRate
    }
}

