import AVFoundation
import Foundation
import MediaToolbox
import os.log

// The Objective-C++ pitch bridge is a separate module under SwiftPM (`swift
// test`) but folds into the one plugin module under CocoaPods (the real app
// build), where it is visible via the umbrella header without an import.
#if canImport(SignalsmithBridge)
  import SignalsmithBridge
#endif

/// Shared state between the platform thread (config writer) and the
/// MTAudioProcessingTap's real-time audio thread (reader + pitch DSP + mixer).
///
/// This context does two jobs in the one tap: it runs the independent
/// pitch-shift (Signalsmith Stretch, matching Android) over the source audio,
/// and then mixes the metronome click on top of the *pitched* output so clicks
/// are never themselves pitch-shifted.
///
/// Threading model:
/// - `setConfig`/`setPitch` (main thread) take the lock unconditionally — it is
///   never held long, so blocking there is fine.
/// - The audio thread only ever `trylock`s. If the lock is contended it
///   keeps using the previously adopted config/pitch for one more buffer
///   (~23 ms) instead of blocking — the real-time callback must never wait.
/// - Format fields (`sampleRate`, `channelCount`, ...) and the pitch processor
///   are written in the tap's `prepare` callback and read in `process`;
///   MediaToolbox sequences prepare → process → unprepare, so no extra
///   synchronization is needed.
final class ClickTrackTapContext {
  // MARK: cross-thread handoff (lock-guarded)

  private let lockPtr: UnsafeMutablePointer<os_unfair_lock>
  private var pendingConfig: ClickTrackConfig?
  private var pendingGeneration: UInt64 = 0
  private var pendingPitch: Double = 1.0
  private var pendingPitchGeneration: UInt64 = 0

  // MARK: audio-thread-confined state

  fileprivate var sampleRate: Double = 0
  fileprivate var channelCount: Int = 0
  fileprivate var isNonInterleaved = false
  fileprivate var isFloat32 = false
  private var adoptedConfig: ClickTrackConfig?
  private var adoptedGeneration: UInt64 = 0
  private var grid: ClickGrid?
  /// Position fallback for callbacks whose timeRange is invalid (transient
  /// during priming/flush); re-synced from the timeRange on every valid one.
  private var fallbackPositionFrames: Int64 = 0

  // MARK: pitch (audio-thread-confined, seeded in prepare)

  /// Frequency multiplier last adopted by the audio thread (1.0 = bypass).
  private var adoptedPitch: Double = 1.0
  private var adoptedPitchGeneration: UInt64 = 0
  /// Nil unless the processing format is float32 (the only format we shift).
  /// `SignalsmithProcessor` is always in scope: imported as a module under
  /// SwiftPM, in-module via the umbrella header under CocoaPods.
  private var pitchProcessor: SignalsmithProcessor?
  /// Constant group delay the stretcher adds; the click grid is shifted back
  /// by this many source frames while pitch is active so beats stay aligned.
  private var pitchLatencyFrames: Int64 = 0
  /// Whether pitch ran on the previous buffer, so we can flush-and-re-prime on
  /// each (re)activation (bypass → active) for a clean start.
  private var pitchWasActive = false
  /// Largest block the callback may hand us, from the prepare ASBD phase.
  private var maxFrames: Int = 0
  /// Preallocated planar channel-pointer scratch (non-interleaved path).
  private var channelPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
  /// Expected next source-start (frames) for seek/loop-wrap detection; -1 until
  /// the first buffer of an item.
  private var expectedNextSourceStart: Int64 = -1
  /// Contiguity slack (frames) absorbing timescale-conversion rounding; any
  /// larger jump is treated as a seek and flushes the stretcher.
  private let seekToleranceFrames: Int64 = 64

  init(config: ClickTrackConfig?, pitch: Double = 1.0) {
    lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    lockPtr.initialize(to: os_unfair_lock())
    if config != nil {
      pendingConfig = config
      pendingGeneration = 1
    }
    if pitch != 1.0 {
      pendingPitch = pitch
      pendingPitchGeneration = 1
    }
  }

