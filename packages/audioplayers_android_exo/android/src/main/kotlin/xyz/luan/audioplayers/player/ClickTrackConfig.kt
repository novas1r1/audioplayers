package xyz.luan.audioplayers.player

/**
 * Metronome click-track configuration, mirrored from the Dart side via the
 * `setClickTrack` method channel call.
 *
 * The beat grid lives in *media time*: `anchorMs + offsetMs + n * beatPeriod(bpm)`.
 * The processor consuming this sits before the Signalsmith time-stretcher, so
 * media time is what its frames are measured in and playback speed never
 * affects click placement.
 *
 * Immutable by design: the config reference is swapped atomically
 * (@Volatile) between the platform thread and the audio playback thread.
 */
data class ClickTrackConfig(
    val enabled: Boolean,
    /** Original BPM of the song (grid tempo), NOT the sped-up value. */
    val bpm: Int,
    /** Song-time ms of a known beat (tap-to-align anchor); null = grid from 0. */
    val anchorMs: Long?,
    /** Additional grid shift in song-time ms (user nudge). */
    val offsetMs: Long,
    val beatsPerBar: Int,
    /** 1 = quarters only, 2 = eighths, 3 = triplets, 4 = sixteenths. */
    val pulsesPerBeat: Int,
    /** Click gain 0.0..1.0 relative to the song. */
    val volume: Float,
)
