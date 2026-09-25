import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'audio/duration.dart';
import 'audio/m4a.dart';
import 'audio/playback.dart';
import 'audio/recorder_engine.dart';
import 'audio/wav_writer.dart';
import 'core/format.dart';
import 'core/recording_file.dart';
import 'core/recording_format.dart';
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

/// What happened when the user pressed play.
enum PlayOutcome {
  /// Playing (or paused, if it was playing).
  ok,

  /// The file couldn't be opened (deleted, unreadable) or a recording runs.
  notPlayable,

  /// The system refused audio playback right now (e.g. during a call).
  audioBusy,

  /// A recording is running or starting.
  recording,
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
  StreamSubscription<CaptureEnd>? _endedSub;

  /// The format of the recording in progress (Settings may change meanwhile).
  RecordingProfile? _activeProfile;

  /// A recording that couldn't be saved into the folder yet; it becomes the
  /// Recorder screen's recording once recovery saves it.
  ({String name, Duration duration})? _unsaved;

  /// Completes when [init] has finished.
  Future<void>? _initDone;
  // Messages wait until the screen listens (they can come during init) and
  // the app is in the foreground (an automatic stop usually happens with the
  // screen off; a toast then would vanish unseen).
  late final StreamController<String> _notices = StreamController.broadcast(
    onListen: _flushNotices,
  );
  final _unheard = <String>[];
  bool _inForeground = true;

  /// Called by the app as it goes to the background and comes back.
  void setForeground(bool value) {
    _inForeground = value;
    _flushNotices();
  }

  void _flushNotices() {
    if (!_inForeground || !_notices.hasListener) return;
    for (final m in _unheard) {
      _notices.add(m);
    }
    _unheard.clear();
  }

  /// Short messages for the user about things that happened on their own
  /// (a recording stopped automatically, a recording couldn't be recovered).
  Stream<String> get notices => _notices.stream;

  void _notify(String message) {
    _unheard.add(message);
    _flushNotices();
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
  /// Loads the folder, the last recording and recovers cut-off recordings.
  /// Record, list and folder actions wait for it.
  Future<void> init() => _initDone ??= _init();

  Future<void> _ready() async => _initDone;

  Future<void> _init() async {
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
    final profile = (_recording ? _activeProfile : null) ?? settings.profile;
    _remaining = usable == null ? null : profile.remainingFor(usable);
    notifyListeners();
  }

  Future<void> refreshFiles() async {
    await _ready();
    final list = await _safe(store.list) ?? const <RecordingFile>[];
    _files = _sorted(list);
    notifyListeners();
  }

  /// Newest first.
  static List<RecordingFile> _sorted(Iterable<RecordingFile> files) =>
      [...files]..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : a.name.compareTo(b.name);
      });

  /// Re-checks what may have changed while the app was in the background:
  /// the last recording may have been deleted or changed, free space too.
  Future<void> onResume() async {
    // iOS: an interruption that ended without "should resume" (e.g. another
    // app took the audio session) leaves the recording paused until now.
    if (_recording && _interrupted) {
      try {
        await engine.resume();
      } catch (e) {
        debugPrint('Could not resume recording: $e');
        await _stopOnItsOwn(
          "The recording couldn't continue after the interruption.",
        );
      }
    }
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
      if (lower.endsWith('.incomplete')) {
        // Unplayable M4A files kept aside; drop them after a week.
        final age = DateTime.now().difference(await e.lastModified());
        if (age > const Duration(days: 7)) await _safe(e.delete);
        continue;
      }
      if (!isAudioFileName(name)) continue;
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
        final unsaved = _unsaved?.name == name ? _unsaved : null;
        final playTime = unsaved?.duration ?? await audioDuration(e);
        final saved = await store.save(
          e,
          name,
          RecordingStore.mimeTypeFor(name),
        );
        // The newest recording belongs on the Recorder screen.
        final cur = _current;
        if (unsaved != null || cur == null || saved.date.isAfter(cur.date)) {
          _current = saved;
          settings.setLast(saved.id, playTime ?? Duration.zero);
        }
        if (unsaved != null) _unsaved = null;
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
    await _ready();
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
        // Playback may have been started while this was starting up.
        if (playback.fileId != null) await playback.stop();
        await engine.start(profile, file.path);
      } catch (e) {
        if (isAndroid) await _safe(native.stopRecordingService);
        rethrow;
      }

      _pendingName = name;
      _pendingFile = file;
      _activeProfile = profile;
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
        (why) => _stopOnItsOwn(switch (why) {
          CaptureEnd.stopped => 'The recording stopped unexpectedly.',
          CaptureEnd.writeFailed =>
            "The recording stopped because it couldn't be written (is the "
                'storage full?).',
          CaptureEnd.sizeLimit =>
            'A WAV recording can be about 13 hours long at most, so it '
                'stopped.',
        }),
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
      // iOS: the recorder may already have set its sample rate on the audio
      // session, which would make later playback sound muffled.
      if (!isAndroid) await _safe(native.resetAudioSampleRate);
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
    if (!isAndroid) await _safe(native.resetAudioSampleRate);
    await _levelSub?.cancel();
    await _interruptSub?.cancel();
    await _endedSub?.cancel();
    _endedSub = null;
    _recording = false;
    _interrupted = false;
    _level = 0;
    try {
      if (!await file.exists()) return RecordOutcome.failed;
      if (name.toLowerCase().endsWith('.m4a') && !await hasMp4Index(file)) {
        // The recorder failed to finish it, so it can't be played.
        await file.rename('${file.path}.incomplete');
        return RecordOutcome.failed;
      }
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
      _unsaved = (name: name, duration: duration);
      await _safe(store.init);
      return RecordOutcome.notSaved;
    } finally {
      // Only now: the service keeps the process alive while the file is
      // copied into the folder.
      if (isAndroid) await _safe(native.stopRecordingService);
      _pendingFile = null;
      _pendingName = null;
      _activeProfile = null;
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
  /// Plays or pauses the recording shown on the Recorder screen.
  Future<PlayOutcome> togglePlayCurrent() async {
    final cur = _current;
    if (cur == null) return PlayOutcome.notPlayable;
    return togglePlay(cur);
  }

  /// Plays or pauses [file].
  Future<PlayOutcome> togglePlay(RecordingFile file) async {
    if (_recording || _busy) return PlayOutcome.recording;
    try {
      if (playback.isPlaying(file.id)) {
        await playback.pause();
      } else {
        await playback.play(file.id, store.playbackUri(file));
      }
      return PlayOutcome.ok;
    } on AudioBusyException {
      return PlayOutcome.audioBusy;
    } catch (e) {
      debugPrint('Could not play ${file.name}: $e');
      return PlayOutcome.notPlayable;
    }
  }

  /// Moves [file]'s playback to [fraction] of its length. If it isn't loaded
  /// yet it is loaded paused. Returns false if it couldn't be opened.
  Future<bool> seek(RecordingFile file, double fraction) async {
    if (_recording || _busy) return false;
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
    _files = _sorted([for (final f in _files) f.id == file.id ? renamed : f]);
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
    await _ready();
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

  bool _disposed = false;

  /// Background work (a refresh, a save) may finish after [dispose].
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
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
