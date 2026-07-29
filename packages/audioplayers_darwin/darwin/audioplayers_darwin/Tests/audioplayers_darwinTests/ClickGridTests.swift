import XCTest

@testable import audioplayers_darwin

/// 1:1 port of the Kotlin ClickGridTest
/// (ap/packages/audioplayers_android_exo/.../ClickGridTest.kt) — the Swift
/// grid must produce the exact same pulses as the Android one.
final class ClickGridTests: XCTestCase {

  private let sampleRate = 44100

  private struct Pulse {
    let startFrame: Int64
    let freqHz: Double
    let gain: Double
  }

  private func config(
    bpm: Int = 120,
    anchorMs: Int64? = nil,
    offsetMs: Int64 = 0,
    beatsPerBar: Int = 4,
    pulsesPerBeat: Int = 1
  ) -> ClickTrackConfig {
    return ClickTrackConfig(
      enabled: true,
      bpm: bpm,
      anchorMs: anchorMs,
      offsetMs: offsetMs,
      beatsPerBar: beatsPerBar,
      pulsesPerBeat: pulsesPerBeat,
      volume: 1.0
    )
  }

  private func framesOf(_ ms: Int64) -> Int64 {
    return Int64((Double(ms) * Double(sampleRate) / 1000.0).rounded())
  }

  private func pulses(_ grid: ClickGrid, _ start: Int64, _ end: Int64) -> [Pulse] {
    var result: [Pulse] = []
    grid.forEachPulseOverlapping(start, end) { startFrame, freqHz, gain in
      result.append(Pulse(startFrame: startFrame, freqHz: freqHz, gain: gain))
    }
    return result
  }

  func testBeatsLandOnTheGridAt120Bpm() {
    let grid = ClickGrid(config: config(), sampleRate: sampleRate)

    // 120 BPM -> beats every 500 ms -> every 22050 frames.
    let result = pulses(grid, 0, framesOf(2000))

    XCTAssertEqual(result.map { $0.startFrame }, [0, 22050, 44100, 66150])
  }

  func testAnchorAndOffsetShiftTheGrid() {
    let grid = ClickGrid(config: config(anchorMs: 100, offsetMs: 25), sampleRate: sampleRate)

    let result = pulses(grid, 0, framesOf(1200))

    // Grid at 125 + n*500 ms.
    XCTAssertEqual(
      result.map { $0.startFrame },
      [framesOf(125), framesOf(625), framesOf(1125)]
    )
  }

  func testAccentFallsOnTheBarDownbeatIncludingLeftOfTheAnchor() {
    // Anchor at 1000 ms; the grid extends left to 500 and 0 ms with
    // negative pulse indices. In 4/4 the accent lands where m % 4 == 0.
    let grid = ClickGrid(config: config(anchorMs: 1000), sampleRate: sampleRate)

    let result = pulses(grid, 0, framesOf(3200))

    XCTAssertEqual(
      result.map { $0.startFrame },
      [
        framesOf(0), framesOf(500), framesOf(1000), framesOf(1500),
        framesOf(2000), framesOf(2500), framesOf(3000),
      ]
    )
    let accents = result.filter { $0.freqHz == ClickSynth.accentFreqHz }
    // m == 0 at the anchor (1000 ms) and m == 4 at 3000 ms; the previous
    // accent (m == -4 at -1000 ms) is before media start.
    XCTAssertEqual(accents.map { $0.startFrame }, [framesOf(1000), framesOf(3000)])
  }

  func testSubdivisionPulsesSitBetweenBeatsAndAreMarkedAsSuch() {
    let grid = ClickGrid(config: config(pulsesPerBeat: 2), sampleRate: sampleRate)

    let result = pulses(grid, 0, framesOf(1000))

    XCTAssertEqual(
      result.map { $0.startFrame },
      [framesOf(0), framesOf(250), framesOf(500), framesOf(750)]
    )
    XCTAssertEqual(result[1].freqHz, ClickSynth.subdivisionFreqHz)
    XCTAssertEqual(result[1].gain, ClickSynth.subdivisionGain)
    XCTAssertEqual(result[2].freqHz, ClickSynth.beatFreqHz)
  }

  func testClicksStraddlingTheRangeStartAreIncluded() {
    let grid = ClickGrid(config: config(), sampleRate: sampleRate)
    let clickFrames = Int64(grid.clickFrames)

    // Range starts a few frames into the beat-1 click at 22050.
    let result = pulses(grid, 22050 + clickFrames / 2, framesOf(600))

    XCTAssertEqual(result.map { $0.startFrame }, [22050])
  }

  func testClicksFullyBeforeTheRangeOrMediaStartAreExcluded() {
    let grid = ClickGrid(config: config(), sampleRate: sampleRate)
    let clickFrames = Int64(grid.clickFrames)

    // Just past the end of the beat-0 click: only beat 1 remains.
    let result = pulses(grid, clickFrames, framesOf(600))

    XCTAssertEqual(result.map { $0.startFrame }, [22050])
  }

  func testClickLengthShrinksSoPackedPulsesNeverOverlap() {
    // 400 BPM sixteenths: pulse gap = 60/400/4 s = 37.5 ms < 45 ms click.
    let grid = ClickGrid(config: config(bpm: 400, pulsesPerBeat: 4), sampleRate: sampleRate)

    let pulseGapFrames = 60.0 * Double(sampleRate) / 400.0 / 4.0
    XCTAssertLessThanOrEqual(grid.clickFrames, Int(pulseGapFrames * 0.8))
    XCTAssertGreaterThan(grid.clickFrames, 0)
  }

  func testEmptyRangeYieldsNoPulses() {
    let grid = ClickGrid(config: config(), sampleRate: sampleRate)
    XCTAssertTrue(pulses(grid, 500, 500).isEmpty)
    XCTAssertTrue(pulses(grid, 500, 400).isEmpty)
  }

  func testGridMathRespectsANon44100SampleRate() {
    let grid = ClickGrid(config: config(), sampleRate: 48000)

    let result = pulses(grid, 0, 48000)

    // 120 BPM at 48 kHz: beats every 24000 frames.
    XCTAssertEqual(result.map { $0.startFrame }, [0, 24000])
  }
}
