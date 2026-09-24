import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'audio/playback.dart';
import 'audio/recorder_engine.dart';
import 'audio/wav_writer.dart';
import 'core/format.dart';
import 'core/recording_file.dart';
import 'core/settings.dart';
import 'platform/native_bridge.dart';
import 'storage/recording_store.dart';

enum RecordOutcome { started, stopped, noPermission, needsFolder, failed }

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
    await store.init();
    final last = settings.lastFile;
    if (last != null) {
      final cur = _current = await _safe<RecordingFile?>(
        () => store.find(last),
      );
      if (cur == null) {
        settings.setLast(null, Duration.zero);
      } else if (cur.id != last) {
        settings.setLast(cur.id, settings.lastDuration);
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
    final free = await _safe(store.freeBytes);
    _remaining = free == null ? null : settings.profile.remainingFor(free);
    notifyListeners();
  }

  Future<void> refreshFiles() async {
    final list = await _safe(store.list) ?? const <RecordingFile>[];
    _files = [...list]..sort((a, b) => b.modified.compareTo(a.modified));
    notifyListeners();
  }

  /// Saves recordings left in the work directory by a crash or a kill.
  Future<void> recoverInterrupted() async {
    if (!store.isReady) return;
    final dir = Directory('${(await workDir()).path}/pending');
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      try {
        if (await e.length() == 0) {
          await e.delete();
          continue;
        }
        if (name.toLowerCase().endsWith('.wav')) {
          await WavWriter.repair(e, sampleRate: await _wavRate(e));
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
    if (_busy) return RecordOutcome.failed;
    return _recording ? _stop() : _start();
  }

  Future<RecordOutcome> _start() async {
    _busy = true;
    notifyListeners();
    try {
      if (playback.fileId != null) await playback.stop();
      if (!await engine.requestPermission()) return RecordOutcome.noPermission;
      if (!store.isReady) return RecordOutcome.needsFolder;

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
        paused ? _stopwatch.stop() : _stopwatch.start();
        notifyListeners();
      });
      _ticker = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => notifyListeners(),
      );
      _spaceTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => refreshRemaining(),
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
    }
    await _levelSub?.cancel();
    await _interruptSub?.cancel();
    if (isAndroid) await _safe(native.stopRecordingService);
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
      // The file stays in the work directory and is saved on next launch.
      debugPrint('Could not save recording: $e');
      return RecordOutcome.failed;
    } finally {
      _pendingFile = null;
      _pendingName = null;
      _busy = false;
      unawaited(refreshRemaining());
      unawaited(refreshFiles());
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- playback
  Future<void> togglePlayCurrent() async {
    final cur = _current;
    if (cur == null || _recording) return;
    await togglePlay(cur);
  }

  Future<void> togglePlay(RecordingFile file) async {
    if (_recording) return;
    if (playback.isPlaying(file.id)) {
      await playback.pause();
    } else {
      await playback.play(file.id, store.playbackUri(file));
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

  Future<bool> chooseFolder() async {
    final ok = await _safe(store.chooseFolder) ?? false;
    if (ok) {
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
    settings.removeListener(_onSettingsChanged);
    store.removeListener(notifyListeners);
    playback.removeListener(notifyListeners);
    super.dispose();
  }
}
