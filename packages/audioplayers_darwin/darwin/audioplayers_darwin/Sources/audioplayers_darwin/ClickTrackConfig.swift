import Foundation

/// Metronome click-track configuration, mirrored from the Dart side via the
/// `setClickTrack` method channel call.
///
/// The beat grid lives in *media time*: `anchorMs + offsetMs + n * beatPeriod(bpm)`.
/// The tap consuming this processes source audio in item time (before AVPlayer's
/// rate/time-pitch stage), so media time is what its frames are measured in and
/// playback speed never affects click placement.
///
/// Immutable by design: the config value is handed across threads as a whole
/// (see `ClickTrackTapContext`) — an exact mirror of the Kotlin
/// `ClickTrackConfig` in audioplayers_android_exo.
struct ClickTrackConfig: Equatable {
  let enabled: Bool
  /// Original BPM of the song (grid tempo), NOT the sped-up value.
  let bpm: Int
  /// Song-time ms of a known beat (tap-to-align anchor); nil = grid from 0.
  let anchorMs: Int64?
  /// Additional grid shift in song-time ms (user nudge).
  let offsetMs: Int64
  let beatsPerBar: Int
  /// 1 = quarters only, 2 = eighths, 3 = triplets, 4 = sixteenths.
  let pulsesPerBeat: Int
  /// Click gain 0.0..1.0 relative to the song.
  let volume: Float
}
