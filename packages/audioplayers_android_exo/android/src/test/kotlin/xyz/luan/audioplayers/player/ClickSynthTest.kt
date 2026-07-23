package xyz.luan.audioplayers.player

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import kotlin.math.abs

class ClickSynthTest {

    private val sampleRate = 44100
    private val clickFrames = (ClickSynth.MAX_CLICK_MS * sampleRate / 1000).toInt()

    private fun peak(freqHz: Double, gain: Double, volume: Float = 1.0f): Double {
        var max = 0.0
        for (i in 0 until clickFrames) {
            val v = abs(
                ClickSynth.sample(
                    i.toLong(), clickFrames, freqHz, gain, volume, sampleRate,
                ),
            )
            if (v > max) max = v
        }
        return max
    }

    @Test
    fun `returns zero outside the click window`() {
        assertThat(
            ClickSynth.sample(-1, clickFrames, ClickSynth.BEAT_FREQ_HZ, 1.0, 1.0f, sampleRate),
        ).isZero()
        assertThat(
            ClickSynth.sample(clickFrames.toLong(), clickFrames, ClickSynth.BEAT_FREQ_HZ, 1.0, 1.0f, sampleRate),
        ).isZero()
    }

    @Test
    fun `starts silent (1 ms attack) and never exceeds the headroom peak`() {
        assertThat(
            ClickSynth.sample(0, clickFrames, ClickSynth.ACCENT_FREQ_HZ, 1.0, 1.0f, sampleRate),
        ).isZero()
        assertThat(peak(ClickSynth.ACCENT_FREQ_HZ, ClickSynth.ACCENT_GAIN))
            .isLessThanOrEqualTo(ClickSynth.PEAK)
    }

    @Test
    fun `accent is louder than beat which is louder than subdivision`() {
        val accent = peak(ClickSynth.ACCENT_FREQ_HZ, ClickSynth.ACCENT_GAIN)
        val beat = peak(ClickSynth.BEAT_FREQ_HZ, ClickSynth.BEAT_GAIN)
        val sub = peak(ClickSynth.SUBDIVISION_FREQ_HZ, ClickSynth.SUBDIVISION_GAIN)

        assertThat(accent).isGreaterThan(beat)
        assertThat(beat).isGreaterThan(sub)
    }

    @Test
    fun `volume scales the click linearly`() {
        val full = peak(ClickSynth.BEAT_FREQ_HZ, ClickSynth.BEAT_GAIN, volume = 1.0f)
        val half = peak(ClickSynth.BEAT_FREQ_HZ, ClickSynth.BEAT_GAIN, volume = 0.5f)

        assertThat(half).isCloseTo(full / 2, org.assertj.core.data.Offset.offset(1.0))
    }

    @Test
    fun `envelope decays towards the click end`() {
        val early = abs(
            ClickSynth.sample(
                (sampleRate / 1000 + 30).toLong(), // just past the attack, near a sine peak
                clickFrames, ClickSynth.BEAT_FREQ_HZ, 1.0, 1.0f, sampleRate,
            ),
        )
        var lateMax = 0.0
        for (i in clickFrames - 100 until clickFrames) {
            val v = abs(
                ClickSynth.sample(i.toLong(), clickFrames, ClickSynth.BEAT_FREQ_HZ, 1.0, 1.0f, sampleRate),
            )
            if (v > lateMax) lateMax = v
        }
        assertThat(lateMax).isLessThan(early)
    }

    /**
     * Cross-check against the Dart ClickTrackRenderer formula
     * (repeatlab_app/lib/core/utils/click_track_renderer.dart): both must
     * compute `0.85*32767 * gain * attack * exp(-i/tau) * sin(2*pi*f*i/sr)`.
     */
    @Test
    fun `matches the shared synthesis formula at probe points`() {
        val i = 200L
        val tau = clickFrames / 5.0
        val expected = ClickSynth.PEAK * ClickSynth.BEAT_GAIN *
            Math.exp(-i / tau) *
            Math.sin(2 * Math.PI * ClickSynth.BEAT_FREQ_HZ * i / sampleRate)

        val actual = ClickSynth.sample(
            i, clickFrames, ClickSynth.BEAT_FREQ_HZ, ClickSynth.BEAT_GAIN, 1.0f, sampleRate,
        )

        assertThat(actual).isCloseTo(expected, org.assertj.core.data.Offset.offset(1e-6))
    }
}
