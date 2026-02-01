package xyz.luan.audioplayers.player

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import android.util.SparseArray
import androidx.annotation.RequiresApi
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.C.TIME_UNSET
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.UnhandledAudioFormatException
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.source.BytesSource
import xyz.luan.audioplayers.source.Source
import xyz.luan.audioplayers.source.UrlSource
import java.nio.ByteBuffer

class ExoPlayerWrapper(
    private val wrappedPlayer: WrappedPlayer,
    appContext: Context,
) : PlayerWrapper {

    companion object {
        private const val TAG = "ExoPlayerWrapper"
    }

    // Position tracking for Signalsmith mode
    // When using Signalsmith, ExoPlayer runs at 1.0x but we need to report adjusted position
    private var signalsmithSpeed: Float = 1.0f
    private var lastSpeedChangePosition: Long = 0  // ExoPlayer position when speed changed
    private var lastSpeedChangeContentPosition: Long = 0  // Actual content position when speed changed
    private var lastSpeedChangeTime: Long = 0  // System time when speed changed

    class ExoPlayerListener(private val wrappedPlayer: WrappedPlayer) : androidx.media3.common.Player.Listener {
        override fun onPlayerError(error: PlaybackException) {
            if (error.errorCode == PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED ||
                error.errorCode == PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND
            ) {
                wrappedPlayer.handleError(
                    errorCode = "AndroidAudioError",
                    errorMessage = "Failed to set source. For troubleshooting, see: " +
                        "https://github.com/bluefireteam/audioplayers/blob/main/troubleshooting.md",
                    errorDetails = "${error.errorCodeName}\n${error.message}\n${error.stackTraceToString()}",
                )
                return
            }
            wrappedPlayer.handleError(
                errorCode = error.errorCodeName,
                errorMessage = error.message,
                errorDetails = error.stackTraceToString(),
            )
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_IDLE -> {} // TODO(gustl22): may can use or leave as no-op
                Player.STATE_BUFFERING -> wrappedPlayer.onBuffering(0)
                Player.STATE_READY -> wrappedPlayer.onPrepared()
                Player.STATE_ENDED -> wrappedPlayer.onCompletion()
            }
        }
    }

    private var player: ExoPlayer

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private var channelMixingAudioProcessor = AdaptiveChannelMixingAudioProcessor()
    
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private var signalsmithAudioProcessor = SignalsmithAudioProcessor()
    
    private lateinit var audioSink: AudioSink
    
    // Track whether Signalsmith is available and should be used for rate changes
    private var useSignalsmithForRate = true

    init {
        player = createPlayer(appContext)
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun createPlayer(appContext: Context): ExoPlayer {
        val renderersFactory = object : DefaultRenderersFactory(appContext) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean,
            ): AudioSink {
                // Signalsmith processor comes first for time-stretching, then channel mixing for balance
                audioSink = DefaultAudioSink.Builder(appContext)
                    .setAudioProcessors(arrayOf(signalsmithAudioProcessor, channelMixingAudioProcessor))
                    .build()
                return audioSink
            }
        }

        return ExoPlayer.Builder(appContext).setRenderersFactory(renderersFactory).build().apply {
            addListener(ExoPlayerListener(wrappedPlayer))
        }
    }

    override fun getDuration(): Int? {
        if (player.isCurrentMediaItemLive) {
            return null
        }
        return (player.duration.takeUnless { it == TIME_UNSET })?.toInt()
    }

    override fun getCurrentPosition(): Int {
        val exoPosition = player.currentPosition

        // When using Signalsmith, ExoPlayer runs at 1.0x but audio plays at signalsmithSpeed
        // We need to calculate the actual content position
        if (useSignalsmithForRate && signalsmithSpeed != 1.0f) {
            // Calculate how much ExoPlayer has advanced since the last speed change
            val exoAdvance = exoPosition - lastSpeedChangePosition
            // The actual content has advanced at signalsmithSpeed rate
            val contentAdvance = (exoAdvance * signalsmithSpeed).toLong()
            // Return the adjusted content position
            val adjustedPosition = lastSpeedChangeContentPosition + contentAdvance
            return adjustedPosition.toInt()
        }

        return exoPosition.toInt()
    }

    override fun start() {
        player.play()
    }

    override fun pause() {
        player.pause()
    }

    override fun stop() {
        player.pause()
        player.seekTo(0)
        // Reset position tracking
        lastSpeedChangePosition = 0
        lastSpeedChangeContentPosition = 0
    }

    override fun seekTo(position: Int) {
        player.seekTo(position.toLong())

        // Reset position tracking after seek
        // The seek position is the new content position
        lastSpeedChangePosition = position.toLong()
        lastSpeedChangeContentPosition = position.toLong()
        lastSpeedChangeTime = System.currentTimeMillis()

        wrappedPlayer.onSeekComplete()
    }

    override fun release() {
        player.stop()
        player.clearMediaItems()
    }

    override fun dispose() {
        release()
        player.release()
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    override fun setVolume(leftVolume: Float, rightVolume: Float) {
        this.channelMixingAudioProcessor.putChannelMixingMatrix(
            ChannelMixingMatrix(2, 2, floatArrayOf(leftVolume, 0f, 0f, rightVolume)),
        )
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    override fun setRate(rate: Float) {
        Log.i(TAG, "setRate called: rate=$rate, useSignalsmithForRate=$useSignalsmithForRate")
        if (useSignalsmithForRate) {
            // Capture current position before changing speed for position tracking
            val currentExoPosition = player.currentPosition
            val currentContentPosition = getCurrentPosition().toLong()

            // Use Signalsmith for pitch-preserving time-stretching
            Log.i(TAG, "Using Signalsmith for rate change")
            signalsmithAudioProcessor.setSpeed(rate)
            // Keep ExoPlayer at 1.0x speed - Signalsmith handles the actual tempo change
            player.setPlaybackSpeed(1.0f)

            // Update position tracking for adjusted position calculation
            lastSpeedChangePosition = currentExoPosition
            lastSpeedChangeContentPosition = currentContentPosition
            lastSpeedChangeTime = System.currentTimeMillis()
            signalsmithSpeed = rate

            Log.i(TAG, "Position tracking updated: exoPos=$currentExoPosition, contentPos=$currentContentPosition, speed=$rate")
        } else {
            // Fallback to native speed control (changes pitch along with speed)
            Log.i(TAG, "Using native ExoPlayer speed control")
            signalsmithAudioProcessor.setSpeed(1.0f)
            player.setPlaybackSpeed(rate)
            // Reset Signalsmith tracking
            signalsmithSpeed = 1.0f
        }
    }
    
    /**
     * Enable or disable Signalsmith time-stretching for rate changes.
     * When enabled (default), playback rate changes preserve pitch.
     * When disabled, native ExoPlayer speed control is used (pitch changes with speed).
     */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    fun setPreservePitch(preservePitch: Boolean) {
        useSignalsmithForRate = preservePitch
        signalsmithAudioProcessor.setEnabled(preservePitch)
    }

    override fun setLooping(looping: Boolean) {
        player.repeatMode = if (looping) {
            Player.REPEAT_MODE_ONE
        } else {
            Player.REPEAT_MODE_OFF
        }
    }

    override fun updateContext(context: AudioContextAndroid) {
        val builder = AudioAttributes.Builder()
        builder.setContentType(context.contentType)
        builder.setUsage(context.usageType)

        player.setAudioAttributes(
            builder.build(),
            false,
        )
    }

    @RequiresApi(Build.VERSION_CODES.M)
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    override fun setSource(source: Source) {
        player.clearMediaItems()
        // Reset position tracking for new source
        lastSpeedChangePosition = 0
        lastSpeedChangeContentPosition = 0
        signalsmithSpeed = 1.0f

        if (source is UrlSource) {
            player.setMediaItem(MediaItem.fromUri(source.url))
        } else if (source is BytesSource) {
            val byteArrayDataSource = ByteArrayDataSource(source.data)
            val factory = DataSource.Factory { byteArrayDataSource; }
            val mediaSource: MediaSource = ProgressiveMediaSource.Factory(factory).createMediaSource(
                MediaItem.fromUri(Uri.EMPTY),
            )
            player.setMediaSource(mediaSource)
        }
    }

    override fun prepare() {
        player.prepare()
    }
}

/**
 * See Implementation of [androidx.media3.common.audio.ChannelMixingAudioProcessor] for reference.
 * See: https://github.com/androidx/media/blob/8ea49025aaf14c7e7d953df8ca2f08a76d9d4275/libraries/common/src/main/java/androidx/media3/common/audio/ChannelMixingAudioProcessor.java
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AdaptiveChannelMixingAudioProcessor : BaseAudioProcessor() {
    private val matrixByInputChannelCount: SparseArray<ChannelMixingMatrix?> = SparseArray<ChannelMixingMatrix?>()

    fun putChannelMixingMatrix(matrix: ChannelMixingMatrix) {
        matrixByInputChannelCount.put(matrix.inputChannelCount, matrix)
    }

    @Throws(UnhandledAudioFormatException::class)
    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw UnhandledAudioFormatException(inputAudioFormat)
        } else {
            // We keep the same format; we're not altering the channel count.
            return inputAudioFormat
        }
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val channelMixingMatrix = matrixByInputChannelCount[inputAudioFormat.channelCount]
        if (channelMixingMatrix == null || channelMixingMatrix.isIdentity) {
            // No need to transform, if balance is equalized.
            val outputBuffer = this.replaceOutputBuffer(inputBuffer.remaining())
            if (inputBuffer.hasRemaining()) {
                outputBuffer.put(inputBuffer)
            }
            outputBuffer.flip()
            return
        }

        val outputBuffer = this.replaceOutputBuffer(inputBuffer.remaining())
        val inputChannelCount = channelMixingMatrix.inputChannelCount
        val outputChannelCount = channelMixingMatrix.outputChannelCount
        val outputFrame = FloatArray(outputChannelCount)

        while (inputBuffer.hasRemaining()) {
            var inputValue: Short
            var inputChannelIndex = 0
            while (inputChannelIndex < inputChannelCount) {
                inputValue = inputBuffer.getShort()

                for (outputChannelIndex in 0 until outputChannelCount) {
                    outputFrame[outputChannelIndex] += channelMixingMatrix.getMixingCoefficient(
                        inputChannelIndex,
                        outputChannelIndex,
                    ) * inputValue.toFloat()
                }
                ++inputChannelIndex
            }

            inputChannelIndex = 0
            while (inputChannelIndex < outputChannelCount) {
                inputValue =
                    outputFrame[inputChannelIndex].toInt().coerceIn(-32768, 32767).toShort()
                outputBuffer.put((inputValue.toInt() and 255).toByte())
                outputBuffer.put((inputValue.toInt() shr 8 and 255).toByte())
                outputFrame[inputChannelIndex] = 0.0f
                ++inputChannelIndex
            }
        }
        outputBuffer.flip()
    }
}
