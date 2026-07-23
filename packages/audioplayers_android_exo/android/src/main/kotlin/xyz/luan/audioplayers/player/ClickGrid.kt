package xyz.luan.audioplayers.player

import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * One click instance on the grid: it starts at [startFrame] (media-time
 * frames) and plays [ClickGrid.clickFrames] frames of a sine burst at
 * [freqHz] scaled by [gain].
 */
data class ClickPulse(
    val startFrame: Long,
    val freqHz: Double,
    val gain: Double,
)

/**
 * Pure beat-grid math in media-time frames — no media3 dependency, unit
 * tested on the JVM.
 *
 * All pulses (beats and subdivisions) form one uniform grid with spacing
 * `beatPeriod / pulsesPerBeat`, anchored at `anchorMs + offsetMs`. Pulse
 * index m is: accent when `m % (pulsesPerBeat * beatsPerBar) == 0`, beat
 * when `m % pulsesPerBeat == 0`, subdivision otherwise — the exact grid the
 * Dart `ClickTrackRenderer` bakes (repeatlab_app/lib/core/utils/
 * click_track_renderer.dart), so Android-native and iOS-baked clicks sound
 * identical.
 */
class ClickGrid(config: ClickTrackConfig, private val sampleRate: Int) {
    private val pulsesPerBeat = config.pulsesPerBeat.coerceIn(1, 8)
    private val beatsPerBar = config.beatsPerBar.coerceAtLeast(1)
    private val accentModulo = pulsesPerBeat * beatsPerBar

    /** Grid origin in frames (can be negative for negative offsets). */
    private val baseFrame: Double =
        ((config.anchorMs ?: 0L) + config.offsetMs) * sampleRate / 1000.0

    private val beatPeriodFrames: Double = 60.0 * sampleRate / config.bpm
    private val pulseGapFrames: Double = beatPeriodFrames / pulsesPerBeat

    /** Click length, shortened so tightly packed pulses never overlap. */
    val clickFrames: Int = min(
        ClickSynth.MAX_CLICK_MS * sampleRate / 1000.0,
        pulseGapFrames * 0.8,
    ).toInt().coerceAtLeast(1)

    /**
     * All pulses whose click audio overlaps the frame range
     * [startFrame, endFrame) — including clicks that started before the
     * range (straddling a buffer boundary) and pulses left of the anchor
     * (negative m: the grid extends over the whole file).
     */
    fun pulsesOverlapping(startFrame: Long, endFrame: Long): List<ClickPulse> {
        if (endFrame <= startFrame) return emptyList()

        // Smallest m whose click can still reach into the range.
        var m = ceil((startFrame - clickFrames - baseFrame) / pulseGapFrames).toLong()
        val pulses = mutableListOf<ClickPulse>()
        while (true) {
            val pulseStart = (baseFrame + m * pulseGapFrames).roundToLong()
            if (pulseStart >= endFrame) break
            // Media time starts at frame 0 — clicks fully before it never play.
            if (pulseStart + clickFrames > 0 && pulseStart + clickFrames > startFrame) {
                val phase = ((m % accentModulo) + accentModulo) % accentModulo
                pulses.add(
                    when {
                        phase == 0L -> ClickPulse(
                            pulseStart,
                            ClickSynth.ACCENT_FREQ_HZ,
                            ClickSynth.ACCENT_GAIN,
                        )
                        phase % pulsesPerBeat == 0L -> ClickPulse(
                            pulseStart,
                            ClickSynth.BEAT_FREQ_HZ,
                            ClickSynth.BEAT_GAIN,
                        )
                        else -> ClickPulse(
                            pulseStart,
                            ClickSynth.SUBDIVISION_FREQ_HZ,
                            ClickSynth.SUBDIVISION_GAIN,
                        )
                    },
                )
            }
            m++
        }
        return pulses
    }
}
