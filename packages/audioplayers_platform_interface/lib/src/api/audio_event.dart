import 'package:flutter/foundation.dart';

enum AudioEventType {
  log,
  duration,
  seekComplete,
  complete,
  prepared,
  loopWrap,
}

/// Event emitted from the platform implementation.
@immutable
class AudioEvent {
  /// Creates an instance of [AudioEvent].
  ///
  /// The [eventType] argument is required.
  const AudioEvent({
    required this.eventType,
    this.duration,
    this.logMessage,
    this.isPrepared,
    this.loopWrapPosition,
  });

  /// The type of the event.
  final AudioEventType eventType;

  /// Duration of the audio.
  final Duration? duration;

  /// Log message in the player scope.
  final String? logMessage;

  /// Whether the source is prepared to be played.
  final bool? isPrepared;

  /// Position the playhead wrapped to on a native loop-region wrap.
  ///
  /// Distinct from [AudioEventType.seekComplete] so that native wraps never
  /// satisfy a pending user seek's completion future.
  final Duration? loopWrapPosition;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AudioEvent &&
            runtimeType == other.runtimeType &&
            eventType == other.eventType &&
            duration == other.duration &&
            logMessage == other.logMessage &&
            isPrepared == other.isPrepared &&
            loopWrapPosition == other.loopWrapPosition;
  }

  @override
  int get hashCode => Object.hash(
        eventType,
        duration,
        logMessage,
        isPrepared,
        loopWrapPosition,
      );

  @override
  String toString() {
    return 'AudioEvent('
        'eventType: $eventType, '
        'duration: $duration, '
        'logMessage: $logMessage, '
        'isPrepared: $isPrepared, '
        'loopWrapPosition: $loopWrapPosition'
        ')';
  }
}
