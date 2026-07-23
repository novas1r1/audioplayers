package xyz.luan.audioplayers.player

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.AudioProcessor.UnhandledAudioFormatException
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * ExoPlayer AudioProcessor that mixes metronome clicks into the stream
 * based on the *media-time* position of the frames flowing through it.
 *
 * It MUST be the first processor in the sink chain (before the Signalsmith
 * time-stretcher): there the frames are pure media time at natural rate, so
 * a frame counter is speed-independent and click placement is sample-exact.
 * The clicks then pass through the stretcher together with the music —
 * identical behavior to the app's baked click track.
 *
 * Position tracking: DefaultAudioSink flushes processors without position
 * info, so [ExoPlayerWrapper] pushes the target position via
 * [setPendingAnchor] *before* every operation that triggers a flush (seek,
 * stop, new source). [onFlush] adopts a pending anchor if one is set and
 * otherwise preserves the current position — a sink flush without a seek
 * (e.g. a mid-stream reconfigure) must not reset the grid.
 *
 * The processor is always active; enable/disable is a @Volatile config flag
 * checked per buffer. (A dynamic isActive() would only be observed at the
 * next flush — the toggle would not be instant.)
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ClickTrackAudioProcessor : BaseAudioProcessor() {

    companion object {
        private const val PENDING_NONE = Long.MIN_VALUE
    }

    /** Written on the platform thread, read on the playback thread. */
    @Volatile
    private var config: ClickTrackConfig? = null

    /** Media-time ms to adopt at the next flush; sentinel = none pending. */
    @Volatile
    private var pendingAnchorMs: Long = PENDING_NONE

    // Playback-thread confined state.
    private var positionFrames: Long = 0
    private var grid: ClickGrid? = null
    private var gridConfig: ClickTrackConfig? = null
    private var gridSampleRate: Int = 0

    /** Atomically swaps the click configuration (null or disabled = silent). */
    fun setConfig(config: ClickTrackConfig?) {
        this.config = config
    }

    /**
     * Announces the media position the stream will restart at. Call before
     * the player operation that triggers the sink flush (seekTo/stop/
     * setSource) — the flush arrives later on the playback thread.
     */
    fun setPendingAnchor(positionMs: Long) {
        pendingAnchorMs = positionMs
    }

    @Throws(UnhandledAudioFormatException::class)
    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }

    override fun onFlush() {
        super.onFlush()
        val sampleRate = inputAudioFormat.sampleRate
        // Not configured yet — keep the pending anchor for the next flush.
        if (sampleRate <= 0) return

        val pending = pendingAnchorMs
        if (pending != PENDING_NONE) {
            positionFrames = pending * sampleRate / 1000
            pendingAnchorMs = PENDING_NONE
        }
        // No pending anchor: preserve the current position.
    }

    override fun onReset() {
        super.onReset()
        positionFrames = 0
        grid = null
        gridConfig = null
        gridSampleRate = 0
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        val outputBuffer = replaceOutputBuffer(remaining)
        val sampleRate = inputAudioFormat.sampleRate
        val channels = inputAudioFormat.channelCount
        val frames = if (channels > 0) remaining / (2 * channels) else 0

        val cfg = config
        if (cfg == null || !cfg.enabled || cfg.bpm <= 0 || cfg.volume <= 0f ||
            sampleRate <= 0 || frames == 0
        ) {
            // Passthrough. Copy byte-by-byte: ExoPlayer reuses buffers and a
            // bulk put(inputBuffer) can throw "source buffer is this buffer".
            while (inputBuffer.hasRemaining()) {
                outputBuffer.put(inputBuffer.get())
            }
            outputBuffer.flip()
            positionFrames += frames
            return
        }

        val activeGrid = gridFor(cfg, sampleRate)
        val start = positionFrames
        val end = start + frames
        val pulses = activeGrid.pulsesOverlapping(start, end)

        val originalOrder = inputBuffer.order()
        inputBuffer.order(ByteOrder.LITTLE_ENDIAN)
        outputBuffer.order(ByteOrder.LITTLE_ENDIAN)

        for (f in 0 until frames) {
            val frame = start + f
            var click = 0.0
            for (pulse in pulses) {
                click += ClickSynth.sample(
                    i = frame - pulse.startFrame,
                    clickFrames = activeGrid.clickFrames,
                    freqHz = pulse.freqHz,
                    gain = pulse.gain,
                    volume = cfg.volume,
                    sampleRate = sampleRate,
                )
            }
            if (click == 0.0) {
                for (ch in 0 until channels) {
                    outputBuffer.putShort(inputBuffer.short)
                }
            } else {
                val clickValue = click.toInt()
                for (ch in 0 until channels) {
                    val mixed = (inputBuffer.short + clickValue)
                        .coerceIn(-32768, 32767)
                    outputBuffer.putShort(mixed.toShort())
                }
            }
        }

        inputBuffer.order(originalOrder)
        outputBuffer.flip()
        positionFrames = end
    }

    private fun gridFor(cfg: ClickTrackConfig, sampleRate: Int): ClickGrid {
        val cached = grid
        if (cached != null && gridConfig == cfg && gridSampleRate == sampleRate) {
            return cached
        }
        val created = ClickGrid(cfg, sampleRate)
        grid = created
        gridConfig = cfg
        gridSampleRate = sampleRate
        return created
    }
}
