import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers_platform_interface/src/api/audio_context.dart';
import 'package:audioplayers_platform_interface/src/api/audio_event.dart';
import 'package:audioplayers_platform_interface/src/api/player_mode.dart';
import 'package:audioplayers_platform_interface/src/api/release_mode.dart';
import 'package:audioplayers_platform_interface/src/audioplayers_platform.dart';
import 'package:meta/meta.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The interface that implementations of audioplayers must implement.
///
/// Platform implementations should extend this class rather than implement it
/// as `audioplayers` does not consider newly added methods to be breaking
/// changes. Extending this class (using `extends`) ensures that the subclass
/// will get the default implementation, while platform implementations that
/// `implements` this interface will be broken by newly added
/// [AudioplayersPlatformInterface] methods.
abstract class AudioplayersPlatformInterface extends PlatformInterface
    implements
        MethodChannelAudioplayersPlatformInterface,
        EventChannelAudioplayersPlatformInterface {
  AudioplayersPlatformInterface() : super(token: _token);

  static final Object _token = Object();

  /// Default implementation so platform packages that don't support pitch
  /// shifting (web, darwin, windows, linux) keep working without changes.
  @override
  Future<void> setPitchShift(String playerId, double pitchShift) {
    throw UnsupportedError('setPitchShift is not supported on this platform');
  }

  /// Default implementation so platform packages that don't support the
  /// in-pipeline metronome click track keep working without changes.
  @override
  Future<void> setClickTrack(
    String playerId, {
    required bool enabled,
    int? bpm,
    int? anchorMs,
    int offsetMs = 0,
    int beatsPerBar = 4,
    int pulsesPerBeat = 1,
    double volume = 1.0,
  }) {
    throw UnsupportedError('setClickTrack is not supported on this platform');
  }

  /// The default instance of [AudioplayersPlatformInterface] to use.
  ///
  /// Defaults to [AudioplayersPlatform].
  /// Platform-specific plugins should set this with their own platform-specific
  /// class that extends [AudioplayersPlatformInterface] when they register
  /// themselves.
  static AudioplayersPlatformInterface instance = AudioplayersPlatform();
}

abstract class MethodChannelAudioplayersPlatformInterface {
  /// Create a player instance for the given playerId.
  Future<void> create(String playerId);

  /// Dispose the player instance with the given playerId.
  Future<void> dispose(String playerId);

  /// Pauses the audio that is currently playing.
  ///
  /// If you call [resume] later, the audio will resume from the point that it
  /// has been paused.
  Future<void> pause(String playerId);

  /// Stops the audio that is currently playing.
  ///
  /// The position is going to be reset and you will no longer be able to resume
  /// from the last point.
  Future<void> stop(String playerId);

  /// Resumes the audio that has been paused or stopped.
  Future<void> resume(String playerId);

  /// Releases the resources associated with this media player.
  ///
  /// The resources are going to be fetched or buffered again as needed.
  Future<void> release(String playerId);

  /// Moves the cursor to the desired position.
  Future<void> seek(String playerId, Duration position);

  /// Sets the stereo balance.
  ///
  /// -1 - The left channel is at full volume; the right channel is silent.
  ///  1 - The right channel is at full volume; the left channel is silent.
  ///  0 - Both channels are at the same volume.
  Future<void> setBalance(String playerId, double balance);

  /// Sets the volume (amplitude).
  ///
  /// 0 is mute and 1 is the max volume. The values between 0 and 1 are linearly
  /// interpolated.
  Future<void> setVolume(String playerId, double volume);

  /// Sets the release mode.
  ///
  /// Check [ReleaseMode]'s doc to understand the difference between the modes.
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode);

  /// Sets the playback rate.
  ///
  /// iOS and macOS have limits between 0.5 and 2x
  /// Android SDK version should be 23 or higher
  Future<void> setPlaybackRate(String playerId, double playbackRate);

  /// Sets the pitch shift as a frequency multiplier, independent of the
  /// playback rate (1.0 = unchanged, 2.0 = one octave up, 0.5 = one octave
  /// down).
  ///
  /// Only supported on Android (via the Signalsmith processor in the
  /// audioplayers_android_exo implementation); other platforms throw
  /// [UnsupportedError].
  Future<void> setPitchShift(String playerId, double pitchShift);

  /// Configures the in-pipeline metronome click track: clicks synthesized
  /// inside the playback pipeline on the media-time beat grid
  /// `anchorMs + offsetMs + n * beatPeriod(bpm)`. Clicks stay sample-locked
  /// to the music across seeks, loops and speed changes.
  ///
  /// Pass `enabled: false` to turn the clicks off ([bpm] may be omitted
  /// then). [volume] is the click gain 0.0..1.0 relative to the song.
  ///
  /// Only supported on Android (audioplayers_android_exo); other platforms
  /// throw [UnsupportedError].
  Future<void> setClickTrack(
    String playerId, {
    required bool enabled,
    int? bpm,
    int? anchorMs,
    int offsetMs,
    int beatsPerBar,
    int pulsesPerBeat,
    double volume,
  });

  /// Configures the player to read the audio from a URL.
  ///
  /// The resources will start being fetched or buffered as soon as you call
  /// this method.
  Future<void> setSourceUrl(
    String playerId,
    String url, {
    bool? isLocal,
    String? mimeType,
  });

  /// Configures the play to read the audio from a byte array.
  Future<void> setSourceBytes(
    String playerId,
    Uint8List bytes, {
    String? mimeType,
  });

  Future<void> setAudioContext(
    String playerId,
    AudioContext audioContext,
  );

  Future<void> setPlayerMode(
    String playerId,
    PlayerMode playerMode,
  );

  /// Returns the duration of the media, in milliseconds, if available.
  ///
  /// Might not be available if:
  ///  * source has not been set or prepared yet (for remote audios it must be
  ///    downloaded and buffered first)
  ///  * source does not support operation (e.g. streams)
  ///  * otherwise not supported (e.g. LOW_LATENCY mode on Android)
  Future<int?> getDuration(String playerId);

  /// Returns the current position of playback, in milliseconds, if available.
  ///
  /// Might not be available if:
  ///  * source has not been set or prepared yet (for remote audios it must be
  ///    downloaded and buffered first)
  ///  * source does not support operation (e.g. streams)
  ///  * otherwise not supported (e.g. LOW_LATENCY mode on Android)
  Future<int?> getCurrentPosition(String playerId);

  @visibleForTesting
  Future<void> emitLog(String playerId, String message);

  @visibleForTesting
  Future<void> emitError(String playerId, String code, String message);
}

abstract class EventChannelAudioplayersPlatformInterface {
  Stream<AudioEvent> getEventStream(String playerId);
}
