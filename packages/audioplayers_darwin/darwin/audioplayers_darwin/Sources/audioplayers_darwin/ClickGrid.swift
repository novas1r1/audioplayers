import Foundation

/// Pure beat-grid math in media-time frames — no AVFoundation dependency,
/// unit tested via `swift test`.
///
/// All pulses (beats and subdivisions) form one uniform grid with spacing
/// `beatPeriod / pulsesPerBeat`, anchored at `anchorMs + offsetMs`. Pulse
/// index m is: accent when `m % (pulsesPerBeat * beatsPerBar) == 0`, beat
/// when `m % pulsesPerBeat == 0`, subdivision otherwise — the exact grid the
/// Kotlin `ClickGrid` and Dart `ClickTrackRenderer` implement, so all
/// platforms' clicks sound identical.
final class ClickGrid {
  private let pulsesPerBeat: Int
  private let beatsPerBar: Int
  private let accentModulo: Int64

  /// Grid origin in frames (can be negative for negative offsets).
  private let baseFrame: Double

  private let beatPeriodFrames: Double
  private let pulseGapFrames: Double

  /// Click length, shortened so tightly packed pulses never overlap.
  let clickFrames: Int

  init(config: ClickTrackConfig, sampleRate: Int) {
    let pulsesPerBeat = min(max(config.pulsesPerBeat, 1), 8)
    let beatsPerBar = max(config.beatsPerBar, 1)
    self.pulsesPerBeat = pulsesPerBeat
    self.beatsPerBar = beatsPerBar
    self.accentModulo = Int64(pulsesPerBeat * beatsPerBar)

    self.baseFrame =
      Double((config.anchorMs ?? 0) + config.offsetMs) * Double(sampleRate) / 1000.0

    let beatPeriodFrames = 60.0 * Double(sampleRate) / Double(config.bpm)
    self.beatPeriodFrames = beatPeriodFrames
    let pulseGapFrames = beatPeriodFrames / Double(pulsesPerBeat)
    self.pulseGapFrames = pulseGapFrames

    self.clickFrames = max(
      1,
      Int(
        min(
          ClickSynth.maxClickMs * Double(sampleRate) / 1000.0,
          pulseGapFrames * 0.8
        )
      )
    )
  }

  /// Calls `body` for every pulse whose click audio overlaps the frame range
  /// [startFrame, endFrame) — including clicks that started before the range
  /// (straddling a buffer boundary) and pulses left of the anchor (negative
  /// m: the grid extends over the whole file).
  ///
  /// Allocation-free by design: this runs on the real-time audio thread.
  func forEachPulseOverlapping(
    _ startFrame: Int64,
    _ endFrame: Int64,
    _ body: (_ pulseStartFrame: Int64, _ freqHz: Double, _ gain: Double) -> Void
  ) {
    if endFrame <= startFrame {
      return
    }

    // Smallest m whose click can still reach into the range.
    var m = Int64(
      ceil((Double(startFrame) - Double(clickFrames) - baseFrame) / pulseGapFrames)
    )
    while true {
      let pulseStart = Int64((baseFrame + Double(m) * pulseGapFrames).rounded())
      if pulseStart >= endFrame {
        break
      }
      // Media time starts at frame 0 — clicks fully before it never play.
      if pulseStart + Int64(clickFrames) > 0 && pulseStart + Int64(clickFrames) > startFrame {
        let phase = ((m % accentModulo) + accentModulo) % accentModulo
        if phase == 0 {
          body(pulseStart, ClickSynth.accentFreqHz, ClickSynth.accentGain)
        } else if phase % Int64(pulsesPerBeat) == 0 {
          body(pulseStart, ClickSynth.beatFreqHz, ClickSynth.beatGain)
        } else {
          body(pulseStart, ClickSynth.subdivisionFreqHz, ClickSynth.subdivisionGain)
        }
      }
      m += 1
    }
  }
}
