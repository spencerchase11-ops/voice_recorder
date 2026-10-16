// The real RecordPluginEngine against a fake `record` platform.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lame_mp3/src/native_library.dart';
import 'package:record/record.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/recording_format.dart';

class _FakeRecordPlatform extends RecordPlatform {
  final _states = StreamController<RecordState>.broadcast();
  StreamController<Uint8List>? bytes;
  void Function(RecordConfig)? onConfig;
  RecordConfig? config;
  var pauses = 0;
  var resumes = 0;

  void emit(RecordState s) => _states.add(s);

  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {}

  /// Whether the platform recorder runs (record_ios: its state isn't "stop").
  var recording = false;
  var streamStarts = 0;

  /// Stream starts that fail from now on (e.g. no audio session to be had).
  var failingStarts = 0;

  /// Holds the next stream start until completed.
  Completer<void>? startGate;

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    // Like record_ios: a running capture is stopped first, and says so.
    if (recording) {
      recording = false;
      emit(RecordState.stop);
    }
    final gate = startGate;
    startGate = null;
    await gate?.future;
    streamStarts++;
    if (failingStarts > 0) {
      failingStarts--;
      throw Exception('cannot start');
    }
    this.config = config;
    bytes = StreamController<Uint8List>.broadcast();
    recording = true;
    emit(RecordState.record);
    return bytes!.stream;
  }

  /// record_ios stopping its own capture (e.g. a conversion that failed):
  /// it reports the state, the stream just goes quiet.
  void dies() {
    recording = false;
    emit(RecordState.stop);
  }

  @override
  Future<String?> stop(String recorderId) async {
    recording = false;
    await bytes?.close();
    return null;
  }

  Object? pauseError;

  @override
  Future<void> pause(String recorderId) async {
    pauses++;
    if (pauseError != null) throw pauseError!;
    emit(RecordState.pause);
  }

  Object? resumeError;

  @override
  Future<void> resume(String recorderId) async {
    resumes++;
    // record_ios ignores a resume when it isn't paused (e.g. stopped).
    if (!recording) return;
    if (resumeError != null) throw resumeError!;
    emit(RecordState.record);
  }

  @override
  Future<bool> isRecording(String recorderId) async => recording;
  @override
  Future<bool> isPaused(String recorderId) async => false;
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;
  @override
  Future<void> cancel(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -40, max: -10);
  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder e) async =>
      true;
  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async =>
      const [];
  @override
  Stream<RecordState> onStateChanged(String recorderId) => _states.stream;
  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) => onConfig = handler;
}

Uint8List _tone(int samples, {int channels = 1}) {
  final b = ByteData(samples * 2 * channels);
  for (var i = 0; i < samples; i++) {
    final v = (math.sin(i / 10) * 9000).round();
    for (var c = 0; c < channels; c++) {
      b.setInt16((i * channels + c) * 2, v, Endian.little);
    }
  }
  return b.buffer.asUint8List();
}