  deinit {
    channelPtrs?.deallocate()
    lockPtr.deinitialize(count: 1)
    lockPtr.deallocate()
  }

  /// Swaps the click configuration (nil or disabled = silent). Instant: the
  /// audio thread picks it up within one buffer, no flush involved.
  func setConfig(_ config: ClickTrackConfig?) {
    os_unfair_lock_lock(lockPtr)
    pendingConfig = config
    pendingGeneration &+= 1
    os_unfair_lock_unlock(lockPtr)
  }

  /// Sets the pitch frequency multiplier (1.0 = unchanged). Live changes are
  /// smooth (no flush); the audio thread adopts it within one buffer.
  func setPitch(_ multiplier: Double) {
    os_unfair_lock_lock(lockPtr)
    pendingPitch = multiplier
    pendingPitchGeneration &+= 1
    os_unfair_lock_unlock(lockPtr)
  }

  // MARK: tap-callback entry points (audio/internal threads)

  fileprivate func handlePrepare(asbd: AudioStreamBasicDescription, maxFrames: Int) {
    sampleRate = asbd.mSampleRate
    channelCount = Int(asbd.mChannelsPerFrame)
    isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM
      && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
      && asbd.mBitsPerChannel == 32
    self.maxFrames = maxFrames
    // Sample rate may differ from the previous item — rebuild lazily.
    grid = nil
    fallbackPositionFrames = 0
    expectedNextSourceStart = -1
    pitchWasActive = false

    // Rebuild the pitch processor for this item's format. Tear down the old
    // one first (channel count / sample rate may have changed).
    pitchProcessor = nil
    channelPtrs?.deallocate()
    channelPtrs = nil
    if isFloat32, sampleRate > 0, channelCount > 0, maxFrames > 0 {
      let proc = SignalsmithProcessor(
        sampleRate: sampleRate,
        channels: Int32(channelCount),
        maxFrames: Int32(maxFrames)
      )
      proc.setPitchMultiplier(adoptedPitch)
      pitchProcessor = proc
      pitchLatencyFrames = Int64(proc.latencyFrames)
      channelPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(
        capacity: channelCount)
    } else {
      pitchLatencyFrames = 0
    }

    if !isFloat32 {
      // Never assume the processing format: unexpected formats pass audio
      // through untouched (no pitch, no clicks) instead of corrupting it.
      os_log(
        "ClickTrackTap: unsupported processing format (id %{public}u, flags %{public}u, bits %{public}u) — pitch and click track disabled for this item",
        type: .error,
        asbd.mFormatID, asbd.mFormatFlags, asbd.mBitsPerChannel
      )
    }
  }

  fileprivate func handleUnprepare() {
    sampleRate = 0
    channelCount = 0
    isFloat32 = false
    grid = nil
    pitchProcessor = nil
    channelPtrs?.deallocate()
    channelPtrs = nil
    pitchWasActive = false
    expectedNextSourceStart = -1
  }

