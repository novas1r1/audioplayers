import 'dart:async';

import 'package:audioplayers_platform_interface/src/api/audio_event.dart';
import 'package:audioplayers_platform_interface/src/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = AudioplayersPlatformInterface.instance;

  final methodCalls = <MethodCall>[];

  void clear() {
    methodCalls.clear();
  }

  MethodCall popCall() {
    return methodCalls.removeAt(0);
  }

  MethodCall popLastCall() {
    expect(methodCalls, hasLength(1));
    return popCall();
  }

  group('AudioPlayers Method Channel', () {
    setUp(() {
      clear();

      createNativeMethodHandler(
        channel: 'xyz.luan/audioplayers',
        handler: (MethodCall methodCall) async {
          methodCalls.add(methodCall);
          switch (methodCall.method) {
            case 'getDuration':
              return 0;
            case 'getCurrentPosition':
              return 0;
            default:
              return null;
          }
        },
      );
    });

    test('#setSource', () async {
      await platform.setSourceUrl(
        'p1',
        'internet.com/file.mp3',
        mimeType: 'audio/wav',
      );
      final call = popLastCall();
      expect(call.method, 'setSourceUrl');
      expect(call.args, {
        'playerId': 'p1',
        'url': 'internet.com/file.mp3',
        'isLocal': null,
        'mimeType': 'audio/wav',
      });
    });

    test('#resume', () async {
      await platform.resume('p1');
      final call = popLastCall();
      expect(call.method, 'resume');
      expect(call.args, {'playerId': 'p1'});
    });

    test('#pause', () async {
      await platform.pause('p1');
      final call = popLastCall();
      expect(call.method, 'pause');
      expect(call.args, {'playerId': 'p1'});
    });

    test('#getDuration', () async {
      final duration = await platform.getDuration('p1');
      final call = popLastCall();
      expect(call.method, 'getDuration');
      expect(call.args, {'playerId': 'p1'});
      expect(duration, 0);
    });

    test('#getCurrentPosition', () async {
      final position = await platform.getCurrentPosition('p1');
      final call = popLastCall();
      expect(call.method, 'getCurrentPosition');
      expect(call.args, {'playerId': 'p1'});
      expect(position, 0);
    });

    test('#setClickTrack', () async {
      await platform.setClickTrack(
        'p1',
        enabled: true,
        bpm: 120,
        anchorMs: 130,
        offsetMs: 25,
        beatsPerBar: 3,
        pulsesPerBeat: 2,
        volume: 0.6,
      );
      final call = popLastCall();
      expect(call.method, 'setClickTrack');
      expect(call.args, {
        'playerId': 'p1',
        'enabled': true,
        'bpm': 120,
        'anchorMs': 130,
        'offsetMs': 25,
        'beatsPerBar': 3,
        'pulsesPerBeat': 2,
        'volume': 0.6,
      });
    });

    test('#setClickTrack disabled needs no bpm', () async {
      await platform.setClickTrack('p1', enabled: false);
      final call = popLastCall();
      expect(call.method, 'setClickTrack');
      expect(call.args['enabled'], false);
      expect(call.args['bpm'], null);
    });

    test('#setLoopRegion', () async {
      await platform.setLoopRegion(
        'p1',
        enabled: true,
        startMs: 1500,
        endMs: 4500,
      );
      final call = popLastCall();
      expect(call.method, 'setLoopRegion');
      expect(call.args, {
        'playerId': 'p1',
        'enabled': true,
        'startMs': 1500,
        'endMs': 4500,
      });
    });

    test('#setLoopRegion disabled needs no bounds', () async {
      await platform.setLoopRegion('p1', enabled: false);
      final call = popLastCall();
      expect(call.method, 'setLoopRegion');
      expect(call.args['enabled'], false);
      expect(call.args['startMs'], null);
      expect(call.args['endMs'], null);
    });
  });

  group('AudioPlayers Event Channel', () {
    test('emit events', () async {
      final eventController = StreamController<ByteData>.broadcast();
      const playerId = 'p1';

      createNativeEventStream(
        channel: 'xyz.luan/audioplayers/events/$playerId',
        byteDataStream: eventController.stream,
      );

      await platform.create(playerId);

      expect(
        platform.getEventStream(playerId),
        emitsInOrder(<AudioEvent>[
          const AudioEvent(
            eventType: AudioEventType.duration,
            duration: Duration(milliseconds: 98765),
          ),
          const AudioEvent(
            eventType: AudioEventType.log,
            logMessage: 'someLogMessage',
          ),
          const AudioEvent(
            eventType: AudioEventType.complete,
          ),
          const AudioEvent(
            eventType: AudioEventType.seekComplete,
          ),
          const AudioEvent(
            eventType: AudioEventType.loopWrap,
            loopWrapPosition: Duration(milliseconds: 1500),
          ),
        ]),
      );

      final byteDataList = <Map<String, dynamic>>[
        <String, dynamic>{
          'event': 'audio.onDuration',
          'value': 98765,
        },
        <String, dynamic>{
          'event': 'audio.onLog',
          'value': 'someLogMessage',
        },
        <String, dynamic>{
          'event': 'audio.onComplete',
        },
        <String, dynamic>{
          'event': 'audio.onSeekComplete',
        },
        <String, dynamic>{
          'event': 'audio.onLoopWrap',
          'value': 1500,
        },
      ];
      for (final byteData in byteDataList) {
        eventController.add(
          const StandardMethodCodec().encodeSuccessEnvelope(byteData),
        );
      }

      await eventController.close();
      await platform.dispose(playerId);
    });
  });
}
