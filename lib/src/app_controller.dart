import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'audio/audio_info.dart';
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
import 'storage/info_cache.dart';
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

/// How far the skip buttons jump.
const skipInterval = Duration(seconds: 10);

/// Recordings one delete moved to Recently deleted, so it can be undone.
class DeletedRecordings {
  const DeletedRecordings(this.items, {this.failed = 0, this.current});

  final List<TrashedRecording> items;

  /// How many couldn't be deleted.
  final int failed;

  /// The Recorder screen's recording was among them: its name and length.
  final ({String name, Duration duration})? current;
}

/// State and actions behind the screens.
class AppController extends ChangeNotifier {
  AppController({
    required this.settings,
    required this.store,
    required this.engine,
    required this.playback,
    required this.native,
    required this.workDir,
    this.isAndroid = false,
    RecordingInfoCache? info,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _info = info ?? RecordingInfoCache(),
       _sortOrder = settings.sortOrder,
       _speed = settings.playbackSpeed,
       _lockScreen = settings.lockScreenControls {
    settings.addListener(_onSettingsChanged);
    store.addListener(notifyListeners);
    playback.addListener(_onPlaybackChanged);
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
  final RecordingInfoCache _info;

  // ------------------------------------------------------------ state
  bool _recording = false;

  /// Paused by the user.
  bool _paused = false;

  /// Paused by the system (iOS: a call).
  bool _interrupted = false;
  bool _busy = false;
  bool _pausing = false;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  Timer? _spaceTimer;
  double _level = 0;
  RecordingFile? _current;
  String? _pendingName;
  File? _pendingFile;
  DateTime? _startedAt;
  Duration? _remaining;
  List<RecordingFile> _files = const [];
  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _interruptSub;
  StreamSubscription<CaptureEnd>? _endedSub;
  StreamSubscription<NativeEvent>? _nativeSub;

  /// The format of the recording in progress (Settings may change meanwhile).
  RecordingProfile? _activeProfile;

  /// A recording that couldn't be saved into the folder yet; it becomes the
  /// Recorder screen's recording once recovery saves it.
  ({String name, Duration duration})? _unsaved;

  /// The recording loaded in the player.
  RecordingFile? _loaded;

  // Settings as last applied, to tell what changed.
  SortOrder _sortOrder;
  double _speed;
  bool _lockScreen;

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

  // Home-screen shortcuts, held until the Recorder screen listens.
  late final StreamController<String> _launches = StreamController.broadcast(
    onListen: _flushLaunches,
  );
  final _unhandledLaunches = <String>[];

  /// Called by the app as it goes to the background and comes back.
  void setForeground(bool value) {
    _inForeground = value;
    if (!value) {
      unawaited(_info.save());
      // Without lock-screen controls playback ends with the app (Android
      // would cut it off in the background anyway).
      if (!settings.lockScreenControls && playback.playing) {
        unawaited(_safe(playback.pause));
      }
    }
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

  /// What the app was opened for from a home-screen shortcut ("record").
  Stream<String> get launchActions => _launches.stream;

  void _flushLaunches() {
    if (!_launches.hasListener) return;
    for (final a in _unhandledLaunches) {
      _launches.add(a);
    }
    _unhandledLaunches.clear();
  }

  /// Picks up a shortcut the app was opened (or brought back) with.
  Future<void> checkLaunchAction() async {
    final action = await _safe(native.takeLaunchAction);
    if (action == null) return;
    _unhandledLaunches.add(action);
    _flushLaunches();
  }

  bool get isRecording => _recording;

  /// The user paused the recording.
  bool get isPaused => _paused;

  /// The system paused the recording (iOS: a call or Siri).
  bool get isInterrupted => _interrupted;
  bool get isBusy => _busy;

  /// Input level (0..1) while recording.
  double get level => _recording && !_paused && !_interrupted ? _level : 0;

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

  /// Recordings in the order chosen in the list (newest first by default).
  List<RecordingFile> get files => _files;

  // ------------------------------------------------------------- setup
  /// Loads the folder, the last recording and recovers cut-off recordings.
  /// Record, list and folder actions wait for it.
  Future<void> init() => _initDone ??= _init();

  Future<void> _ready() async => _initDone;

  Future<void> _init() async {
    _nativeSub = native.events.listen(
      (e) => unawaited(_onNativeEvent(e)),
      onError: (Object e) => debugPrint('Platform event error: $e'),
    );
    await _info.load();
    if (_speed != 1.0) await _safe(() => playback.setSpeed(_speed));
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
    unawaited(_purgeTrash());
    await checkLaunchAction();
    notifyListeners();
  }

  void _onSettingsChanged() {
    if (settings.sortOrder != _sortOrder) {
      _sortOrder = settings.sortOrder;
      _files = _sorted(_files);
    }
    if (settings.playbackSpeed != _speed) {
      _speed = settings.playbackSpeed;
      unawaited(_safe(() => playback.setSpeed(_speed)));
    }
    if (settings.lockScreenControls != _lockScreen) {
      _lockScreen = settings.lockScreenControls;
      _syncMedia();
    }
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
    final list = await _safe(store.list);
    if (list == null) {
      _files = const [];
      notifyListeners();
      return;
    }
    _info.retainOnly(list);
    _files = _sorted([for (final f in list) f.withInfo(_info[f])]);
    notifyListeners();
    // A renamed recording keeps its date inside: read those first, so the
    // list is in the right order.
    for (final f in _files.reversed) {
      if (parseTimestampName(f.baseName) == null) requestInfo(f);
    }
  }

  List<RecordingFile> _sorted(Iterable<RecordingFile> files) {
    int newest(RecordingFile a, RecordingFile b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : a.name.compareTo(b.name);
    }

    int byName(RecordingFile a, RecordingFile b) {
      final n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return n != 0 ? n : a.name.compareTo(b.name);
    }

    final Comparator<RecordingFile> order = switch (_sortOrder) {
      SortOrder.newest => newest,
      SortOrder.oldest => (a, b) => newest(b, a),
      SortOrder.nameAscending => byName,
      SortOrder.nameDescending => (a, b) => byName(b, a),
      SortOrder.largest => (a, b) {
        final bySize = b.size.compareTo(a.size);
        return bySize != 0 ? bySize : newest(a, b);
      },
    };
    return [...files]..sort(order);
  }

  // ------------------------------------------------ dates and lengths
  final _probeQueue = <String, RecordingFile>{};
  final _unreadable = <String>{};
  bool _probing = false;

  /// Reads [file]'s recording date and length in the background if they
  /// aren't known yet; the list shows them once they come in. The newest
  /// request is served first (the rows on screen).
  void requestInfo(RecordingFile file) {
    if (_info.contains(file) ||
        _unreadable.contains(RecordingInfoCache.keyOf(file))) {
      return;
    }
    _probeQueue
      ..remove(file.id)
      ..[file.id] = file;
    // Rows scrolled past long ago don't need reading any more.
    while (_probeQueue.length > 200) {
      _probeQueue.remove(_probeQueue.keys.first);
    }
    if (_probing) return;
    _probing = true;
    // Not right away: this is called while the list is being built.
    scheduleMicrotask(_probe);
  }

  Future<void> _probe() async {
    try {
      while (_probeQueue.isNotEmpty && !_disposed) {
        final id = _probeQueue.keys.last;
        final file = _probeQueue.remove(id)!;
        if (_info.contains(file)) continue;
        AudioInfo info;
        try {
          info = await _readInfo(file);
        } catch (e) {
          // Unreadable right now (deleted, storage gone): not again this run.
          _unreadable.add(RecordingInfoCache.keyOf(file));
          continue;
        }
        _info.put(file, info);
        _applyInfo(file, info);
      }
    } finally {
      _probing = false;
    }
  }

  Future<AudioInfo> _readInfo(RecordingFile file) async {
    final a = await store.openBytes(file);
    try {
      return await readAudioInfo(a, file.name);
    } finally {
      await a.close();
    }
  }

  void _applyInfo(RecordingFile file, AudioInfo info) {
    final i = _files.indexWhere((f) => f.id == file.id);
    if (i < 0) return;
    final old = _files[i];
    final updated = old.withInfo(info);
    if (updated == old) return;
    final files = [..._files]..[i] = updated;
    _files = updated.date == old.date ? files : _sorted(files);
    // Rows that come in together are drawn in the same frame.
    notifyListeners();
  }

  /// Stores [recorded] inside the file [f] (a new recording's date).
  Future<void> _stamp(File f, String name, DateTime recorded) async {
    final a = await FileByteAccess.open(f, write: true);
    try {
      await writeRecordedDate(a, name, recorded);
    } finally {
      await a.close();
    }
  }

  /// Makes sure [file] carries its recording date inside before its name
  /// changes (the name may be the only place it is written). Returns it.
  Future<DateTime> _keepDate(RecordingFile file) async {
    var info = _info[file];
    if (info == null) {
      info = await _safe(() => _readInfo(file));
      if (info != null) _info.put(file, info);
    }
    final known = info?.recorded;
    if (known != null) return known;
    final date = parseTimestampName(file.baseName) ?? file.modified;
    if (canStoreRecordedDate(file.name)) {
      await _safe(() async {
        final a = await store.openBytes(file, write: true);
        try {
          await writeRecordedDate(a, file.name, date);
        } finally {
          await a.close();
        }
      });
    }
    return date;
  }

  /// Re-checks what may have changed while the app was in the background:
  /// the last recording may have been deleted or changed, free space too.
  Future<void> onResume() async {
    // iOS: an interruption that ended without "should resume" (e.g. another
    // app took the audio session) leaves the recording paused until now.
    if (_recording && _interrupted && !_paused) {
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
    await checkLaunchAction();
  }

  /// Forgets the Recorder screen's recording if it no longer exists.
  Future<void> _recheckCurrent() async {
    final cur = _current;
    if (cur == null || _recording) return;
    try {
      final found = await store.find(cur.id);
      if (_current?.id != cur.id) return;
      if (found == null) {
        if (playback.fileId == cur.id) await _stopPlayback();
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
        final recorded =
            parseTimestampName(splitExtension(name).$1) ??
            await e.lastModified();
        // An MP3 has its date from the start; a cut-off WAV or an M4A that
        // wasn't saved gets it now.
        if (!lower.endsWith('.mp3')) {
          await _safe(() => _stamp(e, name, recorded));
        }
        final unsaved = _unsaved?.name == name ? _unsaved : null;
        final playTime = unsaved?.duration ?? await audioDuration(e);
        final saved = await store.save(
          e,
          name,
          RecordingStore.mimeTypeFor(name),
        );
        _info.put(saved, AudioInfo(recorded: recorded, duration: playTime));
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
      if (playback.fileId != null) await _stopPlayback();
      if (!await engine.requestPermission()) return RecordOutcome.noPermission;
      if (!store.isReady) return RecordOutcome.needsFolder;
      await refreshRemaining();
      final left = _remaining;
      if (left != null && left < minRecordingSpace) {
        return RecordOutcome.noSpace;
      }

      final profile = settings.profile;
      final startedAt = _clock();
      final name = '${timestampName(startedAt)}.${profile.type.extension}';
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
        if (playback.fileId != null) await _stopPlayback();
        await engine.start(
          profile,
          file.path,
          recorded: startedAt,
          noiseReduction: settings.noiseReduction,
        );
      } catch (e) {
        if (isAndroid) await _safe(native.stopRecordingService);
        rethrow;
      }

      _pendingName = name;
      _pendingFile = file;
      _startedAt = startedAt;
      _activeProfile = profile;
      _recording = true;
      _paused = false;
      _interrupted = false;
      _level = 0;
      _stopwatch
        ..reset()
        ..start();
      _levelSub = engine.levels.listen((l) {
        if (_paused || _interrupted) return;
        _level = l;
        notifyListeners();
      });
      _interruptSub = engine.interrupted.listen((paused) {
        _interrupted = paused;
        if (paused) _level = 0;
        _updateStopwatch();
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

  void _updateStopwatch() {
    if (_paused || _interrupted) {
      _stopwatch.stop();
    } else {
      _stopwatch.start();
    }
  }

  /// Pauses or resumes the recording. False if that failed (e.g. resuming
  /// during a call on iPhone).
  Future<bool> togglePauseRecording() async {
    if (!_recording || _busy || _pausing) return false;
    _pausing = true;
    notifyListeners();
    try {
      if (_paused) {
        await engine.resume();
        _paused = false;
      } else {
        await engine.pause();
        _paused = true;
        _level = 0;
      }
      _updateStopwatch();
      if (isAndroid) unawaited(_safe(_showRecordingState));
      return true;
    } catch (e) {
      debugPrint('Could not pause or resume the recording: $e');
      return false;
    } finally {
      _pausing = false;
      notifyListeners();
    }
  }

  Future<void> _showRecordingState() {
    final paused = _paused || _interrupted;
    return native.updateRecordingService(
      text: '${paused ? 'Paused' : 'Recording'} $_pendingName',
      paused: paused,
      elapsed: _stopwatch.elapsed,
    );
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
    final startedAt = _startedAt ?? _clock();
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
    _paused = false;
    _interrupted = false;
    _level = 0;
    try {
      if (!await file.exists()) return RecordOutcome.failed;
      final lower = name.toLowerCase();
      if (lower.endsWith('.m4a')) {
        if (!await hasMp4Index(file)) {
          // The recorder failed to finish it, so it can't be played.
          await file.rename('${file.path}.incomplete');
          return RecordOutcome.failed;
        }
        // The platform's encoder writes its own time (when it stopped).
        await _safe(() => _stamp(file, name, startedAt));
      } else if (lower.endsWith('.wav')) {
        // Added when the file was finished, unless finishing failed.
        await _safe(() => _stamp(file, name, startedAt));
      }
      final saved = await store.save(
        file,
        name,
        RecordingStore.mimeTypeFor(name),
      );
      _info.put(saved, AudioInfo(recorded: startedAt, duration: duration));
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
      _startedAt = null;
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
        _loaded = file;
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
      _loaded = file;
      await playback.load(file.id, store.playbackUri(file));
      await playback.seek(playback.duration * fraction.clamp(0.0, 1.0));
      return true;
    } catch (e) {
      debugPrint('Could not seek in ${file.name}: $e');
      return false;
    }
  }

  /// Jumps forward (or back, for a negative [delta]) in the loaded
  /// recording, or in [file] (loaded first if another one is).
  Future<void> skip(Duration delta, {RecordingFile? file}) async {
    if (_recording || _busy) return;
    if (file != null && playback.fileId != file.id) {
      if (!await seek(file, 0)) return;
    }
    if (playback.fileId == null) return;
    await _safe(() => playback.seek(_clamped(playback.position + delta)));
  }

  Duration _clamped(Duration position) {
    final length = playback.duration;
    if (position.isNegative) return Duration.zero;
    if (length > Duration.zero && position > length) return length;
    return position;
  }

  /// The next of [playbackSpeeds] (after the last, the first).
  void cycleSpeed() {
    final i = playbackSpeeds.indexOf(settings.playbackSpeed);
    settings.playbackSpeed = playbackSpeeds[(i + 1) % playbackSpeeds.length];
  }

  Future<void> _stopPlayback() async {
    _loaded = null;
    await playback.stop();
  }

  void _onPlaybackChanged() {
    notifyListeners();
    _syncMedia();
  }

  /// What the lock screen shows, as last sent to the platform.
  ({
    String id,
    Duration duration,
    Duration position,
    bool playing,
    double speed,
    Duration at,
  })?
  _media;
  final _mediaClock = Stopwatch()..start();

  /// Keeps the lock-screen and notification controls in step with the
  /// player. They appear once something plays and stay while it is paused.
  void _syncMedia() {
    if (_disposed) return;
    final file = _loaded;
    final id = playback.fileId;
    final show =
        _lockScreen &&
        file != null &&
        id == file.id &&
        (_media != null || playback.playing);
    if (!show) {
      if (_media != null) {
        _media = null;
        unawaited(_safe(native.clearMediaSession));
      }
      return;
    }
    final now = _mediaClock.elapsed;
    final playing = playback.playing;
    final position = playback.position;
    final duration = playback.duration;
    final speed = playback.speed;
    final m = _media;
    if (m != null &&
        m.id == id &&
        m.playing == playing &&
        m.duration == duration &&
        m.speed == speed) {
      // The platform moves the position along by itself; only a jump (a
      // seek) needs telling.
      final expected = m.playing
          ? m.position + (now - m.at) * speed
          : m.position;
      if ((position - expected).abs() < const Duration(milliseconds: 1500)) {
        return;
      }
    }
    _media = (
      id: id!,
      duration: duration,
      position: position,
      playing: playing,
      speed: speed,
      at: now,
    );
    unawaited(
      _safe(
        () => native.updateMediaSession(
          title: file.name,
          duration: duration,
          position: position,
          playing: playing,
          speed: speed,
        ),
      ),
    );
  }

  Future<void> _onNativeEvent(NativeEvent e) async {
    switch (e) {
      case MediaButton(:final action, :final position):
        await _onMediaButton(action, position);
      case RecordingButton(:final action):
        await _onRecordingButton(action);
    }
  }

  Future<void> _onMediaButton(String action, Duration? position) async {
    final file = _loaded;
    if (file == null || playback.fileId != file.id) {
      // Nothing is loaded any more: the controls are stale.
      _media = null;
      await _safe(native.clearMediaSession);
      return;
    }
    switch (action) {
      case 'play':
        if (!playback.playing) await togglePlay(file);
      case 'pause' || 'stop':
        if (playback.playing) await _safe(playback.pause);
      case 'toggle':
        await togglePlay(file);
      case 'seek':
        if (position != null) {
          await _safe(() => playback.seek(_clamped(position)));
        }
      case 'forward':
        await skip(skipInterval);
      case 'rewind':
        await skip(-skipInterval);
      case 'dismiss':
        if (playback.playing) await _safe(playback.pause);
        _media = null;
        await _safe(native.clearMediaSession);
    }
  }

  Future<void> _onRecordingButton(String action) async {
    if (!_recording) return;
    switch (action) {
      case 'pause':
        if (!_paused) await togglePauseRecording();
      case 'resume':
        if (_paused) await togglePauseRecording();
      case 'stop':
        if (_busy) return;
        final outcome = await _stop();
        if (outcome == RecordOutcome.notSaved) {
          _notify(
            "The recording couldn't be saved to the folder yet; it will be "
            'saved when the folder is available.',
          );
        } else if (outcome == RecordOutcome.failed) {
          _notify('Recording failed');
        }
    }
  }

  // ------------------------------------------------------ file actions
  String displayPathOf(RecordingFile f) => store.displayPath(f);

  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) async {
    final clean = sanitizeFileName(newBaseName);
    if (clean.isEmpty || clean == file.baseName) return file;
    if (playback.fileId == file.id) await _stopPlayback();
    // The date in the old name goes with it: keep it inside the file.
    final recorded = await _keepDate(file);
    final renamed = await _safe(() => store.rename(file, clean));
    if (renamed == null) return null;
    final info = AudioInfo(
      recorded: recorded,
      duration: file.duration ?? _info[file]?.duration,
    );
    _info.put(renamed, info);
    final shown = renamed.withInfo(info);
    if (_current?.id == file.id) {
      _current = shown;
      settings.setLast(shown.id, settings.lastDuration);
    }
    _files = _sorted([for (final f in _files) f.id == file.id ? shown : f]);
    notifyListeners();
    return shown;
  }

  /// Moves [files] to Recently deleted. [DeletedRecordings] undoes it.
  Future<DeletedRecordings> delete(List<RecordingFile> files) async {
    final loaded = playback.fileId;
    if (loaded != null && files.any((f) => f.id == loaded)) {
      await _stopPlayback();
    }
    final now = _clock();
    final moved = <TrashedRecording>[];
    final gone = <String>{};
    var failed = 0;
    ({String name, Duration duration})? current;
    for (final f in files) {
      final t = await _safe(() => store.trash(f, now));
      if (t == null) {
        failed++;
        continue;
      }
      moved.add(t);
      gone.add(f.id);
      if (_current?.id == f.id) {
        current = (name: f.name, duration: settings.lastDuration);
        _current = null;
        settings.setLast(null, Duration.zero);
      }
    }
    _files = [
      for (final f in _files)
        if (!gone.contains(f.id)) f,
    ];
    notifyListeners();
    return DeletedRecordings(moved, failed: failed, current: current);
  }

  /// Puts back what [deleted] moved to Recently deleted. Returns how many
  /// came back.
  Future<int> undoDelete(DeletedRecordings deleted) async {
    var restored = 0;
    for (final t in deleted.items) {
      final f = await _safe(() => store.restore(t));
      if (f == null) continue;
      restored++;
      _addFile(f);
      final cur = deleted.current;
      if (cur != null && cur.name == t.originalName && _current == null) {
        _current = f;
        settings.setLast(f.id, cur.duration);
      }
    }
    notifyListeners();
    return restored;
  }

  void _addFile(RecordingFile f) {
    _files = _sorted([
      for (final x in _files)
        if (x.id != f.id) x,
      f.withInfo(_info[f]),
    ]);
  }

  /// What is in Recently deleted, most recently deleted first.
  Future<List<TrashedRecording>> deletedRecordings() async {
    await _ready();
    final list = await _safe(store.listTrash) ?? <TrashedRecording>[];
    return [...list]..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  /// Brings a recording back from Recently deleted.
  Future<RecordingFile?> restoreDeleted(TrashedRecording t) async {
    final f = await _safe(() => store.restore(t));
    if (f != null) {
      _addFile(f);
      notifyListeners();
    }
    return f;
  }

  /// Deletes recordings from Recently deleted for good. Returns how many.
  Future<int> deleteForever(List<TrashedRecording> items) async {
    var n = 0;
    for (final t in items) {
      if (await _safe(() => store.delete(t.file)) ?? false) n++;
    }
    unawaited(refreshRemaining());
    return n;
  }

  /// Deletes what has been in Recently deleted for 30 days.
  Future<void> _purgeTrash() async {
    if (!store.isReady) return;
    final now = _clock();
    final expired = [
      for (final t in await deletedRecordings())
        if (t.expired(now)) t,
    ];
    if (expired.isNotEmpty) await deleteForever(expired);
  }

  Future<void> share(RecordingFile file, {Rect? origin}) async {
    await _safe(() => store.share(file, origin: origin));
  }

  Future<void> shareAll(List<RecordingFile> files, {Rect? origin}) async {
    await _safe(() => store.shareAll(files, origin: origin));
  }

  /// iOS: copies recordings picked in the Files app into the folder. Returns
  /// how many were copied, or null (cancelled, or not available).
  Future<int?> importRecordings() async {
    final s = store;
    if (s is! IosRecordingStore) return null;
    final n = await _safe(s.importRecordings);
    if (n != null && n > 0) await refreshFiles();
    return n;
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
    _nativeSub?.cancel();
    _notices.close();
    _launches.close();
    _info.dispose();
    settings.removeListener(_onSettingsChanged);
    store.removeListener(notifyListeners);
    playback.removeListener(_onPlaybackChanged);
    super.dispose();
  }
}
