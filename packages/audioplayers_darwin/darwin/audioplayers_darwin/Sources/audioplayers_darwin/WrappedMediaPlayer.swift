// References Flutter-dependent plugin types (AudioplayersDarwinPlugin,
// AudioPlayersStreamHandler); guarded so `swift test` can build the pure-DSP
// click-track sources on a bare Mac. Real app builds always satisfy this.
#if canImport(Flutter) || canImport(FlutterMacOS)

import AVKit

private let defaultPlaybackRate: Double = 1.0

private let defaultPitchMultiplier: Double = 1.0

private let defaultVolume: Double = 1.0

private let defaultReleaseMode: ReleaseMode = ReleaseMode.release

typealias Completer = () -> Void

typealias CompleterError = (Error?) -> Void

enum ReleaseMode: String {
  case stop
  case release
  case loop
}

@MainActor class WrappedMediaPlayer {
  private(set) var eventHandler: AudioPlayersStreamHandler
  private(set) var isPlaying: Bool
  var releaseMode: ReleaseMode

  private var reference: AudioplayersDarwinPlugin
  private var player: AVPlayer
  private var playbackRate: Double
  private var volume: Double
  private var url: String?

  private var completionObserver: TimeObserver?
  private var playerItemStatusObservation: NSKeyValueObservation?

  /// Click-track tap state for the current player item (nil when the item
  /// has no tap, e.g. no audio track or tap creation failed).
  private var clickTapContext: ClickTrackTapContext?

  /// Metronome click configuration. Stored always (survives source swaps —
  /// each new item's tap is seeded with it) and pushed to the live tap
  /// immediately; mirrors the Android WrappedPlayer.clickTrack semantics.
  var clickTrack: ClickTrackConfig? {
    didSet {
      guard clickTrack != oldValue else {
        return
      }
      clickTapContext?.setConfig(clickTrack)
    }
  }

  /// Independent pitch shift as a frequency multiplier (1.0 = unchanged,
  /// 2.0 = +1 octave). Stored always (survives source swaps — each new item's
  /// tap is seeded with it) and pushed to the live tap immediately; mirrors the
  /// Android WrappedPlayer.pitchShift semantics.
  var pitchMultiplier: Double = defaultPitchMultiplier {
    didSet {
      guard pitchMultiplier != oldValue else {
        return
      }
      clickTapContext?.setPitch(pitchMultiplier)
    }
  }

  /// Native loop region in media-time ms. While set, a loop-end boundary
  /// observer wraps the playhead from `endMs` back to `startMs` in-process —
  /// no Dart timer and no `seek` platform-channel round trip — and reports each
  /// wrap through `onLoopWrap`. Mirrors the Android ExoPlayer path
  /// (`ExoPlayerWrapper.setLoopRegion`). The win over the Dart fallback is
  /// purely *when* the wrap fires: here it fires as the boundary is traversed,
  /// so the playhead no longer sails past the loop end (audible) while a Timer
  /// fire + channel hop delivers the seek. The AVPlayer seek itself is
  /// unchanged, so this is not sample-accurate gapless — it removes the
  /// overshoot, not every seek artefact.
  private var loopRegion: (startMs: Int, endMs: Int)?

  /// Opaque token for the live loop-end boundary observer, or nil when no
  /// region is armed / no item is loaded. Removed via `removeTimeObserver`.
  private var loopBoundaryObserver: Any?

  init(
    reference: AudioplayersDarwinPlugin,
    eventHandler: AudioPlayersStreamHandler,
    player: AVPlayer = AVPlayer.init(),
    playbackRate: Double = defaultPlaybackRate,
    volume: Double = defaultVolume,
    releaseMode: ReleaseMode = defaultReleaseMode,
    url: String? = nil
  ) {
    self.reference = reference
    self.eventHandler = eventHandler
    self.player = player
    self.completionObserver = nil
    self.playerItemStatusObservation = nil

    self.isPlaying = false
    self.playbackRate = playbackRate
    self.volume = volume
    self.releaseMode = releaseMode
    self.url = url
  }

