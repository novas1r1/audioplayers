package xyz.luan.audioplayers.player

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test

class ClickGridTest {

    private val sampleRate = 44100

    private fun config(
        bpm: Int = 120,
        anchorMs: Long? = null,
        offsetMs: Long = 0,
        beatsPerBar: Int = 4,
        pulsesPerBeat: Int = 1,
    ) = ClickTrackConfig(
        enabled = true,
        bpm = bpm,
        anchorMs = anchorMs,
        offsetMs = offsetMs,
        beatsPerBar = beatsPerBar,
        pulsesPerBeat = pulsesPerBeat,
        volume = 1.0f,
    )

    private fun framesOf(ms: Long): Long =
        Math.round(ms * sampleRate / 1000.0)

    @Test
    fun `beats land on the grid at 120 bpm`() {
        val grid = ClickGrid(config(), sampleRate)

        // 120 BPM -> beats every 500 ms -> every 22050 frames.
        val pulses = grid.pulsesOverlapping(0, framesOf(2000))

        assertThat(pulses.map { it.startFrame })
            .containsExactly(0L, 22050L, 44100L, 66150L)
    }

    @Test
    fun `anchor and offset shift the grid`() {
        val grid = ClickGrid(config(anchorMs = 100, offsetMs = 25), sampleRate)

        val pulses = grid.pulsesOverlapping(0, framesOf(1200))

        // Grid at 125 + n*500 ms.
        assertThat(pulses.map { it.startFrame })
            .containsExactly(framesOf(125), framesOf(625), framesOf(1125))
    }

    @Test
    fun `accent falls on the bar downbeat including left of the anchor`() {
        // Anchor at 1000 ms; the grid extends left to 500 and 0 ms with
        // negative pulse indices. In 4/4 the accent lands where m % 4 == 0.
        val grid = ClickGrid(config(anchorMs = 1000), sampleRate)

        val pulses = grid.pulsesOverlapping(0, framesOf(3200))

        assertThat(pulses.map { it.startFrame }).containsExactly(
            framesOf(0), framesOf(500), framesOf(1000), framesOf(1500),
            framesOf(2000), framesOf(2500), framesOf(3000),
        )
        val accents = pulses.filter { it.freqHz == ClickSynth.ACCENT_FREQ_HZ }
        // m == 0 at the anchor (1000 ms) and m == 4 at 3000 ms; the previous
        // accent (m == -4 at -1000 ms) is before media start.
        assertThat(accents.map { it.startFrame })
            .containsExactly(framesOf(1000), framesOf(3000))
    }

    @Test
    fun `subdivision pulses sit between beats and are marked as such`() {
        val grid = ClickGrid(config(pulsesPerBeat = 2), sampleRate)

        val pulses = grid.pulsesOverlapping(0, framesOf(1000))

        assertThat(pulses.map { it.startFrame }).containsExactly(
            framesOf(0), framesOf(250), framesOf(500), framesOf(750),
        )
        assertThat(pulses[1].freqHz).isEqualTo(ClickSynth.SUBDIVISION_FREQ_HZ)
        assertThat(pulses[1].gain).isEqualTo(ClickSynth.SUBDIVISION_GAIN)
        assertThat(pulses[2].freqHz).isEqualTo(ClickSynth.BEAT_FREQ_HZ)
    }

    @Test
    fun `clicks straddling the range start are included`() {
        val grid = ClickGrid(config(), sampleRate)
        val clickFrames = grid.clickFrames

        // Range starts a few frames into the beat-1 click at 22050.
        val pulses = grid.pulsesOverlapping(22050L + clickFrames / 2, framesOf(600))

        assertThat(pulses.map { it.startFrame }).containsExactly(22050L)
    }

    @Test
    fun `clicks fully before the range or media start are excluded`() {
        val grid = ClickGrid(config(), sampleRate)
        val clickFrames = grid.clickFrames

        // Just past the end of the beat-0 click: only beat 1 remains.
        val pulses = grid.pulsesOverlapping(clickFrames.toLong(), framesOf(600))

        assertThat(pulses.map { it.startFrame }).containsExactly(22050L)
    }

    @Test
    fun `click length shrinks so packed pulses never overlap`() {
        // 400 BPM sixteenths: pulse gap = 60/400/4 s = 37.5 ms < 45 ms click.
        val grid = ClickGrid(config(bpm = 400, pulsesPerBeat = 4), sampleRate)

        val pulseGapFrames = 60.0 * sampleRate / 400 / 4
        assertThat(grid.clickFrames).isLessThanOrEqualTo((pulseGapFrames * 0.8).toInt())
        assertThat(grid.clickFrames).isGreaterThan(0)
    }

    @Test
    fun `empty range yields no pulses`() {
        val grid = ClickGrid(config(), sampleRate)
        assertThat(grid.pulsesOverlapping(500, 500)).isEmpty()
        assertThat(grid.pulsesOverlapping(500, 400)).isEmpty()
    }

    @Test
    fun `grid math respects a non-44100 sample rate`() {
        val grid = ClickGrid(config(), 48000)

        val pulses = grid.pulsesOverlapping(0, 48000L)

        // 120 BPM at 48 kHz: beats every 24000 frames.
        assertThat(pulses.map { it.startFrame }).containsExactly(0L, 24000L)
    }
}