  /// Mixes clicks into `bufferList` (already filled with source audio).
  /// Real-time-safe: no locks beyond a trylock, no allocation except a
  /// small `ClickGrid` rebuild on config change (accepted, happens only
  /// when the user changes settings, not per buffer).
  fileprivate func processBuffer(
    _ bufferList: UnsafeMutablePointer<AudioBufferList>,
    frames: Int64,
    timeRange: CMTimeRange
  ) {
    adoptPendingConfigIfPossible()

    let sourceStart: Int64
    if sampleRate > 0 && timeRange.start.isNumeric {
      // Authoritative item-time position — seeks, loop wraps and source
      // swaps re-anchor the grid for free, unlike the Android processor's
      // pending-anchor machinery.
      sourceStart = CMTimeConvertScale(
        timeRange.start,
        timescale: Int32(sampleRate),
        method: .roundHalfAwayFromZero
      ).value
    } else {
      sourceStart = fallbackPositionFrames
    }
    fallbackPositionFrames = sourceStart + frames

    // Seek / loop-wrap detection. A non-contiguous jump means the stretcher
    // still holds pre-jump audio, which would bleed ~150 ms across the seek —
    // flush it. (No-op on the first buffer, expectedNextSourceStart == -1.)
    let contiguous = expectedNextSourceStart >= 0
      && abs(sourceStart - expectedNextSourceStart) <= seekToleranceFrames
    if !contiguous {
      pitchProcessor?.reset()
      pitchWasActive = false
    }
    expectedNextSourceStart = sourceStart + frames

    // Independent pitch shift, in place, BEFORE the click mix so clicks are
    // never pitched. Bypassed at unity to keep zero added latency.
    var clickStart = sourceStart
    let pitchActive = isFloat32 && adoptedPitch != 1.0 && frames <= Int64(maxFrames)
    if pitchActive, let proc = pitchProcessor {
      if !pitchWasActive {
        // Clean re-prime on (re)activation so no stale tail leaks in.
        proc.reset()
      }
      applyPitch(proc, to: bufferList, frames: Int(frames))
      // The pitched stream lags the source by the stretcher's group delay, so
      // anchor the click grid the same amount back to keep beats aligned.
      clickStart = sourceStart - pitchLatencyFrames
    }
    pitchWasActive = pitchActive

    guard isFloat32,
          sampleRate > 0,
          let cfg = adoptedConfig,
          cfg.enabled,
          cfg.bpm > 0,
          cfg.volume > 0,
          let grid = grid
    else {
      return  // Passthrough: (possibly pitched) source audio is in the buffers.
    }

    let endFrame = clickStart + frames
    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    let clickFrames = Int64(grid.clickFrames)

    grid.forEachPulseOverlapping(clickStart, endFrame) { pulseStart, freqHz, gain in
      let i0 = max(0, clickStart - pulseStart)
      let i1 = min(clickFrames, endFrame - pulseStart)
      var i = i0
      while i < i1 {
        let value = ClickSynth.sampleFloat(
          i: i,
          clickFrames: grid.clickFrames,
          freqHz: freqHz,
          gain: gain,
          volume: cfg.volume,
          sampleRate: Int(sampleRate)
        )
        if value != 0 {
          let frameIndex = Int(pulseStart + i - clickStart)
          if isNonInterleaved {
            // One buffer per channel.
            for buffer in abl {
              guard let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                    frameIndex < Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
              else { continue }
              data[frameIndex] = min(1.0, max(-1.0, data[frameIndex] + value))
            }
          } else if let buffer = abl.first,
                    let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
            // Single interleaved buffer.
            let channels = max(1, Int(buffer.mNumberChannels))
            let base = frameIndex * channels
            guard base + channels <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            else {
              i += 1
              continue
            }
            for ch in 0..<channels {
              data[base + ch] = min(1.0, max(-1.0, data[base + ch] + value))
            }
          }
        }
        i += 1
      }
    }
  }

  private func adoptPendingConfigIfPossible() {
    if os_unfair_lock_trylock(lockPtr) {
      let generation = pendingGeneration
      let config = pendingConfig
      let pitchGeneration = pendingPitchGeneration
      let pitch = pendingPitch
      os_unfair_lock_unlock(lockPtr)
      if generation != adoptedGeneration {
        adoptedGeneration = generation
        adoptedConfig = config
        grid = nil
      }
      if pitchGeneration != adoptedPitchGeneration {
        adoptedPitchGeneration = pitchGeneration
        adoptedPitch = pitch
        // Live transpose change — cheap, no flush (smooth while dragging).
        pitchProcessor?.setPitchMultiplier(pitch)
      }
    }
    // Rebuild after a config change or a prepare (sample rate change).
    if grid == nil, sampleRate > 0, let cfg = adoptedConfig, cfg.enabled, cfg.bpm > 0 {
      grid = ClickGrid(config: cfg, sampleRate: Int(sampleRate))
    }
  }

  /// Runs the stretcher in place over the tap's float32 buffers. Real-time
  /// safe: the processor preallocated its scratch, and the planar path reuses
  /// the preallocated `channelPtrs`.
  private func applyPitch(
    _ proc: SignalsmithProcessor,
    to bufferList: UnsafeMutablePointer<AudioBufferList>,
    frames: Int
  ) {
    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    if isNonInterleaved {
      guard let ptrs = channelPtrs else { return }
      var n = 0
      for buffer in abl {
        guard n < channelCount,
              let data = buffer.mData?.assumingMemoryBound(to: Float.self)
        else { break }
        ptrs[n] = data
        n += 1
      }
      guard n == channelCount else { return }
      proc.processPlanar(ptrs, frames: Int32(frames))
    } else if let buffer = abl.first,
              let data = buffer.mData?.assumingMemoryBound(to: Float.self),
              Int(buffer.mNumberChannels) == channelCount {
      // Single interleaved buffer with the configured channel count.
      proc.processInterleaved(data, frames: Int32(frames))
    }
  }
}