  func setSourceUrl(
    url: String,
    isLocal: Bool,
    mimeType: String? = nil
  ) async throws {
    let playbackStatus = player.currentItem?.status

    if self.url != url || playbackStatus == .failed || playbackStatus == nil {
      reset()
      self.url = url
      let playerItem = try createPlayerItem(url: url, isLocal: isLocal, mimeType: mimeType)
      // Need to observe item status immediately after creating:
      try await setUpPlayerItemStatusObservation(playerItem)
      // The item is ready and not yet playing — the only safe moment to
      // attach the click-track tap (mutating audioMix on a live item is a
      // known crash source).
      await attachClickTrackTap(to: playerItem)
      // Needs to be called after the preparation has completed.
      self.updateDuration()

      self.setUpSoundCompletedObserver(self.player, playerItem)
      self.eventHandler.onPrepared(isPrepared: true)
    } else {
      if playbackStatus == .readyToPlay {
        self.eventHandler.onPrepared(isPrepared: true)
      }
    }
  }

  func getDuration() -> Int? {
    guard let duration = getDurationCMTime() else {
      return nil
    }
    return fromCMTime(time: duration)
  }

  func getCurrentPosition() -> Int? {
    guard let time = getCurrentCMTime() else {
      return nil
    }
    return fromCMTime(time: time)
  }

  func pause() {
    isPlaying = false
    player.pause()
  }

