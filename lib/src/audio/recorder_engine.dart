import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
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
///
/// iOS, MP3 and WAV: the plugin's audio engine doesn't survive everything
/// the system does to the audio session. After a call the input may come
/// back in another format, and a route change (headphones, a car) or a
/// reset of the media services can stop the engine: it then stops itself,
/// or just delivers nothing. An interruption without "should resume" is
/// never resumed. Capture that dies like that is started again and goes on
/// into the same file (the plugin always converts to the format asked for);
/// only if that keeps failing does the recording end.
class RecordPluginEngine implements RecorderEngine {
  /// The streams stand in for the audio session's, and the durations for
  /// the real ones (tests).
  RecordPluginEngine({
    bool? isAndroid,
    this._sessionInterruptions,
    this._routeChanges,
    this._mediaResets,
    this._stallLimit = const Duration(seconds: 5),
    this._restartDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    this._resumeCheck = const Duration(seconds: 2),
    this._routeCheck = const Duration(seconds: 1),
    bool Function()? inForeground,
  }) : _recorder = AudioRecorder(),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _inForeground = inForeground ?? _appInForeground;

  static bool _appInForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Whether the app is in the foreground: iOS may not let a capture start
  /// in the background (outside of an interruption that ends).
  final bool Function() _inForeground;

  final AudioRecorder _recorder;
  final bool _isAndroid;
  final Stream<AudioInterruptionEvent>? _sessionInterruptions;
  final Stream<void>? _routeChanges;
  final Stream<void>? _mediaResets;
  StreamSubscription<AudioInterruptionEvent>? _sessionSub;
  StreamSubscription<void>? _routeSub;
  StreamSubscription<void>? _resetSub;
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
  DateTime _lastLevel = DateTime.fromMillisecondsSinceEpoch(0);

  /// Time since the last audio chunk (monotonic: clock changes don't count).
  final _sinceChunk = Stopwatch();

  /// Audio chunks received in this recording: tells whether any came since
  /// a moment (the stall clock is also reset by the plugin's state events).
  int _chunks = 0;

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

  /// The sample rate the file is being written at.
  int _writerRate = 44100;

  /// Longest gap between audio chunks before capture counts as dead.
  final Duration _stallLimit;

  /// Waits between attempts to start capture again.
  final List<Duration> _restartDelays;

  /// How long after an interruption ends the capture must be flowing again.
  final Duration _resumeCheck;

  /// How long after a route change (or a reset) audio must be arriving.
  final Duration _routeCheck;

  /// Restarts allowed per recording (capture that dies again and again
  /// would otherwise never end).
  static const _maxRestarts = 20;

  /// The stream configuration of the recording, while one can be restarted
  /// (iOS, MP3 and WAV).
  RecordConfig? _restartable;

  /// Each platform stream gets a number: events of earlier ones are ignored.
  int _stream = 0;

  /// The restart under way, if any: the only one (see [_captureLost] and
  /// [resume]), and the one [stop] waits for. It never fails.
  Future<void>? _recovery;
  int _restarts = 0;

  /// [resume] is under way: a capture lost meanwhile is its business.
  bool _resuming = false;
  bool _lostWhileResuming = false;

  /// An audio session interruption (a call) has begun and not yet ended, as
  /// far as is known: iOS doesn't promise an end, so a capture that runs
  /// again clears it too.
  bool _sessionInterrupted = false;

  /// Checks after an interruption's end and after a route change; they
  /// belong to one recording.
  Timer? _resumeTimer;
  Timer? _routeTimer;