/// Builds the AVAudioMix that carries the click-track tap for one player
/// item. The tap holds the only strong native reference to the context's
/// retained pointer; it is released exactly once, in the finalize callback,
/// when the item (and with it the mix and tap) is deallocated.
enum ClickTrackTapFactory {
  static func makeAudioMix(
    track: AVAssetTrack,
    context: ClickTrackTapContext
  ) -> AVAudioMix? {
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
      init: clickTapInit,
      finalize: clickTapFinalize,
      prepare: clickTapPrepare,
      unprepare: clickTapUnprepare,
      process: clickTapProcess
    )
    // Swift's audited import returns the tap at +1 with ownership managed
    // automatically (no Unmanaged dance needed for the tap itself).
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault,
      &callbacks,
      kMTAudioProcessingTapCreationFlag_PreEffects,
      &tap
    )
    guard status == noErr, let tap = tap else {
      // Creation failed — balance the passRetained above immediately.
      Unmanaged<ClickTrackTapContext>.fromOpaque(callbacks.clientInfo!).release()
      return nil
    }

    let inputParameters = AVMutableAudioMixInputParameters(track: track)
    inputParameters.audioTapProcessor = tap
    let audioMix = AVMutableAudioMix()
    audioMix.inputParameters = [inputParameters]
    return audioMix
  }
}

// MARK: - C-convention tap callbacks (no captures allowed)

private func clickTapInit(
  tap: MTAudioProcessingTap,
  clientInfo: UnsafeMutableRawPointer?,
  tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
  tapStorageOut.pointee = clientInfo
}

private func clickTapFinalize(tap: MTAudioProcessingTap) {
  // The single release balancing the factory's passRetained.
  Unmanaged<ClickTrackTapContext>
    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
    .release()
}

private func clickTapPrepare(
  tap: MTAudioProcessingTap,
  maxFrames: CMItemCount,
  processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
  let context = Unmanaged<ClickTrackTapContext>
    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
    .takeUnretainedValue()
  context.handlePrepare(asbd: processingFormat.pointee, maxFrames: Int(maxFrames))
}

private func clickTapUnprepare(tap: MTAudioProcessingTap) {
  let context = Unmanaged<ClickTrackTapContext>
    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
    .takeUnretainedValue()
  context.handleUnprepare()
}

private func clickTapProcess(
  tap: MTAudioProcessingTap,
  numberFrames: CMItemCount,
  flags: MTAudioProcessingTapFlags,
  bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
  numberFramesOut: UnsafeMutablePointer<CMItemCount>,
  flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
  // Always pull the source audio through, even when the click is disabled —
  // the music must keep flowing.
  var timeRange = CMTimeRange()
  let status = MTAudioProcessingTapGetSourceAudio(
    tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut
  )
  let frames = Int64(numberFramesOut.pointee)
  guard status == noErr, frames > 0 else { return }

  let context = Unmanaged<ClickTrackTapContext>
    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
    .takeUnretainedValue()
  context.processBuffer(bufferListInOut, frames: frames, timeRange: timeRange)
}