  func resume() {
    isPlaying = true
    configParameters(player: player)
    if #available(iOS 10.0, macOS 10.12, *) {
      player.playImmediately(atRate: Float(playbackRate))
    } else {
      player.play()
    }
    updateDuration()
  }

  func setVolume(volume: Double) {
    self.volume = volume
    player.volume = Float(volume)
  }

  func setPlaybackRate(playbackRate: Double) {
    self.playbackRate = playbackRate
    if isPlaying {
      // Setting the rate causes the player to resume playing. So setting it only, when already playing.
      player.rate = Float(playbackRate)
    }
  }

  /// Sets an independent pitch shift (frequency multiplier). Applied by the
  /// Signalsmith stretcher inside the click-track tap; time-neutral, so it does
  /// not affect playback rate or position. Matches the Android `setPitchShift`.
  func setPitchShift(pitchShift: Double) {
    self.pitchMultiplier = pitchShift
  }

  /// Sets or clears the native loop region. `enabled == false`, missing bounds,
  /// or `endMs <= startMs` tears the region down; the Dart side then falls back
  /// to its timer-driven wrapping. Bounds are in media-time ms — unlike Android
  /// no rate compensation is needed, because AVPlayer's boundary observer works
  /// in the item's own timeline regardless of `player.rate`.
  func setLoopRegion(enabled: Bool, startMs: Int?, endMs: Int?) {
    guard enabled, let startMs = startMs, let endMs = endMs, endMs > startMs else {
      loopRegion = nil
      refreshLoopBoundaryObserver()
      return
    }
    loopRegion = (startMs: startMs, endMs: endMs)
    refreshLoopBoundaryObserver()
  }

  /// (Re)installs the loop-end boundary observer against the current item.
  /// Always removes the previous observer first, so it is safe to call
  /// repeatedly. A boundary observer fires every time playback traverses the
  /// boundary during normal playback — but not on a seek *over* it, which is
  /// why the Dart watchdog still guards user seeks past the loop end. No re-arm
  /// is needed on a rate change (the observer is in item time, not real time);
  /// a source swap clears it via `reset()` and the app re-arms after loading.
  private func refreshLoopBoundaryObserver() {
    if let observer = loopBoundaryObserver {
      player.removeTimeObserver(observer)
      loopBoundaryObserver = nil
    }
    guard let region = loopRegion, player.currentItem != nil else {
      return
    }
    let endTime = toCMTime(millis: region.endMs)
    loopBoundaryObserver = player.addBoundaryTimeObserver(
      forTimes: [NSValue(time: endTime)],
      queue: .main
    ) { [weak self] in
      Task { @MainActor in
        await self?.onLoopBoundaryReached()
      }
    }
  }

  /// Wrap handler: seek precisely back to the loop start and report an
  /// `onLoopWrap` event — deliberately *not* `onSeekComplete`, matching Android
  /// so the Dart side can tell an engine-driven wrap from a user-initiated
  /// seek (`onLoopWrap` is surfaced as a seek the cubit never initiated).
  private func onLoopBoundaryReached() async {
    guard let region = loopRegion, let currentItem = player.currentItem else {
      return
    }
    // Instrumentation for tuning loop seamlessness. `overshoot` = how far the
    // playhead ran past the loop end before the boundary observer caught it
    // (the old Dart-timer + channel path's main artefact — want this near 0).
    // `seekMs` = wall-clock cost of the precise seek back (the AVPlayer buffer
    // re-prime, the residual that a boundary observer can't remove). Surfaced
    // via onLog → Dart debug log. Remove once the loop feels right on-device.
    let firedAt = Date()
    let overshoot = (getCurrentPosition() ?? region.endMs) - region.endMs
    await currentItem.seek(
      to: toCMTime(millis: region.startMs), toleranceBefore: .zero, toleranceAfter: .zero)
    let seekMs = Int(Date().timeIntervalSince(firedAt) * 1000)
    let landed = getCurrentPosition() ?? region.startMs
    eventHandler.onLog(
      message:
        "loop wrap: overshoot=\(overshoot)ms past end(\(region.endMs)ms), seek=\(seekMs)ms, "
        + "landed=\(landed)ms (target start=\(region.startMs)ms)")
    eventHandler.onLoopWrap(positionMs: region.startMs)
  }

  func seek(time: CMTime) async {
    guard let currentItem = player.currentItem else {
      return
    }
    // AVPlayer's default seek tolerance is unbounded, so a seek may land
    // noticeably before or after the target. Loop wraps and loop-point seeks
    // must land exactly on the requested position, so always seek precisely.
    await currentItem.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    if !self.isPlaying {
      self.player.pause()
    }
    self.eventHandler.onSeekComplete()
  }

  func stop() async {
    pause()
    if releaseMode == ReleaseMode.release {
      await release()
    } else if (getCurrentPosition() ?? 0) != 0 {
      await seek(time: toCMTime(millis: 0))
    }
  }

  func release() async {
    if self.isPlaying {
      pause()
    }
    self.reset()
  }

  func dispose() async {
    await release()
    self.eventHandler.dispose()
  }

  private func getDurationCMTime() -> CMTime? {
    return player.currentItem?.asset.duration
  }

  private func getCurrentCMTime() -> CMTime? {
    return player.currentItem?.currentTime()
  }

  private func createPlayerItem(
    url: String,
    isLocal: Bool,
    mimeType: String? = nil
  ) throws -> AVPlayerItem {
    guard
      let parsedUrl = isLocal
        ? URL(fileURLWithPath: url.deletingPrefix("file://")) : URL(string: url)
    else {
      throw AudioPlayerError.error("Url not valid: \(url)")
    }

    let playerItem: AVPlayerItem

    if let unwrappedMimeType = mimeType {
      if #available(iOS 17, macOS 14.0, *) {
        let asset = AVURLAsset(
          url: parsedUrl, options: [AVURLAssetOverrideMIMETypeKey: unwrappedMimeType])
        playerItem = AVPlayerItem(asset: asset)
      } else {
        let asset = AVURLAsset(
          url: parsedUrl, options: ["AVURLAssetOutOfBandMIMETypeKey": unwrappedMimeType])
        playerItem = AVPlayerItem(asset: asset)
      }
    } else {
      playerItem = AVPlayerItem(url: parsedUrl)
    }

    playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain
    return playerItem
  }

  /// Attaches the metronome click tap to the item via an AVAudioMix, seeded
  /// with the stored `clickTrack` config. On any failure the song still
  /// plays — just without a native click track.
  private func attachClickTrackTap(to playerItem: AVPlayerItem) async {
    let audioTrack: AVAssetTrack?
    if #available(iOS 15, macOS 12, *) {
      audioTrack = try? await playerItem.asset.loadTracks(withMediaType: .audio).first
    } else {
      audioTrack = playerItem.asset.tracks(withMediaType: .audio).first
    }
    guard let audioTrack = audioTrack else {
      eventHandler.onLog(
        message: "ClickTrackTap: no audio track — click track unavailable for this item")
      clickTapContext = nil
      return
    }

    let context = ClickTrackTapContext(config: clickTrack, pitch: pitchMultiplier)
    guard let audioMix = ClickTrackTapFactory.makeAudioMix(track: audioTrack, context: context)
    else {
      eventHandler.onLog(
        message: "ClickTrackTap: tap creation failed — click track unavailable for this item")
      clickTapContext = nil
      return
    }
    playerItem.audioMix = audioMix
    clickTapContext = context
  }

  private func setUpPlayerItemStatusObservation(
    _ playerItem: AVPlayerItem
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      playerItemStatusObservation = playerItem.observe(\AVPlayerItem.status) {
        [weak self] (playerItem, change) in
        guard let self = self else {
          return
        }
        let status = playerItem.status
        self.eventHandler.onLog(message: "player status: \(status), change: \(change)")

        switch status {
        case .readyToPlay:
          continuation.resume()
        case .failed:
          self.reset()
          continuation.resume(throwing: AudioPlayerError.error("Failed to set playerItem"))
        default:
          // Do not resume continuation yet
          break
        }
      }
      // Replacing the player item triggers continuation of the observation.
      self.player.replaceCurrentItem(with: playerItem)
    }

    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
  }

  private func setUpSoundCompletedObserver(_ player: AVPlayer, _ playerItem: AVPlayerItem) {
    let observer = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: nil
    ) {
      (notification) in
      Task { @MainActor [weak self] in
        guard let self = self else {
          return
        }
        await self.onSoundComplete()
      }
    }
    self.completionObserver = TimeObserver(player: player, observer: observer)
  }

  private func configParameters(player: AVPlayer) {
    if isPlaying {
      player.volume = Float(volume)
      player.rate = Float(playbackRate)
    }
  }

  private func reset() {
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
    if let cObserver = completionObserver {
      NotificationCenter.default.removeObserver(cObserver.observer)
      completionObserver = nil
    }
    // Drop the loop-end observer with the outgoing item and clear the region:
    // a new item has an unrelated timeline, so the app re-arms loop mode (via
    // `setLoopRegion`) after loading. Until it does, the Dart fallback wraps —
    // safe — whereas keeping a stale region would seek to the wrong start.
    if let observer = loopBoundaryObserver {
      player.removeTimeObserver(observer)
      loopBoundaryObserver = nil
    }
    loopRegion = nil
    // Drop our tap reference only — never mutate audioMix on a live item.
    // The tap itself (and the retained context) is torn down by the item's
    // deallocation via the finalize callback.
    clickTapContext = nil
    player.replaceCurrentItem(with: nil)
    self.url = nil
  }

  private func updateDuration() {
    guard let duration = player.currentItem?.asset.duration else {
      return
    }
    if CMTimeGetSeconds(duration) > 0 {
      let millis = fromCMTime(time: duration)
      eventHandler.onDuration(millis: millis)
    }
  }

  private func onSoundComplete() async {
    if !isPlaying {
      return
    }

    reference.controlAudioSession()
    eventHandler.onComplete()

    await seek(time: toCMTime(millis: 0))
    if self.releaseMode == ReleaseMode.loop {
      self.resume()
    } else if self.releaseMode == ReleaseMode.release {
      await self.release()
    } else {
      self.isPlaying = false
    }
  }
}

#endif  // canImport(Flutter) || canImport(FlutterMacOS)
