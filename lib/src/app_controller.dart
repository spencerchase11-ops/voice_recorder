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

/// Most recordings shared at once (Android hands them all to the share sheet
/// in one message, which has a size limit).
const maxShareCount = 200;

/// How far a long job (deleting or restoring many recordings) has got.
typedef Progress = void Function(int done, int total);

/// Whether the user has cancelled a long job.
typedef Cancelled = bool Function();

/// What [AppController.storeDates] did: how many dates it stored, which
/// recordings couldn't hold one, and the one it stopped at (a write failed).
typedef StoredDates = ({int stored, List<String> refused, String? stoppedAt});

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
      _keepPlaybackInBounds();
    }
    _flushNotices();
  }

  /// Playback that mustn't go on: without lock-screen controls it ends with
  /// the app (Android would cut it off in the background anyway), also when
  /// it starts later (a file that was still opening, or resuming by itself
  /// after a call); and never during a recording.
  void _keepPlaybackInBounds() {
    if (!playback.playing) return;
    if (_recording || (!_inForeground && !settings.lockScreenControls)) {
      unawaited(_safe(playback.pause));
    }
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
  bool get isPaused => _recording && _paused;

  /// The system paused the recording (iOS: a call or Siri).
  bool get isInterrupted => _interrupted;
  bool get isBusy => _busy;

  /// Input level (0..1) while recording.
  double get level => _recording && !_paused && !_interrupted ? _level : 0;

  /// Number of lit level-meter squares (at least one, like the original).
  int get litSegments => 1 + (level * 9).round().clamp(0, 9);

  /// Recording shown at the bottom of the Recorder screen.
  RecordingFile? get currentFile => _current;

  /// A recording is running, or being saved.
  bool get _hasPending => _recording || (_busy && _pendingName != null);

  /// Text in the timer box.
  Duration get timerValue {
    if (_hasPending) return _stopwatch.elapsed;
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
    if (_hasPending && _pendingName != null) {
      return '${store.folderDisplayPath}/$_pendingName';
    }
    final cur = _current;
    return cur == null ? null : store.displayPath(cur);
  }

  /// Recordings in the order chosen in the list (newest first by default).
  List<RecordingFile> get files => _files;

  /// The folder has been listed at least once ([files] is empty until then).
  bool get filesLoaded => _filesLoaded;
  bool _filesLoaded = false;

  /// The folder couldn't be read the last time ([files] is what it had).
  bool get filesError => _filesError;
  bool _filesError = false;

  /// Changes whenever Recently deleted may have changed (a delete, an undo,
  /// a restore), for the screens that show it.
  int get trashVersion => _trashVersion;
  int _trashVersion = 0;

  void _trashChanged() {
    _trashVersion++;
    notifyListeners();
  }

  /// Runs a job on [count] recordings with the screen kept on when it's
  /// long: the phone going to sleep would pause it.
  Future<T> _awake<T>(int count, Future<T> Function() job) async {
    if (count <= 20) return job();
    await _safe(() => native.keepScreenOn(true));
    try {
      return await job();
    } finally {
      await _safe(() => native.keepScreenOn(false));
    }
  }

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
    try {
      await recoverInterrupted();
    } catch (e) {
      // Recording, the list and the folder wait for this: don't fail them.
      debugPrint('Could not recover recordings: $e');
    }
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
    final wasShown = _filesLoaded && !_filesError;
    _filesLoaded = true;
    _filesError = list == null;
    if (list == null) {
      // A passing error keeps what was listed; a folder that can't be
      // reached any more lists nothing.
      if (!store.isReady) _files = const [];
      notifyListeners();
      return;
    }
    // Forget the files that are gone, but not all of them when the folder
    // is out of reach (the list is empty then).
    if (store.isReady && list.isNotEmpty) _info.retainOnly(list);
    // Most refreshes (coming back to the app) find the same files: keep
    // the list as it is then.
    final shown = {for (final f in _files) f.id: f};
    var same = list.length == _files.length;
    final files = <RecordingFile>[];
    for (final f in list) {
      final old = shown[f.id];
      if (old != null &&
          old.name == f.name &&
          old.size == f.size &&
          old.modified == f.modified) {
        files.add(old);
      } else {
        same = false;
        files.add(f.withInfo(_info[f]));
      }
    }
    if (!same) {
      _files = _sorted(files);
      notifyListeners();
    } else if (!wasShown) {
      notifyListeners();
    }
    // A renamed recording keeps its date inside: read all of those (the
    // newest first), so the whole list is in the right order.
    for (final f in _files) {
      if (f.nameDate == null) _requestInfo(f, forOrder: true);
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
  /// Rows on screen that need their length: the newest request first.
  final _rowQueue = <String, RecordingFile>{};

  /// Recordings whose date may be stored inside (renamed ones): all of them
  /// are read, for the list's order.
  final _orderQueue = <String, RecordingFile>{};
  final _unreadable = <String>{};
  bool _probing = false;

  /// Reads [file]'s recording date and length in the background if they
  /// aren't known yet; the list shows them once they come in. The newest
  /// request is served first (the rows on screen).
  void requestInfo(RecordingFile file) => _requestInfo(file);

  void _requestInfo(RecordingFile file, {bool forOrder = false}) {
    if (_info.contains(file) ||
        _unreadable.contains(RecordingInfoCache.keyOf(file))) {
      return;
    }
    if (forOrder) {
      _orderQueue[file.id] = file;
    } else {
      _rowQueue
        ..remove(file.id)
        ..[file.id] = file;
      // Rows scrolled past long ago don't need reading any more.
      while (_rowQueue.length > 200) {
        _rowQueue.remove(_rowQueue.keys.first);
      }
    }
    if (_probing) return;
    _probing = true;
    // Not right away: this is called while the list is being built.
    scheduleMicrotask(_probe);
  }

  /// Results read but not shown yet: they are shown together, a few at a
  /// time, so thousands of them don't re-sort the list thousands of times.
  final _arrived = <String, AudioInfo>{};
  final _sinceShown = Stopwatch()..start();

  Future<void> _probe() async {
    try {
      while (!_disposed) {
        final RecordingFile file;
        if (_rowQueue.isNotEmpty) {
          file = _rowQueue.remove(_rowQueue.keys.last)!;
        } else if (_orderQueue.isNotEmpty) {
          file = _orderQueue.remove(_orderQueue.keys.first)!;
        } else {
          break;
        }
        _orderQueue.remove(file.id);
        if (_info.contains(file)) continue;
        AudioInfo info;
        try {
          info = await _readInfo(file);
        } catch (e) {
          // Unreadable right now (storage gone): not again this run. A file
          // deleted meanwhile doesn't count (it may be restored).
          if (_files.any((f) => f.id == file.id)) {
            _unreadable.add(RecordingInfoCache.keyOf(file));
          }
          continue;
        }
        _info.put(file, info);
        if (_arrived.isEmpty) _sinceShown.reset();
        _arrived[file.id] = info;
        final more = _rowQueue.isNotEmpty || _orderQueue.isNotEmpty;
        if (!more ||
            _arrived.length >= 10 ||
            _sinceShown.elapsedMilliseconds > 300) {
          _showArrived();
        }
      }
    } finally {
      _probing = false;
      _showArrived();
    }
  }

  void _showArrived() {
    if (_arrived.isEmpty || _disposed) return;
    var resort = false;
    final files = <RecordingFile>[];
    for (final f in _files) {
      final info = _arrived[f.id];
      if (info == null) {
        files.add(f);
        continue;
      }
      final updated = f.withInfo(info);
      if (updated.date != f.date) resort = true;
      files.add(updated);
    }
    _arrived.clear();
    _files = resort ? _sorted(files) : files;
    notifyListeners();
  }

  Future<AudioInfo> _readInfo(RecordingFile file) async {
    final a = await store.openBytes(file);
    try {
      return await readAudioInfo(a, file.name);
    } finally {
      await a.close();
    }
  }

  /// Writes [date] into [file]. False if the file can't hold it (it is left
  /// as it was); throws if writing failed.
  Future<bool> _writeDate(RecordingFile file, DateTime date) async {
    final a = await store.openBytes(file, write: true);
    try {
      return await writeRecordedDate(a, file.name, date);
    } finally {
      await a.close();
    }
  }

  // --------------------------------------------- dates for a new phone
  /// Renamed recordings whose date is only their file's time, which copying
  /// them to another phone often loses, and that can hold a date inside.
  /// Null while they are still being read.
  List<RecordingFile>? get datesToStore {
    if (!store.fileTimesAreDates) return const [];
    final out = <RecordingFile>[];
    for (final f in _files) {
      if (f.nameDate != null || !canStoreRecordedDate(f.name)) continue;
      if (_unreadable.contains(RecordingInfoCache.keyOf(f))) continue;
      final info = _info[f];
      if (info == null) return null;
      // A length means the file could be read (it can take a date).
      if (info.recorded == null && info.duration != null) out.add(f);
    }
    return out;
  }

  /// Stores each of [files]' date, as the list shows it (the file's time),
  /// inside the file, so it is kept wherever the recording is copied. The
  /// sound isn't touched. Stops at the first write that fails.
  Future<StoredDates> storeDates(
    List<RecordingFile> files, {
    Progress? onProgress,
    Cancelled? cancelled,
  }) => _awake(files.length, () async {
    final loaded = playback.fileId;
    if (loaded != null && files.any((f) => f.id == loaded)) {
      await _stopPlayback();
    }
    var stored = 0;
    final refused = <String>[];
    String? stoppedAt;
    final changed = <String, RecordingFile>{};
    var done = 0;
    for (final file in files) {
      if (cancelled?.call() ?? false) break;
      final date = file.date;
      final duration = _info[file]?.duration ?? file.duration;
      var ok = false;
      try {
        ok = await _writeDate(file, date);
      } catch (e) {
        debugPrint('Could not store the date of ${file.name}: $e');
        stoppedAt = file.name;
      }
      if (ok || stoppedAt != null) {
        // Its size and time have changed: keep its date under them (also
        // when the write failed and was undone, as its time changed).
        final now = await _safe(() => store.find(file.id));
        if (now != null) {
          final info = AudioInfo(recorded: date, duration: duration);
          _info.put(now, info);
          changed[file.id] = now.withInfo(info);
        }
      }
      if (ok) {
        stored++;
      } else if (stoppedAt == null) {
        refused.add(file.name);
      }
      done++;
      onProgress?.call(done, files.length);
      if (stoppedAt != null) break;
      if (changed.length >= 50) _replaceFiles(changed);
    }
    _replaceFiles(changed);
    unawaited(_info.save());
    return (stored: stored, refused: refused, stoppedAt: stoppedAt);
  });

  /// Puts the new state of [changed] recordings (by id) in the list.
  void _replaceFiles(Map<String, RecordingFile> changed) {
    if (changed.isEmpty) return;
    _files = _sorted([for (final f in _files) changed[f.id] ?? f]);
    final cur = _current;
    if (cur != null && changed[cur.id] != null) _current = changed[cur.id];
    changed.clear();
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
  /// Formats that can't hold it (and damaged files) keep it in the cache.
  Future<DateTime> _keepDate(RecordingFile file) async {
    var info = _info[file];
    if (info == null) {
      info = await _safe(() => _readInfo(file));
      if (info != null) _info.put(file, info);
    }
    final known = info?.recorded;
    final named = recordingDate(
      stored: known,
      named: file.nameDate,
      length: info?.duration,
    );
    final date = named ?? file.modified;
    if (known != null && date == known) return known;
    // On iPhone a file's time is when it was copied there, not a recording
    // date: writing it into the file would make a wrong date stick.
    if (named == null && !store.fileTimesAreDates) return date;
    if (canStoreRecordedDate(file.name)) {
      await _safe(() => _writeDate(file, date));
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
        // Still in use (a call goes on): it stays paused, and resumes when
        // the call ends or on the next return to the app.
        debugPrint('Could not resume recording yet: $e');
      }
    }
    await _recheckCurrent();
    await refreshRemaining();
    await checkLaunchAction();
    // The app can stay in memory for days.
    final last = _lastPurge;
    if (last == null || _clock().difference(last).abs() > _purgeEvery) {
      unawaited(_purgeTrash());
    }
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
    // Never touch the file of a recording that is running, starting, or
    // being saved.
    if (!store.isReady || _recording || _busy) return;
    final dir = Directory('${(await workDir()).path}/pending');
    if (!await dir.exists()) return;
    final files = [
      await for (final e in dir.list())
        if (e is File) e,
    ];
    for (final e in files) {
      if (_recording || _busy) return;
      final name = e.uri.pathSegments.last;
      final lower = name.toLowerCase();
      try {
        if (lower.endsWith('.incomplete')) {
          // Unplayable M4A files kept aside; drop them after a week.
          final age = DateTime.now().difference(await e.lastModified());
          if (age > const Duration(days: 7)) await e.delete();
          continue;
        }
        if (!isAudioFileName(name)) continue;
        final length = await e.length();
        // Nothing was recorded (a WAV header alone is 44 bytes, an MP3 starts
        // with its date tag).
        if (length == 0 ||
            (lower.endsWith('.wav') && length <= 44) ||
            (lower.endsWith('.mp3') && await _onlyDateTag(e, length))) {
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
          _notify("An M4A recording was cut off and couldn't be saved.");
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
        final playTime = await audioDuration(e) ?? unsaved?.duration;
        final saved = await store.save(
          e,
          name,
          RecordingStore.mimeTypeFor(name),
        );
        _info.put(saved, AudioInfo(recorded: recorded, duration: playTime));
        // The newest recording belongs on the Recorder screen.
        final cur = _current;
        if (cur == null || !saved.date.isBefore(cur.date)) {
          _current = saved;
          settings.setLast(saved.id, playTime ?? Duration.zero);
        }
        if (unsaved != null) _unsaved = null;
      } catch (err) {
        debugPrint('Could not recover $name: $err');
      }
    }
  }

  /// An MP3 cut off before its first sound: just the date tag it starts
  /// with.
  Future<bool> _onlyDateTag(File f, int length) async {
    if (length > id3DateTag(DateTime(2000)).length) return false;
    final raf = await f.open();
    try {
      return String.fromCharCodes(await raf.read(3)) == 'ID3';
    } finally {
      await raf.close();
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
      if (_playbackOpen) await _stopPlayback();
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
      // iOS: a recording in progress (possibly gigabytes of WAV) stays out of
      // iCloud backups; Android excludes it in backup_rules.xml.
      if (!isAndroid) await _safe(() => native.excludeFromBackup(dir.path));
      final file = File('${dir.path}/$name');

      if (isAndroid) {
        await native.startRecordingService(
          title: 'Voice Recorder',
          text: 'Recording $name',
        );
      }
      try {
        // Playback may have been started while this was starting up.
        if (_playbackOpen) await _stopPlayback();
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
            "The recording stopped: it couldn't be written. Is the storage "
                'full?',
          CaptureEnd.sizeLimit =>
            "The recording stopped: WAV recordings can't be longer than "
                'about 13 hours.',
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
      // The notification's timer started with the service, a moment early.
      if (isAndroid) unawaited(_safe(_showRecordingState));
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
  /// during a call on iPhone); a tap while the last one is still being
  /// carried out is ignored.
  Future<bool> togglePauseRecording() async {
    if (_pausing) return true;
    if (!_recording || _busy) return false;
    _pausing = true;
    notifyListeners();
    try {
      final resume = _paused;
      if (resume) {
        await engine.resume();
      } else {
        await engine.pause();
      }
      // Stopped meanwhile (the stop button, or it stopped on its own).
      if (!_recording) return false;
      _paused = !resume;
      if (_paused) _level = 0;
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
    var duration = _stopwatch.elapsed;
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
        // Its length is in the file (the timer may have run through an
        // interruption the encoder paused for).
        duration =
            await _safe<Duration?>(() => audioDuration(file)) ?? duration;
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
      RecordOutcome.stopped => '$reason It has been saved.',
      RecordOutcome.notSaved =>
        "$reason It couldn't be saved to the folder yet. $_whenSaved",
      _ => "$reason It couldn't be saved.",
    });
  }

  /// When a recording that couldn't be saved to the folder will be.
  String get _whenSaved => store.isReady
      ? 'It will be saved the next time the app starts.'
      : 'To save it, choose the folder again in Settings > Folder.';

  @visibleForTesting
  Future<void> checkSpace() => _checkSpace();

  Future<void> _checkSpace() async {
    await refreshRemaining();
    final left = _remaining;
    if (_recording && left != null && left < minRecordingSpace) {
      await _stopOnItsOwn('The recording stopped: storage is almost full.');
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
        _held = false;
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
  /// recording, or in [file] (loaded first if another one is). False if
  /// [file] couldn't be opened.
  Future<bool> skip(Duration delta, {RecordingFile? file}) async {
    if (_recording || _busy) return true;
    if (file != null && playback.fileId != file.id) {
      if (!await seek(file, 0)) return false;
    }
    if (playback.fileId == null) return true;
    await _safe(() => playback.seek(_clamped(playback.position + delta)));
    return true;
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

  /// A recording is loaded or still opening.
  bool get _playbackOpen => playback.fileId != null || _loaded != null;

  Future<void> _stopPlayback() async {
    _loaded = null;
    _held = false;
    await playback.stop();
  }

  /// The controls went away while it was paused: it stays paused (it would
  /// resume by itself after a call otherwise) until played in the app.
  bool _held = false;

  void _onPlaybackChanged() {
    notifyListeners();
    if (_held && playback.playing) {
      // It resumed by itself: pause it again, without bringing the controls
      // back meanwhile (the player says it has paused a moment later).
      unawaited(_safe(playback.pause));
      return;
    }
    _keepPlaybackInBounds();
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
          title: file.baseName,
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
      case ImportProgress(:final done, :final total):
        _importProgress = (done: done, total: total);
        notifyListeners();
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
      case 'pause':
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
      case 'stop' || 'dismiss':
        // The controls were dismissed, or went away after a long pause. The
        // recording stays where it was, paused.
        _media = null;
        _held = true;
        await _safe(native.clearMediaSession);
        if (playback.playing) await _safe(playback.pause);
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
            "The recording couldn't be saved to the folder yet. $_whenSaved",
          );
        } else if (outcome == RecordOutcome.failed) {
          _notify("The recording couldn't be saved.");
        }
    }
  }

  // ------------------------------------------------------ file actions
  Future<RecordingFile?> rename(RecordingFile file, String newBaseName) async {
    // OK without a change (the name may have spaces that would be trimmed).
    if (newBaseName == file.baseName) return file;
    final ext = file.extension;
    var clean = sanitizeFileName(newBaseName);
    // "name.mp3" typed for an MP3: the extension is kept anyway.
    if (ext.isNotEmpty &&
        clean.toLowerCase().endsWith('.${ext.toLowerCase()}')) {
      clean = sanitizeFileName(
        clean.substring(0, clean.length - ext.length - 1),
      );
    }
    clean = fitFileName(clean, ext);
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
  Future<DeletedRecordings> delete(
    List<RecordingFile> files, {
    Progress? onProgress,
    Cancelled? cancelled,
  }) => _awake(files.length, () async {
    final loaded = playback.fileId;
    if (loaded != null && files.any((f) => f.id == loaded)) {
      await _stopPlayback();
    }
    final now = _clock();
    final moved = <TrashedRecording>[];
    final gone = <String>{};
    var failed = 0;
    ({String name, Duration duration})? current;
    var done = 0;
    for (final f in files) {
      if (cancelled?.call() ?? false) break;
      final t = await _safe(() => store.trash(f, now));
      done++;
      onProgress?.call(done, files.length);
      if (t == null) {
        failed++;
        continue;
      }
      moved.add(t);
      gone.add(f.id);
      _rowQueue.remove(f.id);
      _orderQueue.remove(f.id);
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
    if (moved.isNotEmpty) _trashVersion++;
    notifyListeners();
    return DeletedRecordings(moved, failed: failed, current: current);
  });

  /// Puts back what [deleted] moved to Recently deleted. Returns how many
  /// came back; the others stay in Recently deleted, and the user is told.
  Future<int> undoDelete(
    DeletedRecordings deleted, {
    Progress? onProgress,
    Cancelled? cancelled,
  }) => _awake(deleted.items.length, () async {
    final back = <RecordingFile>[];
    var done = 0;
    for (final t in deleted.items) {
      if (cancelled?.call() ?? false) break;
      final f = await _safe(() => store.restore(t));
      done++;
      onProgress?.call(done, deleted.items.length);
      if (f == null) continue;
      back.add(f);
      final cur = deleted.current;
      if (cur != null && cur.name == t.originalName && _current == null) {
        _current = f;
        settings.setLast(f.id, cur.duration);
      }
    }
    _addFiles(back);
    // Those not tried (cancelled) stay in Recently deleted as well; the
    // user knows.
    final missing = done - back.length;
    if (missing > 0) {
      final restored = {for (final f in back) f.name};
      var kept = 0;
      for (final t in deleted.items.take(done)) {
        if (restored.contains(t.originalName)) continue;
        if (await _safe(() => store.find(t.file.id)) != null) kept++;
      }
      final what = missing == 1
          ? "A recording couldn't be restored."
          : "${formatCount(missing)} recordings couldn't be restored.";
      _notify(switch (kept) {
        0 => what,
        _ when kept == missing =>
          '$what ${missing == 1 ? "It's" : "They're"} still in Settings > '
              'Recently deleted.',
        _ =>
          '$what ${formatCount(kept)} of them are still in Settings > '
              'Recently deleted.',
      });
    }
    _trashChanged();
    return back.length;
  });

  /// Adds [added] to the list (in one sort: an undo may bring back many).
  void _addFiles(List<RecordingFile> added) {
    if (added.isEmpty) return;
    final ids = {for (final f in added) f.id};
    for (final f in added) {
      _unreadable.remove(RecordingInfoCache.keyOf(f));
    }
    _files = _sorted([
      for (final x in _files)
        if (!ids.contains(x.id)) x,
      for (final f in added) f.withInfo(_info[f]),
    ]);
  }

  /// What is in Recently deleted, most recently deleted first. What has been
  /// there for 30 days is deleted for good first. Null if the folder can't
  /// be read.
  Future<List<TrashedRecording>?> deletedRecordings() async =>
      (await _loadTrash())?.items;

  /// Lists Recently deleted: deletes for good what has been there for 30
  /// days (and says how many), and gives what was deleted while the phone's
  /// clock was wrong its 30 days from now. One listing at a time (two at
  /// once would both deal with the same files).
  Future<({List<TrashedRecording> items, int purged})?> _loadTrash() {
    final previous = _trashLoad;
    final next = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      return _loadTrashNow();
    }();
    _trashLoad = next;
    next.whenComplete(() {
      if (identical(_trashLoad, next)) _trashLoad = null;
    }).ignore();
    return next;
  }

  Future<({List<TrashedRecording> items, int purged})?>? _trashLoad;

  Future<({List<TrashedRecording> items, int purged})?> _loadTrashNow() async {
    await _ready();
    final list = await _safe(store.listTrash);
    if (list == null) return null;
    final now = _clock();
    _lastPurge = now;
    final items = <TrashedRecording>[];
    var purged = 0;
    for (final t in list) {
      if (!t.plausible(now)) {
        items.add(
          await _safe<TrashedRecording?>(() => store.retime(t, now)) ?? t,
        );
      } else if (!t.expired(now)) {
        items.add(t);
      } else if (await _safe(() => store.delete(t.file)) ?? false) {
        purged++;
      } else {
        items.add(t);
      }
    }
    if (purged > 0) unawaited(refreshRemaining());
    items.sort((a, b) {
      final byTime = b.deletedAt.compareTo(a.deletedAt);
      return byTime != 0
          ? byTime
          : a.originalName.toLowerCase().compareTo(
              b.originalName.toLowerCase(),
            );
    });
    return (items: items, purged: purged);
  }

  /// Brings everything in [items] back from Recently deleted. Returns how
  /// many came back.
  Future<int> restoreAll(
    List<TrashedRecording> items, {
    Progress? onProgress,
    Cancelled? cancelled,
  }) => _awake(items.length, () async {
    final back = <RecordingFile>[];
    var done = 0;
    for (final t in items) {
      if (cancelled?.call() ?? false) break;
      final f = await _safe(() => store.restore(t));
      if (f != null) back.add(f);
      done++;
      onProgress?.call(done, items.length);
    }
    _addFiles(back);
    if (back.isNotEmpty) _trashChanged();
    return back.length;
  });

  /// Brings a recording back from Recently deleted.
  Future<RecordingFile?> restoreDeleted(TrashedRecording t) async {
    final f = await _safe(() => store.restore(t));
    if (f != null) {
      _addFiles([f]);
      _trashChanged();
    }
    return f;
  }

  /// Deletes recordings from Recently deleted for good. Returns how many.
  Future<int> deleteForever(
    List<TrashedRecording> items, {
    Progress? onProgress,
    Cancelled? cancelled,
  }) => _awake(items.length, () async {
    var n = 0;
    var done = 0;
    for (final t in items) {
      if (cancelled?.call() ?? false) break;
      if (await _safe(() => store.delete(t.file)) ?? false) n++;
      done++;
      onProgress?.call(done, items.length);
    }
    if (n > 0) _trashChanged();
    unawaited(refreshRemaining());
    return n;
  });

  /// When Recently deleted was last cleared of expired recordings.
  DateTime? _lastPurge;
  static const _purgeEvery = Duration(hours: 6);

  /// Deletes what has been in Recently deleted for 30 days. (A screen that
  /// lists it purges it itself, and isn't told again.)
  Future<void> _purgeTrash() async {
    if (!store.isReady) return;
    final trash = await _loadTrash();
    if (trash != null && trash.purged > 0) _trashChanged();
  }

  /// Opens the share sheet with [files] (at most [maxShareCount]). False if
  /// it couldn't be opened.
  Future<bool> shareAll(List<RecordingFile> files, {Rect? origin}) async {
    if (files.isEmpty || files.length > maxShareCount) return false;
    try {
      await store.shareAll(files, origin: origin);
      return true;
    } catch (e) {
      debugPrint('Could not share: $e');
      return false;
    }
  }

  /// iOS: copies recordings picked in the Files app into the folder: all in
  /// a [folder] (and its subfolders), or single ones. Null if cancelled, or
  /// not available. [importProgress] follows it.
  Future<ImportResult?> importRecordings({bool folder = true}) async {
    final s = store;
    if (s is! IosRecordingStore || _importProgress != null) return null;
    try {
      final result = await _safe(() => s.importRecordings(folder: folder));
      if (result != null && result.copied > 0) await refreshFiles();
      return result;
    } finally {
      _importProgress = null;
      notifyListeners();
    }
  }

  /// Stops the import from Files after the recording being copied.
  Future<void> cancelImport() async {
    if (_importProgress == null) return;
    await _safe(native.cancelImport);
  }

  /// How far an import from Files has got (total 0: still looking through
  /// the folders); null when none runs.
  ({int done, int total})? get importProgress => _importProgress;
  ({int done, int total})? _importProgress;

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
