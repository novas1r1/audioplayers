import XCTest

@testable import audioplayers_darwin

/// 1:1 port of the Kotlin ClickSynthTest
/// (ap/packages/audioplayers_android_exo/.../ClickSynthTest.kt) — the Swift
/// synth must produce identical samples to the Android/Dart implementations.
final class ClickSynthTests: XCTestCase {

  private let sampleRate = 44100
  private var clickFrames: Int {
    Int(ClickSynth.maxClickMs * Double(sampleRate) / 1000.0)
  }

  private func peak(freqHz: Double, gain: Double, volume: Float = 1.0) -> Double {
    var maxValue = 0.0
    for i in 0..<clickFrames {
      let v = abs(
        ClickSynth.sample(
          i: Int64(i),
          clickFrames: clickFrames,
          freqHz: freqHz,
          gain: gain,
          volume: volume,
          sampleRate: sampleRate
        )
      )
      if v > maxValue {
        maxValue = v
      }
    }
    return maxValue
  }

  func testReturnsZeroOutsideTheClickWindow() {
    XCTAssertEqual(
      ClickSynth.sample(
        i: -1, clickFrames: clickFrames, freqHz: ClickSynth.beatFreqHz,
        gain: 1.0, volume: 1.0, sampleRate: sampleRate),
      0.0
    )
    XCTAssertEqual(
      ClickSynth.sample(
        i: Int64(clickFrames), clickFrames: clickFrames, freqHz: ClickSynth.beatFreqHz,
        gain: 1.0, volume: 1.0, sampleRate: sampleRate),
      0.0
    )
  }

  func testStartsSilentAndNeverExceedsTheHeadroomPeak() {
    XCTAssertEqual(
      ClickSynth.sample(
        i: 0, clickFrames: clickFrames, freqHz: ClickSynth.accentFreqHz,
        gain: 1.0, volume: 1.0, sampleRate: sampleRate),
      0.0
    )
    XCTAssertLessThanOrEqual(
      peak(freqHz: ClickSynth.accentFreqHz, gain: ClickSynth.accentGain),
      ClickSynth.peak
    )
  }

  func testAccentIsLouderThanBeatWhichIsLouderThanSubdivision() {
    let accent = peak(freqHz: ClickSynth.accentFreqHz, gain: ClickSynth.accentGain)
    let beat = peak(freqHz: ClickSynth.beatFreqHz, gain: ClickSynth.beatGain)
    let sub = peak(freqHz: ClickSynth.subdivisionFreqHz, gain: ClickSynth.subdivisionGain)

    XCTAssertGreaterThan(accent, beat)
    XCTAssertGreaterThan(beat, sub)
  }

  func testVolumeScalesTheClickLinearly() {
    let full = peak(freqHz: ClickSynth.beatFreqHz, gain: ClickSynth.beatGain, volume: 1.0)
    let half = peak(freqHz: ClickSynth.beatFreqHz, gain: ClickSynth.beatGain, volume: 0.5)

    XCTAssertEqual(half, full / 2, accuracy: 1.0)
  }

  func testEnvelopeDecaysTowardsTheClickEnd() {
    let early = abs(
      ClickSynth.sample(
        i: Int64(sampleRate / 1000 + 30),  // just past the attack, near a sine peak
        clickFrames: clickFrames, freqHz: ClickSynth.beatFreqHz,
        gain: 1.0, volume: 1.0, sampleRate: sampleRate)
    )
    var lateMax = 0.0
    for i in (clickFrames - 100)..<clickFrames {
      let v = abs(
        ClickSynth.sample(
          i: Int64(i), clickFrames: clickFrames, freqHz: ClickSynth.beatFreqHz,
          gain: 1.0, volume: 1.0, sampleRate: sampleRate)
      )
      if v > lateMax {
        lateMax = v
      }
    }
    XCTAssertLessThan(lateMax, early)
  }

  /// Cross-check against the shared formula also implemented by the Kotlin
  /// ClickSynth: both must compute
  /// `0.85*32767 * gain * attack * exp(-i/tau) * sin(2*pi*f*i/sr)`.
  func testMatchesTheSharedSynthesisFormulaAtProbePoints() {
    let i: Int64 = 200
    let tau = Double(clickFrames) / 5.0
    let expected =
      ClickSynth.peak * ClickSynth.beatGain
      * exp(-Double(i) / tau)
      * sin(2 * Double.pi * ClickSynth.beatFreqHz * Double(i) / Double(sampleRate))

    let actual = ClickSynth.sample(
      i: i, clickFrames: clickFrames, freqHz: ClickSynth.beatFreqHz,
      gain: ClickSynth.beatGain, volume: 1.0, sampleRate: sampleRate)

    XCTAssertEqual(actual, expected, accuracy: 1e-6)
  }

  func testSampleFloatIsTheInt16DomainSampleNormalized() {
    let i: Int64 = 300
    let raw = ClickSynth.sample(
      i: i, clickFrames: clickFrames, freqHz: ClickSynth.accentFreqHz,
      gain: ClickSynth.accentGain, volume: 0.8, sampleRate: sampleRate)
    let normalized = ClickSynth.sampleFloat(
      i: i, clickFrames: clickFrames, freqHz: ClickSynth.accentFreqHz,
      gain: ClickSynth.accentGain, volume: 0.8, sampleRate: sampleRate)

    XCTAssertEqual(Double(normalized), raw / 32768.0, accuracy: 1e-6)
  }
}
