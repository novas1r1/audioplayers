import Foundation

/// Metronome click synthesis: a short sine burst with a 1 ms linear attack
/// and an exponential decay. Soft transients survive time-stretching at
/// extreme slowdowns much better than sharp ticks.
///
/// Constants are an exact mirror of the Kotlin `ClickSynth`
/// (ap/packages/audioplayers_android_exo/.../player/ClickSynth.kt) and the
/// Dart `ClickTrackRenderer` — keep all in sync so the native metronomes
/// sound identical across platforms.
enum ClickSynth {
  static let accentFreqHz = 1600.0
  static let beatFreqHz = 1050.0
  static let subdivisionFreqHz = 800.0

  static let accentGain = 1.0
  static let beatGain = 0.8
  static let subdivisionGain = 0.45

  /// Nominal click length; ClickGrid shortens it for packed pulses.
  static let maxClickMs = 45.0

  /// Peak amplitude leaves ~1.3 dB headroom before the saturating mix.
  /// Kept in the 16-bit domain to match the Kotlin/Dart formula exactly;
  /// `sampleFloat` normalizes for Float32 mixing.
  static let peak = 0.85 * 32767

  /// The click's sample value (16-bit domain) at frame `i` (0-based within
  /// the click) for a click of `clickFrames` length. Returns 0 outside the
  /// click.
  static func sample(
    i: Int64,
    clickFrames: Int,
    freqHz: Double,
    gain: Double,
    volume: Float,
    sampleRate: Int
  ) -> Double {
    if i < 0 || i >= Int64(clickFrames) {
      return 0.0
    }

    let attackFrames = sampleRate / 1000  // 1 ms linear attack avoids a DC pop
    let attack: Double
    if attackFrames > 0 && i < Int64(attackFrames) {
      attack = Double(i) / Double(attackFrames)
    } else {
      attack = 1.0
    }
    let tau = Double(clickFrames) / 5.0
    let envelope = attack * exp(-Double(i) / tau)
    return peak * gain * Double(volume) * envelope
      * sin(2 * Double.pi * freqHz * Double(i) / Double(sampleRate))
  }

  /// `sample(...)` normalized to the Float32 [-1, 1] domain the tap mixes
  /// in — level-equivalent to Android's int16 mix.
  static func sampleFloat(
    i: Int64,
    clickFrames: Int,
    freqHz: Double,
    gain: Double,
    volume: Float,
    sampleRate: Int
  ) -> Float {
    return Float(
      sample(
        i: i,
        clickFrames: clickFrames,
        freqHz: freqHz,
        gain: gain,
        volume: volume,
        sampleRate: sampleRate
      ) / 32768.0
    )
  }
}
