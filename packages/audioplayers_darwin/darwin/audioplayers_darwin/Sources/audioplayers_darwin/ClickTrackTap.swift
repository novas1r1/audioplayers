import AVFoundation
import Foundation
import MediaToolbox
import os.log

/// Shared state between the platform thread (config writer) and the
/// MTAudioProcessingTap's real-time audio thread (config reader + mixer).
///
/// Threading model:
/// - `setConfig` (main thread) takes the lock unconditionally — it is never
///   held long, so blocking there is fine.
/// - The audio thread only ever `trylock`s. If the lock is contended it
///   keeps using the previously adopted config for one more buffer (~23 ms)
///   instead of blocking — the real-time callback must never wait.
/// - Format fields (`sampleRate`, `channelCount`, ...) are written in the
///   tap's `prepare` callback and read in `process`; MediaToolbox sequences
///   prepare → process → unprepare, so no extra synchronization is needed.
final class ClickTrackTapContext {
  // MARK: cross-thread handoff (lock-guarded)

  private let lockPtr: UnsafeMutablePointer<os_unfair_lock>
  private var pendingConfig: ClickTrackConfig?
  private var pendingGeneration: UInt64 = 0

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

  init(config: ClickTrackConfig?) {
    lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    lockPtr.initialize(to: os_unfair_lock())
    if config != nil {
      pendingConfig = config
      pendingGeneration = 1
    }
  }

  deinit {
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

  // MARK: tap-callback entry points (audio/internal threads)

  fileprivate func handlePrepare(asbd: AudioStreamBasicDescription) {
    sampleRate = asbd.mSampleRate
    channelCount = Int(asbd.mChannelsPerFrame)
    isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM
      && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
      && asbd.mBitsPerChannel == 32
    // Sample rate may differ from the previous item — rebuild lazily.
    grid = nil
    fallbackPositionFrames = 0
    if !isFloat32 {
      // Never assume the processing format: unexpected formats pass audio
      // through untouched (no clicks) instead of corrupting it.
      os_log(
        "ClickTrackTap: unsupported processing format (id %{public}u, flags %{public}u, bits %{public}u) — click track disabled for this item",
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

    let startFrame: Int64
    if sampleRate > 0 && timeRange.start.isNumeric {
      // Authoritative item-time position — seeks, loop wraps and source
      // swaps re-anchor the grid for free, unlike the Android processor's
      // pending-anchor machinery.
      startFrame = CMTimeConvertScale(
        timeRange.start,
        timescale: Int32(sampleRate),
        method: .roundHalfAwayFromZero
      ).value
    } else {
      startFrame = fallbackPositionFrames
    }
    fallbackPositionFrames = startFrame + frames

    guard isFloat32,
          sampleRate > 0,
          let cfg = adoptedConfig,
          cfg.enabled,
          cfg.bpm > 0,
          cfg.volume > 0,
          let grid = grid
    else {
      return  // Passthrough: source audio is already in the buffers.
    }

    let endFrame = startFrame + frames
    let abl = UnsafeMutableAudioBufferListPointer(bufferList)
    let clickFrames = Int64(grid.clickFrames)

    grid.forEachPulseOverlapping(startFrame, endFrame) { pulseStart, freqHz, gain in
      let i0 = max(0, startFrame - pulseStart)
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
          let frameIndex = Int(pulseStart + i - startFrame)
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
      os_unfair_lock_unlock(lockPtr)
      if generation != adoptedGeneration {
        adoptedGeneration = generation
        adoptedConfig = config
        grid = nil
      }
    }
    // Rebuild after a config change or a prepare (sample rate change).
    if grid == nil, sampleRate > 0, let cfg = adoptedConfig, cfg.enabled, cfg.bpm > 0 {
      grid = ClickGrid(config: cfg, sampleRate: Int(sampleRate))
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
  context.handlePrepare(asbd: processingFormat.pointee)
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
