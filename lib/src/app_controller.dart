import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'audio/m4a.dart';
import 'audio/playback.dart';
import 'audio/recorder_engine.dart';
import 'audio/wav_writer.dart';
import 'core/format.dart';
import 'core/recording_file.dart';
import 'core/settings.dart';
import 'platform/native_bridge.dart';
import 'storage/recording_store.dart';

enum RecordOutcome {
  started,
  stopped,
  noPermission,
  needsFolder,

  /// Recorded, but the file couldn't be moved into the folder. It stays in
  /// the app and is saved by [AppController.recoverInterrupted] later.
  notSaved,
  failed,

  /// Too little storage left to record.
  noSpace,

  /// A start or stop is already in progress; the tap is ignored.
  busy,
}

/// Recordings stop automatically when less than this much time is left, so
/// the file can still be saved.
const minRecordingSpace = Duration(seconds: 30);

/// State and actions behind the three screens.
class AppController extends ChangeNotifier {
  AppController({
    required this.settings,
    required this.store,
    required this.engine,
    required this.playback,
    required this.native,
    required this.workDir,
    this.isAndroid = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    settings.addListener(_onSettingsChanged);
    store.addListener(notifyListeners);
    playback.addListener(notifyListeners);
  }

  final Settings settings;
  final RecordingStore store;
  final RecorderEngine engine;
  final Playback playback;
  final NativeBridge native;

  /// Private app directory for recordings in progress.
  final Future<Directory> Function() workDir;
  final bool isAndroid;
  final DateTime Function() _clock;

  // ------------------------------------------------------------ state
  bool _recording = false;
  bool _interrupted = false;
  bool _busy = false;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  Timer? _spaceTimer;
  double _level = 0;
  RecordingFile? _current;
  String? _pendingName;
  File? _pendingFile;
  Duration? _remaining;
  List<RecordingFile> _files = const [];
  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _interruptSub;
  StreamSubscription<void>? _endedSub;
  late final StreamController<String> _notices = StreamController.broadcast(
    onListen: () {
      // Messages from before the screen was listening (e.g. during init).
      for (final m in _unheard) {
        _notices.add(m);
      }
      _unheard.clear();
    },
  );
  final _unheard = <String>[];

  /// Short messages for the user about things that happened on their own
  /// (a recording stopped automatically, a recording couldn't be recovered).
  Stream<String> get notices => _notices.stream;

  void _notify(String message) {
    if (_notices.hasListener) {
      _notices.add(message);
    } else {
      _unheard.add(message);
    }
  }

  bool get isRecording => _recording;
  bool get isInterrupted => _interrupted;
  bool get isBusy => _busy;

  /// Input level (0..1) while recording.
  double get level => _recording ? _level : 0;

  /// Number of lit level-meter squares (at least one, like the original).
  int get litSegments => 1 + (level * 9).round().clamp(0, 9);

  /// Recording shown at the bottom of the Recorder screen.
  RecordingFile? get currentFile => _current;

  /// Text in the timer box.
  Duration get timerValue {
    if (_recording) return _stopwatch.elapsed;
    final cur = _current;
    if (cur != null &&
        playback.fileId == cur.id &&
        (playback.playing || playback.position > Duration.zero)) {
      return playback.position;
    }
    return cur == null ? Duration.zero : settings.lastDuration;
  }

  bool get isPlayingCurrent =>
      _current != null && playback.isPlaying(_current!.id);

  Duration? get remaining => _remaining;

  /// Path shown next to the floppy icon.
  String? get currentPath {
    if (_recording && _pendingName != null) {
      return '${store.folderDisplayPath}/$_pendingName';
    }
    final cur = _current;
    return cur == null ? null : store.displayPath(cur);
  }

  /// Recordings, newest first.
  List<RecordingFile> get files => _files;

  // ------------------------------------------------------------- setup
  Future<void> init() async {
    await _safe(store.init);
    final last = settings.lastFile;
    if (last != null) {
      try {
        final cur = _current = await store.find(last);
        if (cur == null) {
          settings.setLast(null, Duration.zero);
        } else if (cur.id != last) {
          settings.setLast(cur.id, settings.lastDuration);
        }
      } catch (e) {
        // Storage not reachable right now: only forget the recording once it
        // is known to be gone.
        debugPrint('Could not look up the last recording: $e');
      }
    }
    await recoverInterrupted();
    await refreshRemaining();
    notifyListeners();
  }

  void _onSettingsChanged() {
    unawaited(refreshRemaining());
    notifyListeners();
  }

  Future<void> refreshRemaining() async {
    final pending = _recording ? await _safe(_pendingFile!.length) ?? 0 : 0;
    final usable = await _safe(() => store.usableBytes(pendingBytes: pending));
    _remaining = usable == null ? null : settings.profile.remainingFor(usable);
    notifyListeners();
  }

  Future<void> refreshFiles() async {
    final list = await _safe(store.list) ?? const <RecordingFile>[];
    _files = [...list]
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : a.name.compareTo(b.name);
      });
    notifyListeners();
  }

  /// Re-checks what may have changed while the app was in the background:
  /// the last recording may have been deleted or changed, free space too.
  Future<void> onResume() async {
    // iOS: an interruption that ended without "should resume" (e.g. another
    // app took the audio session) leaves the recording paused until now.
    if (_recording && _interrupted) await _safe(engine.resume);
    await _recheckCurrent();
    await refreshRemaining();
  }

  /// Forgets the Recorder screen's recording if it no longer exists.
  Future<void> _recheckCurrent() async {
    final cur = _current;
    if (cur == null || _recording) return;
    try {
      final found = await store.find(cur.id);
      if (_current?.id != cur.id) return;
      if (found == null) {
        if (playback.fileId == cur.id) await playback.stop();
        _current = null;
        settings.setLast(null, Duration.zero);
      } else {
        _current = found;
      }
      notifyListeners();
    } catch (e) {
      // Storage not reachable right now: keep showing the file.
      debugPrint('Could not re-check ${cur.name}: $e');
    }
  }

  /// Saves recordings left in the work directory by a crash or a kill.
  Future<void> recoverInterrupted() async {
    // Never touch the file of a recording that is still running.
    if (!store.isReady || _recording) return;
    final dir = Directory('${(await workDir()).path}/pending');
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      final lower = name.toLowerCase();
      if (!isAudioFileName(name)) continue; // e.g. an unrecoverable .m4a
      try {
        final length = await e.length();
        // Nothing was recorded (a WAV header alone is 44 bytes).
        if (length == 0 || (lower.endsWith('.wav') && length <= 44)) {
          await e.delete();
          continue;
        }
        if (lower.endsWith('.wav')) {
          await WavWriter.repair(e, sampleRate: await _wavRate(e));
        }
        if (lower.endsWith('.m4a') && !await hasMp4Index(e)) {
          // An M4A is only playable once finalized; this one never was.
          // Keep it out of the folder (and out of later recoveries).
          await e.rename('${e.path}.incomplete');
          _notify(
            "An M4A recording that was cut off couldn't be recovered. "
            'MP3 and WAV recordings can always be recovered.',
          );
          continue;
        }
        final saved = await store.save(
          e,
          name,
          RecordingStore.mimeTypeFor(name),
        );
        _current ??= saved;
      } catch (err) {
        debugPrint('Could not recover $name: $err');
      }
    }
  }

  Future<int> _wavRate(File f) async {
    final raf = await f.open();
    try {
      final h = await raf.read(28);
      if (h.length < 28) return 44100;
      return h[24] | (h[25] << 8) | (h[26] << 16) | (h[27] << 24);
    } finally {
      await raf.close();
    }
  }

  // --------------------------------------------------------- recording
  /// Starts or stops a recording.
  Future<RecordOutcome> toggleRecord() async {
    if (_busy) return RecordOutcome.busy;
    return _recording ? _stop() : _start();
  }

  Future<RecordOutcome> _start() async {
    _busy = true;
    notifyListeners();
    try {
      if (playback.fileId != null) await playback.stop();
      if (!await engine.requestPermission()) return RecordOutcome.noPermission;
      if (!store.isReady) return RecordOutcome.needsFolder;
      await refreshRemaining();
      final left = _remaining;
      if (left != null && left < minRecordingSpace) {
        return RecordOutcome.noSpace;
      }

      final profile = settings.profile;
      final name = '${timestampName(_clock())}.${profile.type.extension}';
      final dir = Directory('${(await workDir()).path}/pending');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');

      if (isAndroid) {
        await native.startRecordingService(
          title: 'Voice Recorder',
          text: 'Recording $name',
        );
      }
      try {
        await engine.start(profile, file.path);
      } catch (e) {
        if (isAndroid) await _safe(native.stopRecordingService);
        rethrow;
      }

      _pendingName = name;
      _pendingFile = file;
      _recording = true;
      _interrupted = false;
      _level = 0;
      _stopwatch
        ..reset()
        ..start();
      _levelSub = engine.levels.listen((l) {
        _level = l;
        notifyListeners();
      });
      _interruptSub = engine.interrupted.listen((paused) {
        _interrupted = paused;
        if (paused) _level = 0;
        paused ? _stopwatch.stop() : _stopwatch.start();
        notifyListeners();
      });
      _endedSub = engine.ended.listen(
        (_) => _stopOnItsOwn('The recording stopped unexpectedly.'),
      );
      _ticker = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => notifyListeners(),
      );
      _spaceTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _checkSpace(),
      );
      return RecordOutcome.started;
    } catch (e) {
      debugPrint('Could not start recording: $e');
      return RecordOutcome.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<RecordOutcome> _stop() async {
    _busy = true;
    _ticker?.cancel();
    _spaceTimer?.cancel();
    _stopwatch.stop();
    notifyListeners();
    final duration = _stopwatch.elapsed;
    final file = _pendingFile!;
    final name = _pendingName!;
    try {
      await engine.stop();
    } catch (e) {
      debugPrint('Recorder reported an error while stopping: $e');
      // The header may not have been finalized.
      if (name.toLowerCase().endsWith('.wav')) {
        await _safe(
          () async => WavWriter.repair(file, sampleRate: await _wavRate(file)),
        );
      }
    }
    if (!isAndroid) unawaited(_safe(native.resetAudioSampleRate));
    await _levelSub?.cancel();
    await _interruptSub?.cancel();
    await _endedSub?.cancel();
    _endedSub = null;
    _recording = false;
    _interrupted = false;
    _level = 0;
    try {
      final saved = await store.save(
        file,
        name,
        RecordingStore.mimeTypeFor(name),
      );
      _current = saved;
      settings.setLast(saved.id, duration);
      return RecordOutcome.stopped;
    } catch (e) {
      // The file stays in the work directory and is saved on next launch or
      // when a folder is chosen again. Folder access may have been lost
      // (Android), so re-check it; the UI then asks for the folder.
      debugPrint('Could not save recording: $e');
      await _safe(store.init);
      return RecordOutcome.notSaved;
    } finally {
      // Only now: the service keeps the process alive while the file is
      // copied into the folder.
      if (isAndroid) await _safe(native.stopRecordingService);
      _pendingFile = null;
      _pendingName = null;
      _busy = false;
      unawaited(refreshRemaining());
      unawaited(refreshFiles());
      notifyListeners();
    }
  }

  /// Stops a recording that can't go on, saving what was recorded.
  Future<void> _stopOnItsOwn(String reason) async {
    if (!_recording || _busy) return;
    final outcome = await _stop();
    _notify(switch (outcome) {
      RecordOutcome.stopped => '$reason What was recorded has been saved.',
      _ =>
        "$reason It couldn't be saved to the folder yet; it will be saved "
            'when the folder is available.',
    });
  }

  @visibleForTesting
  Future<void> checkSpace() => _checkSpace();

  Future<void> _checkSpace() async {
    await refreshRemaining();
    final left = _remaining;
    if (_recording && left != null && left < minRecordingSpace) {
      await _stopOnItsOwn('Storage is almost full, so the recording stopped.');
    }
  }

  // ---------------------------------------------------------- playback
  /// Plays or pauses the recording shown on the Recorder screen. Returns
  /// false if it couldn't be played.
  Future<bool> togglePlayCurrent() async {
    final cur = _current;
    if (cur == null) return false;
    return togglePlay(cur);
  }

  /// Plays or pauses [file]. Returns false if it couldn't be played (or a
  /// recording is running).
  Future<bool> togglePlay(RecordingFile file) async {
    if (_recording) return false;
    try {
      if (playback.isPlaying(file.id)) {
        await playback.pause();
      } else {
        await playback.play(file.id, store.playbackUri(file));
      }
      return true;
    } catch (e) {
      debugPrint('Could not play ${file.name}: $e');
      return false;
    }
  }

  /// Moves [file]'s playback to [fraction] of its length. If it isn't loaded
  /// yet it is loaded paused. Returns false if it couldn't be opened.
  Future<bool> seek(RecordingFile file, double fraction) async {
    if (_recording) return false;
    try {
      await playback.load(file.id, store.playbackUri(file));
      await playback.seek(playback.duration * fraction.clamp(0.0, 1.0));
      return true;
    } catch (e) {
      debugPrint('Could not seek in ${file.name}: $e');
      return false;
    }
  }

  // ------------------------------------------------------ file actions
  String displayPathOf(RecordingFile f) => store.displayPath(f);

  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) async {
    final clean = sanitizeFileName(newBaseName);
    if (clean.isEmpty || clean == file.baseName) return file;
    if (playback.fileId == file.id) await playback.stop();
    final renamed = await _safe(() => store.rename(file, clean));
    if (renamed == null) return null;
    if (_current?.id == file.id) {
      _current = renamed;
      settings.setLast(renamed.id, settings.lastDuration);
    }
    _files = [for (final f in _files) f.id == file.id ? renamed : f];
    notifyListeners();
    return renamed;
  }

  Future<bool> delete(RecordingFile file) async {
    if (playback.fileId == file.id) await playback.stop();
    final ok = await _safe(() => store.delete(file)) ?? false;
    if (!ok) return false;
    if (_current?.id == file.id) {
      _current = null;
      settings.setLast(null, Duration.zero);
    }
    _files = [
      for (final f in _files)
        if (f.id != file.id) f,
    ];
    unawaited(refreshRemaining());
    notifyListeners();
    return true;
  }

  Future<void> share(RecordingFile file, {Rect? origin}) async {
    await _safe(() => store.share(file, origin: origin));
  }

  /// Opens this app's page in the system settings.
  Future<void> openAppSettings() async {
    await _safe(native.openAppSettings);
  }

  Future<bool> chooseFolder() async {
    final ok = await _safe(store.chooseFolder) ?? false;
    if (ok) {
      await _recheckCurrent();
      await recoverInterrupted();
      await refreshFiles();
      await refreshRemaining();
    }
    return ok;
  }

  Future<T?> _safe<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      debugPrint('Voice Recorder: $e');
      return null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _spaceTimer?.cancel();
    _levelSub?.cancel();
    _interruptSub?.cancel();
    _endedSub?.cancel();
    _notices.close();
    settings.removeListener(_onSettingsChanged);
    store.removeListener(notifyListeners);
    playback.removeListener(notifyListeners);
    super.dispose();
  }
}
