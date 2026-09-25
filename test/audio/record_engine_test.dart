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
  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    this.config = config;
    bytes = StreamController<Uint8List>.broadcast();
    return bytes!.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
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

  @override
  Future<void> resume(String recorderId) async {
    resumes++;
    emit(RecordState.record);
  }

  @override
  Future<bool> isRecording(String recorderId) async => true;
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
}