  /// Completed by [stop]: cuts a recovery's waits short.
  Completer<void> _stopSignal = Completer<void>();

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
    _restartable = null;
    _restarts = 0;
    _chunks = 0;
    _resuming = false;
    _lostWhileResuming = false;
    _sessionInterrupted = false;
    _cancelChecks();
    _stopSignal = Completer<void>();
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
      if (!_isAndroid) await _watchInterruptions();
      // iOS reports average power in this mode, about 10 dB below the peak
      // level the other formats show.
      final boost = _isAndroid ? 0.0 : 10.0;
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((a) => _levels.add(levelFromDb(a.current + boost)));
      return;
    }

    final config = _config(
      profile,
      AudioEncoder.pcm16bits,
      noiseReduction: noiseReduction,
    );
    final stream = await _recorder.startStream(config);
    _running = true;
    if (!_isAndroid) _restartable = config;

    // Open the writer only now: nothing is left behind if the start failed,
    // and the platform has reported the actual format (config changes are
    // delivered before startStream returns). Chunks queue up behind it.
    final type = profile.type;
    final bitRate = profile.bitRateKbps;
    final rate = _writerRate = _sampleRate;
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

    _listen(stream);
    // Capture can also die silently (e.g. the audio route changed under an
    // iOS audio engine); no chunks for a while means it did.
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_paused && _recovery == null && _sinceChunk.elapsed > _stallLimit) {
        _captureLost();
      }
    });
    if (!_isAndroid) {
      await _watchInterruptions();
      await _watchRoutes();
    }
  }

  /// Writes the chunks of a platform stream into the file, from the first
  /// stream of a recording or from one that replaced it (see [_recover]).
  void _listen(Stream<Uint8List> stream) {
    final number = ++_stream;
    final done = _streamDone = Completer<void>();
    _lastLevel = DateTime.fromMillisecondsSinceEpoch(0);
    _sinceChunk
      ..reset()
      ..start();
    _pcmSub = stream.listen(
      (chunk) {
        if (number != _stream) return;
        _sinceChunk.reset();
        _chunks++;
        // Audio delivered after the system resumed a paused recording on its
        // own, before it is paused again (see _onState).
        if (_userPaused) return;
        final now = DateTime.now();
        final pcm = _channels == 2 ? downmixToMono(chunk) : chunk;
        if (now.difference(_lastLevel).inMilliseconds >= 90) {
          _lastLevel = now;
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
        if (number == _stream) _captureLost();
      },
      onError: (Object e) {
        if (number == _stream) _onPlatformError(e);
      },
      cancelOnError: false,
    );
  }

  void _onState(RecordState state) {
    switch (state) {
      case RecordState.pause:
        _paused = true;
        if (!_userPaused) _interrupted.add(true);
      case RecordState.record:
        // The plugin's engine only runs with the audio session ours again,
        // whether or not iOS said the interruption was over.
        _sessionInterrupted = false;
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
        if (_restartable == null) {
          _endedOnItsOwn(CaptureEnd.stopped);
        } else {
          unawaited(_confirmStopped());
        }
    }
  }

  /// iOS, MP3 and WAV: the plugin also reports a stop while it starts a new
  /// stream (see [_restartStream]), and such events can come late; only a
  /// capture the plugin no longer runs counts as lost.
  Future<void> _confirmStopped() async {
    if (_recovery != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!_running || _stopping || _endedSent || _recovery != null) return;
    if (!await _platformRecording()) _captureLost();
  }

  /// Whether the plugin still runs a capture (paused or not).
  Future<bool> _platformRecording() async {
    try {
      return await _recorder.isRecording();
    } catch (_) {
      return false;
    }
  }

  /// iOS: the audio session's interruptions (calls, Siri, alarms).
  ///
  /// M4A: a call pauses the platform's recorder without the plugin reporting
  /// it (it only reports its own pauses), so they are followed here: the
  /// timer stops with the sound.
  ///
  /// MP3 and WAV: the plugin pauses and resumes the capture itself, but it
  /// doesn't resume without the system's "should resume", and the capture
  /// it resumes may stay silent. Once an interruption is over, audio must
  /// be arriving again soon; if it isn't, the capture is started again.
  Future<void> _watchInterruptions() async {
    final Stream<AudioInterruptionEvent> events;
    try {
      events =
          _sessionInterruptions ??
          (await AudioSession.instance).interruptionEventStream;
    } catch (e) {
      // Without them, only the stall check notices a capture that wasn't
      // resumed.
      debugPrint('No audio session interruptions: $e');
      return;
    }
    await _sessionSub?.cancel();
    _sessionSub = events.listen((e) {
      if (!_running || _stopping) return;
      if (_restartable != null) {
        _sessionInterrupted = e.begin;
        _resumeTimer?.cancel();
        _resumeTimer = null;
        if (e.begin) return;
        final chunks = _chunks;
        _resumeTimer = Timer(_resumeCheck, () {
          _resumeTimer = null;
          if (!_running || _stopping || _endedSent) return;
          if (_userPaused || _sessionInterrupted || _recovery != null) return;
          // Not resumed, or resumed without a sound since.
          if (_paused || _chunks == chunks) _captureLost();
        });
        return;
      }
      if (e.begin) {
        _paused = true;
        if (!_userPaused) _interrupted.add(true);
      } else if (e.type == AudioInterruptionType.pause) {
        // Over, and to be resumed: the plugin resumes the recorder without
        // reporting it either (its state never left "recording", and it
        // only reports changes), so it is reported here.
        if (_userPaused) {
          // Paused by the user meanwhile: pause it again once it has.
          Timer(const Duration(milliseconds: 500), () {
            if (_running && !_stopping && _userPaused) {
              unawaited(_pauseQuietly());
            }
          });
        } else {
          _paused = false;
          _interrupted.add(false);
        }
      }
    });
  }

  /// iOS, MP3 and WAV: a route change (headphones, a car, the input's
  /// format) can stop the plugin's audio engine without it noticing, and a
  /// reset of the media services always does. Rather than wait for the
  /// stall check, audio must be arriving soon after such a change.
  Future<void> _watchRoutes() async {
    final Stream<void> routes, resets;
    try {
      if (_routeChanges != null && _mediaResets != null) {
        routes = _routeChanges;
        resets = _mediaResets;
      } else {
        final session = AVAudioSession();
        routes = _routeChanges ?? session.routeChangeStream;
        resets = _mediaResets ?? session.mediaServicesWereResetStream;
      }
    } catch (e) {
      debugPrint('No route changes: $e'); // the stall check still applies
      return;
    }
    await _routeSub?.cancel();
    await _resetSub?.cancel();
    void check() {
      // The plugin's own restarts change the route too; audio flows again
      // right after those.
      _routeTimer?.cancel();
      final chunks = _chunks;
      _routeTimer = Timer(_routeCheck, () {
        _routeTimer = null;
        if (!_running || _stopping || _endedSent) return;
        if (_paused || _userPaused || _sessionInterrupted) return;
        if (_recovery != null) return;
        if (_chunks == chunks) _captureLost();
      });
    }

    _routeSub = routes.listen((_) {
      if (_running && !_stopping) check();
    });
    _resetSub = resets.listen((_) {
      if (_running && !_stopping) check();
    });
  }

  void _cancelChecks() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _routeTimer?.cancel();
    _routeTimer = null;
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
    if (_restartable != null) {
      debugPrint('Capture failed: $e');
      _captureLost();
      return;
    }
    _writeError ??= e;
    _endedOnItsOwn(CaptureEnd.stopped);
  }

  /// Audio stopped arriving, or the platform stopped capturing, without the
  /// user stopping: the capture is started again where that can be done,
  /// otherwise the recording ends.
  void _captureLost() {
    if (!_running || _stopping || _endedSent) return;
    if (_restartable == null) {
      _endedOnItsOwn(CaptureEnd.stopped);
      return;
    }
    // Paused by the user: started again when they resume (see [resume]).
    if (_userPaused) return;
    if (_resuming) {
      _lostWhileResuming = true;
      return;
    }
    if (_recovery != null) return;
    late final Future<void> recovery;
    recovery = _recover().whenComplete(() {
      if (identical(_recovery, recovery)) _recovery = null;
    });
    _recovery = recovery;
  }

  /// Starts the capture again into the same file, a few times if need be.
  /// The timer stands still meanwhile (it counts as an interruption). An
  /// interruption still going on (a call) is waited out: its end tries
  /// again; so is the user's pause: their resume does. In the background, a
  /// capture that can't be started stays paused: opening the app resumes it
  /// (AppController.onResume). Only in the foreground does the recording
  /// end.
  Future<void> _recover() async {
    if (_restarts >= _maxRestarts) {
      _endedOnItsOwn(CaptureEnd.stopped);
      return;
    }
    _paused = true;
    if (!_userPaused) _interrupted.add(true);
    for (final wait in [Duration.zero, ..._restartDelays]) {
      if (wait > Duration.zero) {
        await Future.any([Future<void>.delayed(wait), _stopSignal.future]);
      }
      if (!_running || _stopping || _endedSent) return;
      if (_sessionInterrupted || _userPaused) return;
      try {
        await _restartStream();
        _restarts++;
        return;
      } catch (e) {
        debugPrint('Could not start the capture again: $e');
      }
    }
    if (_sessionInterrupted || _userPaused || !_inForeground()) return;
    _endedOnItsOwn(CaptureEnd.stopped);
  }

  /// A restart outside [_recover] ([resume]), run as the [_recovery].
  Future<void> _restartNow() {
    final restart = _restartStream();
    late final Future<void> recovery;
    recovery = restart
        .then<void>((_) => _restarts++, onError: (Object _) {})
        .whenComplete(() {
          if (identical(_recovery, recovery)) _recovery = null;
        });
    _recovery = recovery;
    return restart;
  }

  /// Replaces the platform stream with a new one (the plugin stops the old
  /// capture first), written into the same file.
  Future<void> _restartStream() async {
    if (!_running || _stopping) throw StateError('Recording stopped');
    await _pcmSub?.cancel();
    _pcmSub = null;
    // Nothing more comes from the old stream: [stop] needn't wait for it.
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete();
    final stream = await _recorder.startStream(_restartable!);
    if (!_running || _stopping || _sampleRate != _writerRate) {
      // Stopped meanwhile, or (it shouldn't happen: the plugin converts to
      // the rate asked for) a rate the file isn't written at, which would
      // play too fast or too slow: no capture may go on.
      try {
        await _recorder.stop();
      } catch (_) {}
      throw StateError(
        _sampleRate != _writerRate
            ? 'Capture restarted at $_sampleRate Hz'
            : 'Recording stopped',
      );
    }
    // A capture only starts with the audio session ours again.
    _sessionInterrupted = false;
    _listen(stream);
    if (_userPaused) {
      // Paused by the user meanwhile: keep it paused.
      await _pauseQuietly();
    } else {
      _paused = false;
      _interrupted.add(false);
    }
  }

  void _endedOnItsOwn(CaptureEnd why) {
    if (!_running || _stopping || _endedSent) return;
    _endedSent = true;
    _watchdog?.cancel();
    _cancelChecks();
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
    // A restart under way is the resume (if it gets the capture going).
    final pending = _recovery;
    if (pending != null) {
      await pending;
      if (!_running || _stopping || _endedSent) return;
      if (!_paused || _userPaused || _recovery != null) return;
    }
    if (_restartable == null) {
      try {
        await _recorder.resume();
      } catch (e) {
        _userPaused = wasUserPaused;
        rethrow;
      }
      _sinceChunk.reset();
      return;
    }
    // iOS, MP3 and WAV: the capture may have died while paused (a call that
    // changed the input meanwhile, or a restart iOS refused in the
    // background); a new one goes on instead.
    _resuming = true;
    _lostWhileResuming = false;
    try {
      if (!await _platformRecording()) {
        await _restartNow();
      } else {
        try {
          await _recorder.resume();
          // The state event may come later.
          _sinceChunk.reset();
        } catch (e) {
          // A call that still has the audio session refuses it: its end
          // resumes the capture.
          if (_sessionInterrupted) rethrow;
          await _restartNow();
        }
      }
    } catch (e) {
      // Stopped meanwhile: there's nothing to resume.
      if (!_running || _stopping) return;
      if (wasUserPaused) {
        _userPaused = true;
      } else if (!_sessionInterrupted) {
        // Resumed by the app (AppController.onResume) after the system
        // broke the capture: it goes on being tried like any lost capture,
        // and in the foreground the recording ends if that keeps failing.
        _lostWhileResuming = true;
      }
      rethrow;
    } finally {
      _resuming = false;
      if (_lostWhileResuming) {
        _lostWhileResuming = false;
        unawaited(_confirmStopped());
      }
    }
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _watchdog?.cancel();
    _watchdog = null;
    _cancelChecks();
    await _sessionSub?.cancel();
    _sessionSub = null;
    await _routeSub?.cancel();
    _routeSub = null;
    await _resetSub?.cancel();
    _resetSub = null;
    // A capture being started again must not outlive the recording.
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    await _recovery;
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
        _restartable = null;
        _sessionInterrupted = false;
        _sinceChunk
          ..stop()
          ..reset();
      }
    }
    error ??= _writeError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    _watchdog?.cancel();
    _cancelChecks();
    await _sessionSub?.cancel();
    await _routeSub?.cancel();
    await _resetSub?.cancel();
    await _stateSub?.cancel();
    await _pcmSub?.cancel();
    await _ampSub?.cancel();
    await _recorder.dispose();
    await _levels.close();
    await _interrupted.close();
    await _ended.close();
  }
}
