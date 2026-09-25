import 'dart:async';
import 'dart:io' show Platform;
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

  /// Starts capturing into [path] using [profile]. [recorded] is stored in
  /// MP3 and WAV files as their recording date; [noiseReduction] turns on
  /// the platform's noise suppression (MP3 and WAV).
  Future<void> start(
    RecordingProfile profile,
    String path, {
    DateTime? recorded,
    bool noiseReduction = false,
  });

  /// Stops and finalizes the file.
  Future<void> stop();

  /// Pauses capture at the user's request, until [resume].
  Future<void> pause();

  /// Resumes a capture paused by [pause] or by the system (see
  /// [interrupted]).
  Future<void> resume();

  /// Input level between 0 (silence) and 1 (full scale), about 10 per second.
  Stream<double> get levels;

  /// True while capture is paused by the system (e.g. a phone call), not
  /// by [pause].
  Stream<bool> get interrupted;

  /// Fires once when a recording can't go on: see [CaptureEnd]. The file
  /// holds what was captured until then; call [stop] to finalize it.
  Stream<CaptureEnd> get ended;

  Future<void> dispose();
}

/// Why a recording ended without the user stopping it.
enum CaptureEnd {
  /// A platform error, the system ending the audio session, or audio no
  /// longer arriving.
  stopped,

  /// The file couldn't be written any more (e.g. storage full).
  writeFailed,

  /// A WAV file reached the format's 4 GB limit (about 13.5 hours).
  sizeLimit,
}

/// Largest WAV data size: the RIFF size fields are 32-bit.
const maxWavDataBytes = 0xFFFFFFFF - 36 - 1024 * 1024;

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

/// Averages interleaved 16-bit little-endian stereo PCM down to mono.
Uint8List downmixToMono(Uint8List stereo) {
  final frames = stereo.length ~/ 4;
  final src = ByteData.sublistView(stereo);
  final out = ByteData(frames * 2);
  for (var i = 0; i < frames; i++) {
    final l = src.getInt16(i * 4, Endian.little);
    final r = src.getInt16(i * 4 + 2, Endian.little);
    out.setInt16(i * 2, (l + r) >> 1, Endian.little);
  }
  return out.buffer.asUint8List();
}

/// [RecorderEngine] built on the `record` plugin. MP3 and WAV are encoded in
/// Dart from the PCM stream (MP3 through the bundled LAME encoder); M4A uses
/// the platform AAC encoder.
class RecordPluginEngine implements RecorderEngine {
  RecordPluginEngine({bool? isAndroid})
    : _recorder = AudioRecorder(),
      _isAndroid = isAndroid ?? Platform.isAndroid;

  final AudioRecorder _recorder;
  final bool _isAndroid;
  final _levels = StreamController<double>.broadcast();
  final _interrupted = StreamController<bool>.broadcast();
  final _ended = StreamController<CaptureEnd>.broadcast();

  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<RecordState>? _stateSub;
  Completer<void>? _streamDone;
  Future<void> _writes = Future.value();
  Mp3Writer? _mp3;
  WavWriter? _wav;
  Object? _writeError;
  Timer? _watchdog;

  /// Time since the last audio chunk (monotonic: clock changes don't count).
  final _sinceChunk = Stopwatch();

  /// Between a successful start and the end of [stop].
  bool _running = false;
  bool _stopping = false;

  /// Capture is paused, by the user or by the system.
  bool _paused = false;

  /// The user paused: nothing is recorded until they resume, even if the
  /// system resumes capture on its own (iOS does after a call).
  bool _userPaused = false;
  bool _endedSent = false;

  /// The format the platform actually delivers (it may differ from the
  /// request, e.g. stereo on an input device without a mono mode).
  int _channels = 1;
  int _sampleRate = 44100;

  /// Longest gap between audio chunks before capture counts as dead.
  static const _stallLimit = Duration(seconds: 5);

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Stream<bool> get interrupted => _interrupted.stream;

  @override
  Stream<CaptureEnd> get ended => _ended.stream;

