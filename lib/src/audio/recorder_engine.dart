import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import '../core/recording_format.dart';
import 'mp3_writer.dart';
import 'wav_writer.dart';

/// Captures microphone audio into a file.
abstract class RecorderEngine {
  /// Asks for (and returns) microphone permission.
  Future<bool> requestPermission();

  /// Starts capturing into [path] using [profile].
  Future<void> start(RecordingProfile profile, String path);

  /// Stops and finalizes the file.
  Future<void> stop();

  /// Input level between 0 (silence) and 1 (full scale), about 10 per second.
  Stream<double> get levels;

  /// True while capture is paused by the system (e.g. a phone call).
  Stream<bool> get interrupted;

  Future<void> dispose();
}

/// Maps a dBFS value onto the 0..1 range shown by the level meter.
double levelFromDb(double db) => ((db + 50) / 50).clamp(0.0, 1.0);

/// Peak level of a chunk of 16-bit little-endian PCM, in dBFS.
double peakDb(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  var peak = 0;
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    final v = data.getInt16(i, Endian.little).abs();
    if (v > peak) peak = v;
  }
  if (peak == 0) return -160;
  return 20 * math.log(peak / 32768) / math.ln10;
}

/// [RecorderEngine] built on the `record` plugin. MP3 and WAV are encoded in
/// Dart from the PCM stream (MP3 through the bundled LAME encoder); M4A uses
/// the platform AAC encoder.
class RecordPluginEngine implements RecorderEngine {
  RecordPluginEngine() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  final _levels = StreamController<double>.broadcast();
  final _interrupted = StreamController<bool>.broadcast();

  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<RecordState>? _stateSub;
  Completer<void>? _streamDone;
  Future<void> _writes = Future.value();
  Mp3Writer? _mp3;
  WavWriter? _wav;
  Object? _writeError;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<bool> get interrupted => _interrupted.stream;

  static const _android = AndroidRecordConfig(
    // Keep the microphone's natural gain, like a plain MediaRecorder.
    audioSource: AndroidAudioSource.mic,
    manageBluetooth: false,
  );

  static const _ios = IosRecordConfig(
    categoryOptions: [
      IosAudioCategoryOption.defaultToSpeaker,
      IosAudioCategoryOption.allowBluetooth,
      IosAudioCategoryOption.allowBluetoothA2DP,
    ],
  );

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<void> start(RecordingProfile profile, String path) async {
    _writeError = null;
    _stateSub ??= _recorder.onStateChanged().listen(
      (s) => _interrupted.add(s == RecordState.pause),
    );

    if (profile.type == RecordingType.m4a) {
      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: profile.sampleRate,
          bitRate: profile.bitRateKbps! * 1000,
          numChannels: 1,
          androidConfig: _android,
          iosConfig: _ios,
          audioInterruption: AudioInterruptionMode.pauseResume,
        ),
        path: path,
      );
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((a) => _levels.add(levelFromDb(a.current)));
      return;
    }

    if (profile.type == RecordingType.mp3) {
      _mp3 = await Mp3Writer.open(
        path,
        sampleRate: profile.sampleRate,
        bitRateKbps: profile.bitRateKbps!,
      );
    } else {
      _wav = await WavWriter.open(path, sampleRate: profile.sampleRate);
    }
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: profile.sampleRate,
        numChannels: 1,
        androidConfig: _android,
        iosConfig: _ios,
        audioInterruption: AudioInterruptionMode.pauseResume,
      ),
    );
    final done = _streamDone = Completer<void>();
    var lastLevel = DateTime.fromMillisecondsSinceEpoch(0);
    _pcmSub = stream.listen(
      (chunk) {
        final now = DateTime.now();
        if (now.difference(lastLevel).inMilliseconds >= 90) {
          lastLevel = now;
          _levels.add(levelFromDb(peakDb(chunk)));
        }
        // Keep chunks in order: each write waits for the previous one.
        _writes = _writes.then((_) async {
          try {
            await (_mp3?.add(chunk) ?? _wav?.add(chunk));
          } catch (e) {
            _writeError ??= e;
          }
        });
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (Object e) => _writeError ??= e,
      cancelOnError: false,
    );
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
    await _ampSub?.cancel();
    _ampSub = null;
    final done = _streamDone;
    if (done != null) {
      // The stream closes once the platform side has flushed its buffers.
      await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
      await _pcmSub?.cancel();
      _pcmSub = null;
      _streamDone = null;
    }
    await _writes;
    try {
      await _mp3?.close();
      await _wav?.close();
    } finally {
      _mp3 = null;
      _wav = null;
    }
    final err = _writeError;
    if (err != null) throw err;
  }

  @override
  Future<void> dispose() async {
    await _stateSub?.cancel();
    await _pcmSub?.cancel();
    await _ampSub?.cancel();
    await _recorder.dispose();
    await _levels.close();
    await _interrupted.close();
  }
}
