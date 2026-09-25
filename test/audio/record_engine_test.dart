// The real RecordPluginEngine against a fake `record` platform.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lame_mp3/src/native_library.dart';
import 'package:record/record.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/recording_format.dart';

class _FakeRecordPlatform extends RecordPlatform {
  final _states = StreamController<RecordState>.broadcast();
  StreamController<Uint8List>? bytes;
  void Function(RecordConfig)? onConfig;

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
    bytes = StreamController<Uint8List>.broadcast();
    return bytes!.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    await bytes?.close();
    return null;
  }

  @override
  Future<void> pause(String recorderId) async {}
  @override
  Future<void> resume(String recorderId) async {}
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
}
