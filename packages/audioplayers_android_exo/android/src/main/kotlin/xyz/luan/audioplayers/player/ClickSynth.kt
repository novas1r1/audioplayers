package xyz.luan.audioplayers.player

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/**
 * Metronome click synthesis: a short sine burst with a 1 ms linear attack
 * and an exponential decay. Soft transients survive the Signalsmith
 * time-stretcher at extreme slowdowns much better than sharp ticks.
 *
 * Constants are an exact mirror of the Dart `ClickTrackRenderer`
 * (repeatlab_app/lib/core/utils/click_track_renderer.dart) — keep both in
 * sync so the native (Android) and baked (iOS) metronomes sound identical.
 */
object ClickSynth {
    const val ACCENT_FREQ_HZ = 1600.0
    const val BEAT_FREQ_HZ = 1050.0
    const val SUBDIVISION_FREQ_HZ = 800.0

    const val ACCENT_GAIN = 1.0
    const val BEAT_GAIN = 0.8
    const val SUBDIVISION_GAIN = 0.45

    /** Nominal click length; ClickGrid shortens it for packed pulses. */
    const val MAX_CLICK_MS = 45.0

    /** Peak amplitude leaves ~1.3 dB headroom before the saturating mix. */
    const val PEAK = 0.85 * 32767

    /**
     * The click's sample value at frame [i] (0-based within the click) for
     * a click of [clickFrames] length. Returns 0 outside the click.
     */
    fun sample(
        i: Long,
        clickFrames: Int,
        freqHz: Double,
        gain: Double,
        volume: Float,
        sampleRate: Int,
    ): Double {
        if (i < 0 || i >= clickFrames) return 0.0

        val attackFrames = sampleRate / 1000 // 1 ms linear attack avoids a DC pop
        val attack = if (attackFrames > 0 && i < attackFrames) {
            i.toDouble() / attackFrames
        } else {
            1.0
        }
        val tau = clickFrames / 5.0
        val envelope = attack * exp(-i / tau)
        return PEAK * gain * volume * envelope * sin(2 * PI * freqHz * i / sampleRate)
    }
}