  static const _androidConfig = AndroidRecordConfig(
    // Keep the microphone's natural gain, like a plain MediaRecorder.
    audioSource: AndroidAudioSource.mic,
    manageBluetooth: false,
  );

  // No Bluetooth hands-free profile: recordings use the phone's microphone
  // (as on Android) and playback over headphones keeps full quality.
  static const _iosConfig = IosRecordConfig(
    categoryOptions: [
      IosAudioCategoryOption.defaultToSpeaker,
      IosAudioCategoryOption.allowBluetoothA2DP,
    ],
  );

  RecordConfig _config(
    RecordingProfile profile,
    AudioEncoder encoder, {
    bool noiseReduction = false,
  }) => RecordConfig(
    encoder: encoder,
    sampleRate: profile.sampleRate,
    bitRate: (profile.bitRateKbps ?? 128) * 1000,
    numChannels: 1,
    androidConfig: _androidConfig,
    iosConfig: _iosConfig,
    // Android: the system's noise suppressor on the microphone input.
    // iOS: voice processing (noise and echo reduction), without automatic
    // gain.
    noiseSuppress: noiseReduction && _isAndroid,
    echoCancel: noiseReduction && !_isAndroid,
    // Android: audio focus must never pause a recording (after a
    // permanent focus loss, e.g. another app starting music, it would
    // never resume). A phone call records as silence instead.
    // iOS: calls and Siri pause the recording; it resumes afterwards.
    audioInterruption: _isAndroid
        ? AudioInterruptionMode.none
        : AudioInterruptionMode.pauseResume,
  );

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<void> start(
    RecordingProfile profile,
    String path, {
    DateTime? recorded,
    bool noiseReduction = false,
  }) async {
    _writeError = null;
    _paused = false;
    _userPaused = false;
    _endedSent = false;
    _channels = 1;
    _sampleRate = profile.sampleRate;
    _stateSub ??= _recorder.onStateChanged().listen(
      _onState,
      onError: _onPlatformError,
    );
    await _recorder.setOnConfigChanged((c) {
      _channels = c.numChannels;
      _sampleRate = c.sampleRate;
    });

    if (profile.type == RecordingType.m4a) {
      await _recorder.start(_config(profile, AudioEncoder.aacLc), path: path);
      _running = true;
      // iOS reports average power in this mode, about 10 dB below the peak
      // level the other formats show.
      final boost = _isAndroid ? 0.0 : 10.0;
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((a) => _levels.add(levelFromDb(a.current + boost)));
      return;
    }

    final stream = await _recorder.startStream(
      _config(profile, AudioEncoder.pcm16bits, noiseReduction: noiseReduction),
    );
    _running = true;

    // Open the writer only now: nothing is left behind if the start failed,
    // and the platform has reported the actual format (config changes are
    // delivered before startStream returns). Chunks queue up behind it.
    final type = profile.type;
    final bitRate = profile.bitRateKbps;
    final rate = _sampleRate;
    _writes = () async {
      try {
        if (type == RecordingType.mp3) {
          _mp3 = await Mp3Writer.open(
            path,
            sampleRate: rate,
            bitRateKbps: bitRate!,
            recorded: recorded,
          );
        } else {
          _wav = await WavWriter.open(
            path,
            sampleRate: rate,
            recorded: recorded,
          );
        }
      } catch (e) {
        // Nothing can be written (e.g. storage full): end the recording now
        // rather than let it look like it's recording.
        _writeError ??= e;
        _endedOnItsOwn(CaptureEnd.writeFailed);
      }
    }();

    final done = _streamDone = Completer<void>();
    var lastLevel = DateTime.fromMillisecondsSinceEpoch(0);
    _sinceChunk
      ..reset()
      ..start();
    _pcmSub = stream.listen(
      (chunk) {
        _sinceChunk.reset();
        // Audio delivered after the system resumed a paused recording on its
        // own, before it is paused again (see _onState).
        if (_userPaused) return;
        final now = DateTime.now();
        final pcm = _channels == 2 ? downmixToMono(chunk) : chunk;
        if (now.difference(lastLevel).inMilliseconds >= 90) {
          lastLevel = now;
          _levels.add(levelFromDb(peakDb(pcm)));
        }
        // Keep chunks in order: each write waits for the previous one.
        _writes = _writes.then((_) async {
          if (_writeError != null) return; // already failed: stop writing
          final wav = _wav;
          if (wav != null && wav.dataBytes + pcm.length > maxWavDataBytes) {
            _endedOnItsOwn(CaptureEnd.sizeLimit);
            return;
          }
          try {
            await (_mp3?.add(pcm) ?? wav?.add(pcm));
          } catch (e) {
            // e.g. storage full: the rest would be lost, so end it here.
            _writeError ??= e;
            _endedOnItsOwn(CaptureEnd.writeFailed);
          }
        });
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
        _endedOnItsOwn(CaptureEnd.stopped);
      },
      onError: _onPlatformError,
      cancelOnError: false,
    );
    // Capture can also die silently (e.g. the audio route changed under an
    // iOS audio engine); no chunks for a while means it did.
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_paused && _sinceChunk.elapsed > _stallLimit) {
        _endedOnItsOwn(CaptureEnd.stopped);
      }
    });
  }

  void _onState(RecordState state) {
    switch (state) {
      case RecordState.pause:
        _paused = true;
        if (!_userPaused) _interrupted.add(true);
      case RecordState.record:
        if (_userPaused) {
          // The system resumed a recording the user had paused (iOS, when a
          // call ends): keep it paused.
          if (_running && !_stopping) unawaited(_pauseQuietly());
          return;
        }
        _paused = false;
        _sinceChunk.reset();
        _interrupted.add(false);
      case RecordState.stop:
        _endedOnItsOwn(CaptureEnd.stopped);
    }
  }

  Future<void> _pauseQuietly() async {
    try {
      await _recorder.pause();
    } catch (_) {
      // Stopped meanwhile; nothing to keep paused.
    }
  }

  void _onPlatformError(Object e) {
    if (!_running) return;
    _writeError ??= e;
    _endedOnItsOwn(CaptureEnd.stopped);
  }

  void _endedOnItsOwn(CaptureEnd why) {
    if (!_running || _stopping || _endedSent) return;
    _endedSent = true;
    _watchdog?.cancel();
    _ended.add(why);
  }

  @override
  Future<void> pause() async {
    if (!_running || _stopping) return;
    // Set first: the watchdog must not count the pause as a stall, and no
    // chunk may be written from here on.
    final wasPaused = _paused;
    _userPaused = true;
    _paused = true;
    try {
      await _recorder.pause();
    } catch (e) {
      // Still recording: keep writing (and watching) it.
      _userPaused = false;
      _paused = wasPaused;
      rethrow;
    }
  }

  @override
  Future<void> resume() async {
    if (!_running || _stopping) return;
    final wasUserPaused = _userPaused;
    _userPaused = false;
    try {
      await _recorder.resume();
    } catch (e) {
      _userPaused = wasUserPaused;
      rethrow;
    }
    // A resume that happened while only the user's pause was in effect
    // restarts the stall clock (the state event may come later).
    _sinceChunk.reset();
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _watchdog?.cancel();
    _watchdog = null;
    Object? error;
    try {
      await _recorder.stop();
    } catch (e) {
      error = e;
    }
    try {
      await _ampSub?.cancel();
      _ampSub = null;
      final done = _streamDone;
      if (done != null) {
        // The stream closes once the platform side has delivered its data.
        await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
        await _pcmSub?.cancel();
        _pcmSub = null;
        _streamDone = null;
      }
      await _writes;
    } finally {
      try {
        await _mp3?.close();
        await _wav?.close();
      } catch (e) {
        error ??= e;
      } finally {
        _mp3 = null;
        _wav = null;
        _writes = Future.value();
        _running = false;
        _stopping = false;
        _paused = false;
        _userPaused = false;
      }
    }
    error ??= _writeError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    _watchdog?.cancel();
    await _stateSub?.cancel();
    await _pcmSub?.cancel();
    await _ampSub?.cancel();
    await _recorder.dispose();
    await _levels.close();
    await _interrupted.close();
    await _ended.close();
  }
}