void main() {
  final lame = File('packages/lame_mp3/build/host/liblame_mp3.so');
  if (lame.existsSync()) lameMp3LibraryPathOverride = lame.absolute.path;
  final noDevFull = File('/dev/full').existsSync() ? null : 'needs /dev/full';

  late _FakeRecordPlatform platform;
  late Directory dir;
  late RecordPluginEngine engine;
  late List<CaptureEnd> ends;

  setUp(() async {
    RecordPlatform.instance = platform = _FakeRecordPlatform();
    dir = await Directory.systemTemp.createTemp('engine');
    engine = RecordPluginEngine(isAndroid: true);
    ends = [];
    engine.ended.listen(ends.add);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<void> feed(Uint8List chunk, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      platform.bytes!.add(chunk);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  final wavBest = RecordingProfile.of(RecordingType.wav, RecordingQuality.best);

  test('records a WAV; a normal stop is not an unexpected end', () async {
    final path = '${dir.path}/a.wav';
    await engine.start(wavBest, path);
    await feed(_tone(4410), 10);
    await engine.stop();
    final b = await File(path).readAsBytes();
    expect(b.length, 44 + 88200);
    expect(ByteData.sublistView(b).getUint32(40, Endian.little), 88200);
    expect(ends, isEmpty);
  });

  test('stereo from the device is written as mono', () async {
    final path = '${dir.path}/s.wav';
    await engine.start(wavBest, path);
    platform.onConfig!(const RecordConfig(numChannels: 2, sampleRate: 44100));
    await feed(_tone(4410, channels: 2), 10);
    await engine.stop();
    expect(await File(path).length(), 44 + 88200); // 1 s mono, not 2 s
  });

  test('capture that the platform stops ends the recording', () async {
    await engine.start(wavBest, '${dir.path}/b.wav');
    await feed(_tone(441));
    platform.emit(RecordState.stop);
    await Future<void>.delayed(Duration.zero);
    expect(ends, [CaptureEnd.stopped]);
    await engine.stop();
  });

  test('storage running out mid-recording ends it at once', () async {
    await engine.start(
      RecordingProfile.of(RecordingType.mp3, RecordingQuality.best),
      '/dev/full', // opens fine, every write fails with ENOSPC
    );
    await feed(_tone(4410), 5);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ends, [CaptureEnd.writeFailed]);
    await expectLater(engine.stop(), throwsA(isA<FileSystemException>()));
  }, skip: lame.existsSync() ? noDevFull : 'needs the host LAME build');

  test('a WAV that cannot be created ends the recording at once', () async {
    await engine.start(wavBest, '/dev/full');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ends, [CaptureEnd.writeFailed]);
    await expectLater(engine.stop(), throwsA(isA<FileSystemException>()));
  }, skip: noDevFull);

  test('the engine can record again after a failed start', () async {
    await engine.start(wavBest, '/nonexistent-dir/x.wav');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await expectLater(engine.stop(), throwsA(anything));
    ends.clear();
    final path = '${dir.path}/c.wav';
    await engine.start(wavBest, path);
    await feed(_tone(4410));
    await engine.stop();
    expect(await File(path).length(), 44 + 8820);
    expect(ends, isEmpty);
  });

  test('a paused recording writes nothing until resumed', () async {
    final interruptions = <bool>[];
    engine.interrupted.listen(interruptions.add);
    final path = '${dir.path}/p.wav';
    await engine.start(wavBest, path);
    await feed(_tone(4410), 2);
    await engine.pause();
    await feed(_tone(4410), 3); // arrives anyway: dropped
    await engine.resume();
    await feed(_tone(4410), 2);
    await engine.stop();
    expect(await File(path).length(), 44 + 4 * 8820);
    // The user's pause is not an interruption.
    expect(interruptions, isNot(contains(true)));
    expect((platform.pauses, platform.resumes), (1, 1));
  });

  test(
    'iOS: a paused recording stays paused when the system resumes it',
    () async {
      engine = RecordPluginEngine(isAndroid: false);
      final path = '${dir.path}/i.wav';
      await engine.start(wavBest, path);
      await feed(_tone(4410));
      await engine.pause();
      // A call ends: iOS resumes the capture by itself.
      platform.emit(RecordState.record);
      await Future<void>.delayed(Duration.zero);
      expect(platform.pauses, 2); // paused again
      await feed(_tone(4410), 2); // in between: dropped
      await engine.stop();
      expect(await File(path).length(), 44 + 8820);
    },
  );

  test(
    'iOS, M4A: calls pause the timer, and a paused one stays paused',
    () async {
      // The system pauses the M4A recorder for a call without the plugin
      // saying so: the audio session's interruptions tell.
      final calls = StreamController<AudioInterruptionEvent>.broadcast();
      addTearDown(calls.close);
      engine = RecordPluginEngine(
        isAndroid: false,
        sessionInterruptions: calls.stream,
      );
      final interruptions = <bool>[];
      engine.interrupted.listen(interruptions.add);
      await engine.start(
        RecordingProfile.of(RecordingType.m4a, RecordingQuality.best),
        '${dir.path}/a.m4a',
      );
      calls.add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      await Future<void>.delayed(Duration.zero);
      expect(interruptions, [true]);
      // Resumed: the plugin resumes the recorder without saying so either
      // (record_ios only reports changes, and its state never left
      // "recording").
      calls.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(Duration.zero);
      expect(interruptions, [true, false]);

      // Paused by the user during the next call: after it ends (and iOS
      // resumes the recorder), it is paused again.
      calls.add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      await Future<void>.delayed(Duration.zero);
      await engine.pause();
      final pauses = platform.pauses;
      calls.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(platform.pauses, pauses + 1);
      expect(interruptions, [true, false, true]);
      await engine.stop();
    },
  );

  test('noise reduction reaches the platform', () async {
    await engine.start(wavBest, '${dir.path}/n.wav', noiseReduction: true);
    expect(platform.config!.noiseSuppress, isTrue); // Android
    expect(platform.config!.echoCancel, isFalse);
    await engine.stop();

    engine = RecordPluginEngine(isAndroid: false);
    await engine.start(wavBest, '${dir.path}/n2.wav', noiseReduction: true);
    expect(platform.config!.echoCancel, isTrue); // iOS voice processing
    expect(platform.config!.autoGain, isFalse);
    await engine.stop();

    await engine.start(wavBest, '${dir.path}/n3.wav');
    expect(platform.config!.echoCancel, isFalse);
    expect(platform.config!.noiseSuppress, isFalse);
    await engine.stop();
  });

  test('the recording date is stored in the file', () async {
    final recorded = DateTime(2026, 9, 25, 3, 30);
    final path = '${dir.path}/d.wav';
    await engine.start(wavBest, path, recorded: recorded);
    await feed(_tone(4410), 10);
    await engine.stop();
    final a = await FileByteAccess.open(File(path));
    final info = await readAudioInfo(a, path);
    await a.close();
    expect(info.recorded, recorded);
    expect(info.duration, const Duration(seconds: 1));
  });

  test('a pause the platform refuses leaves the recording running', () async {
    final path = '${dir.path}/r.wav';
    await engine.start(wavBest, path);
    platform.pauseError = Exception('refused');
    await expectLater(engine.pause(), throwsException);
    await feed(_tone(4410), 3); // still written
    await engine.stop();
    expect(await File(path).length(), 44 + 3 * 8820);
  });

  group('iOS: capture the system breaks goes on in the same file', () {
    late StreamController<AudioInterruptionEvent> calls;
    late StreamController<void> routes;
    late StreamController<void> resets;
    late List<bool> interruptions;
    late bool foreground;

    RecordPluginEngine iosEngine({
      List<Duration> restartDelays = const [
        Duration(milliseconds: 20),
        Duration(milliseconds: 20),
      ],
      Duration resumeCheck = const Duration(milliseconds: 50),
    }) {
      final e = RecordPluginEngine(
        isAndroid: false,
        sessionInterruptions: calls.stream,
        routeChanges: routes.stream,
        mediaResets: resets.stream,
        stallLimit: const Duration(milliseconds: 200),
        restartDelays: restartDelays,
        resumeCheck: resumeCheck,
        routeCheck: const Duration(milliseconds: 50),
        inForeground: () => foreground,
      );
      ends = [];
      e.ended.listen(ends.add);
      interruptions = [];
      e.interrupted.listen(interruptions.add);
      return e;
    }

    setUp(() {
      foreground = true;
      calls = StreamController<AudioInterruptionEvent>.broadcast();
      routes = StreamController<void>.broadcast();
      resets = StreamController<void>.broadcast();
      engine = iosEngine();
    });
    tearDown(() async {
      // A failed test must not leave an engine running into the next one.
      try {
        await engine.stop();
      } catch (_) {}
      await engine.dispose();
      await calls.close();
      await routes.close();
      await resets.close();
    });

    Future<void> settle([int ms = 100]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    /// Waits (up to 5 s, so a slow machine doesn't fail it) for [done].
    Future<void> eventually(bool Function() done) async {
      final clock = Stopwatch()..start();
      while (!done()) {
        if (clock.elapsed > const Duration(seconds: 5)) {
          fail('timed out');
        }
        await settle(10);
      }
    }

    AudioInterruptionEvent began() =>
        AudioInterruptionEvent(true, AudioInterruptionType.unknown);
    AudioInterruptionEvent over({bool resume = false}) =>
        AudioInterruptionEvent(
          false,
          resume ? AudioInterruptionType.pause : AudioInterruptionType.unknown,
        );

    test('the plugin stopping its capture (after a call)', () async {
      final path = '${dir.path}/c1.wav';
      await engine.start(wavBest, path, noiseReduction: true);
      final first = platform.config!;
      await feed(_tone(4410), 2);
      platform.dies();
      await eventually(() => platform.streamStarts == 2);
      // The same capture as before: format, voice processing, session.
      final again = platform.config!;
      expect(again.encoder, AudioEncoder.pcm16bits);
      expect(again.sampleRate, first.sampleRate);
      expect(again.numChannels, 1);
      expect(again.echoCancel, isTrue);
      expect(again.autoGain, isFalse);
      expect(again.iosConfig.categoryOptions, first.iosConfig.categoryOptions);
      expect(again.audioInterruption, AudioInterruptionMode.pauseResume);
      await feed(_tone(4410), 3);
      await engine.stop();
      expect(ends, isEmpty);
      expect(await File(path).length(), 44 + 5 * 8820);
      // The timer stood still meanwhile.
      expect(interruptions, containsAllInOrder([true, false]));
      expect(interruptions.last, isFalse);
    });

    test('a capture that goes silent', () async {
      final path = '${dir.path}/c2.mp3';
      await engine.start(
        RecordingProfile.of(RecordingType.mp3, RecordingQuality.best),
        path,
      );
      await feed(_tone(4410));
      // No more audio: the watchdog (every second) notices.
      await eventually(() => platform.streamStarts == 2);
      await feed(_tone(4410));
      await engine.stop();
      expect(ends, isEmpty);
    }, skip: lame.existsSync() ? null : 'needs the host LAME build');

    test(
      'a route change that silences the capture is noticed at once',
      () async {
        await engine.start(wavBest, '${dir.path}/r1.wav');
        await feed(_tone(4410));
        routes.add(null); // AirPods connect; the engine stops, unreported
        // Well before the stall check (it looks once a second).
        await settle(400);
        expect(platform.streamStarts, 2);
        expect(ends, isEmpty);
        await engine.stop();
      },
    );

    test(
      'a route change with the audio still flowing changes nothing',
      () async {
        await engine.start(wavBest, '${dir.path}/r2.wav');
        routes.add(null);
        await feed(_tone(441), 10); // keeps arriving through the check
        await settle(100);
        expect(platform.streamStarts, 1);
        await engine.stop();
        expect(ends, isEmpty);
      },
    );

    test('a reset of the media services starts the capture again', () async {
      await engine.start(wavBest, '${dir.path}/r3.wav');
      await feed(_tone(4410));
      resets.add(null);
      await eventually(() => platform.streamStarts == 2);
      await engine.stop();
      expect(ends, isEmpty);
    });

    test('an interruption ending without "should resume"', () async {
      await engine.start(wavBest, '${dir.path}/c3.wav');
      await feed(_tone(4410));
      calls.add(began());
      platform.emit(RecordState.pause); // the plugin pauses for the call
      await settle(60);
      expect(platform.streamStarts, 1);
      // Over; record_ios only resumes when told to, and isn't.
      calls.add(over());
      await eventually(() => platform.streamStarts == 2);
      await settle(10);
      expect(interruptions.last, isFalse);
      await feed(_tone(4410));
      await engine.stop();
      expect(ends, isEmpty);
    });

    test('an interruption whose resumed capture stays silent', () async {
      await engine.start(wavBest, '${dir.path}/c4.wav');
      await feed(_tone(4410));
      calls.add(began());
      platform.emit(RecordState.pause);
      calls.add(over(resume: true));
      // record_ios resumes its engine a moment later, which delivers
      // nothing (the input changed during the call); its "record" resets
      // the stall clock.
      await settle(25);
      platform.emit(RecordState.record);
      // Well before the stall check (it looks once a second).
      await settle(400);
      expect(platform.streamStarts, 2);
      await engine.stop();
      expect(ends, isEmpty);
    });

    test('waits for a call to end before starting again', () async {
      await engine.start(wavBest, '${dir.path}/c5.wav');
      await feed(_tone(4410));
      calls.add(began());
      platform.emit(RecordState.pause);
      platform.dies(); // during the call
      await settle(500);
      expect(platform.streamStarts, 1); // not yet: the call still has it
      expect(ends, isEmpty);
      calls.add(over(resume: true));
      await eventually(() => platform.streamStarts == 2);
      await engine.stop();
      expect(ends, isEmpty);
    });

    test('an interruption that never says it ended does not block '
        'later restarts', () async {
      await engine.start(wavBest, '${dir.path}/c6.wav');
      await feed(_tone(4410));
      calls.add(began()); // another app's audio; no end ever comes
      platform.emit(RecordState.pause);
      await settle(20);
      // Back in the app: AppController.onResume resumes it.
      await engine.resume();
      await feed(_tone(4410));
      // Later, a route change kills the capture.
      platform.dies();
      await eventually(() => platform.streamStarts == 2);
      await feed(_tone(4410));
      await engine.stop();
      expect(ends, isEmpty);
    });

    test('a capture that cannot be started again ends it, saved', () async {
      final path = '${dir.path}/c7.wav';
      await engine.start(wavBest, path);
      await feed(_tone(4410), 2);
      platform.failingStarts = 99;
      platform.dies();
      await eventually(() => ends.isNotEmpty);
      expect(ends, [CaptureEnd.stopped]);
      expect(platform.streamStarts, 1 + 3); // at once, then twice more
      await engine.stop();
      expect(await File(path).length(), 44 + 2 * 8820);
    });

    test('in the background, one that cannot be started again stays paused '
        'until the app is opened', () async {
      final path = '${dir.path}/c8.wav';
      await engine.start(wavBest, path);
      await feed(_tone(4410));
      foreground = false;
      platform.failingStarts = 3; // iOS refuses while in the background
      platform.dies();
      await eventually(() => platform.streamStarts == 1 + 3);
      await settle(100);
      expect(ends, isEmpty);
      expect(interruptions.last, isTrue); // the timer stands still
      // Opened again: AppController.onResume resumes it.
      foreground = true;
      await engine.resume();
      expect(platform.streamStarts, 1 + 3 + 1);
      await settle(10);
      expect(interruptions.last, isFalse);
      await feed(_tone(4410), 2);
      await engine.stop();
      expect(ends, isEmpty);
      expect(await File(path).length(), 44 + 3 * 8820);
    });

    test(
      'opened again but still failing, it is tried again and ends',
      () async {
        await engine.start(wavBest, '${dir.path}/c9.wav');
        await feed(_tone(4410));
        foreground = false;
        platform.failingStarts = 99;
        platform.dies();
        await eventually(() => platform.streamStarts == 1 + 3);
        await settle(100);
        expect(ends, isEmpty);
        foreground = true;
        // AppController.onResume: the error is only logged there.
        await expectLater(engine.resume(), throwsException);
        await eventually(() => ends.isNotEmpty);
        expect(ends, [CaptureEnd.stopped]);
      },
    );

    test('a user pause during a recovery stops it; resume starts the '
        'capture', () async {
      engine = iosEngine(restartDelays: const [Duration(milliseconds: 300)]);
      await engine.start(wavBest, '${dir.path}/c10.wav');
      await feed(_tone(4410));
      platform.failingStarts = 1; // the first attempt fails
      platform.dies();
      await eventually(() => platform.streamStarts == 2);
      await engine.pause(); // during the 300 ms wait
      await settle(500);
      expect(platform.streamStarts, 2); // no attempt while paused
      expect(ends, isEmpty); // and no end either
      await engine.resume();
      expect(platform.streamStarts, 3);
      await feed(_tone(4410));
      await engine.stop();
      expect(ends, isEmpty);
    });

    test('a resume when the capture died while paused by the user', () async {
      final path = '${dir.path}/c11.wav';
      await engine.start(wavBest, path);
      await feed(_tone(4410));
      await engine.pause();
      platform.dies();
      await settle(500);
      expect(platform.streamStarts, 1); // kept paused: nothing to restart yet
      await engine.resume();
      expect(platform.streamStarts, 2);
      expect(platform.resumes, 0); // not a resume of the dead one
      await feed(_tone(4410));
      await engine.stop();
      expect(await File(path).length(), 44 + 2 * 8820);
      expect(ends, isEmpty);
    });

    test('a resume the plugin refuses starts a new capture', () async {
      final path = '${dir.path}/c12.wav';
      await engine.start(wavBest, path);
      await feed(_tone(4410));
      await engine.pause();
      platform.resumeError = Exception('engine gone');
      await engine.resume();
      expect(platform.streamStarts, 2);
      await feed(_tone(4410), 2);
      await engine.stop();
      expect(await File(path).length(), 44 + 3 * 8820);
      expect(ends, isEmpty);
    });

    test(
      'a stop while a recovery starts the capture leaves none running',
      () async {
        await engine.start(wavBest, '${dir.path}/c13.wav');
        await feed(_tone(4410));
        final gate = platform.startGate = Completer<void>();
        platform.dies();
        await settle(400);
        final stopping = engine.stop();
        gate.complete();
        await stopping;
        expect(platform.streamStarts, 2);
        expect(platform.recording, isFalse);
        expect(ends, isEmpty);
      },
    );

    test(
      'a stop while resume starts the capture leaves none running',
      () async {
        await engine.start(wavBest, '${dir.path}/c14.wav');
        await feed(_tone(4410));
        await engine.pause();
        platform.dies();
        await settle(400);
        final gate = platform.startGate = Completer<void>();
        final resuming = engine.resume();
        await settle(10);
        final stopping = engine.stop();
        gate.complete();
        await resuming;
        await stopping;
        expect(platform.recording, isFalse);
      },
    );

    test('a stop during a long wait between attempts is quick', () async {
      engine = iosEngine(restartDelays: const [Duration(seconds: 30)]);
      await engine.start(wavBest, '${dir.path}/c15.wav');
      await feed(_tone(4410));
      platform.failingStarts = 1;
      platform.dies();
      await eventually(() => platform.streamStarts == 2);
      final clock = Stopwatch()..start();
      await engine.stop();
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(platform.streamStarts, 2);
      expect(ends, isEmpty);
    });

    test('an interruption check of a stopped recording does not reach the '
        'next one', () async {
      engine = iosEngine(resumeCheck: const Duration(milliseconds: 300));
      await engine.start(wavBest, '${dir.path}/c16.wav');
      calls.add(over()); // arms the check (no audio yet, like the next one)
      await settle(20);
      await engine.stop();
      // The next recording is M4A, which isn't restarted but would end.
      await engine.start(
        RecordingProfile.of(RecordingType.m4a, RecordingQuality.best),
        '${dir.path}/c16.m4a',
      );
      await settle(500);
      expect(ends, isEmpty);
    });

    test('M4A is not started again (it would replace the file)', () async {
      await engine.start(
        RecordingProfile.of(RecordingType.m4a, RecordingQuality.best),
        '${dir.path}/c17.m4a',
      );
      platform.emit(RecordState.stop);
      await settle(50);
      expect(ends, [CaptureEnd.stopped]);
      expect(platform.streamStarts, 0);
    });
  });
}
