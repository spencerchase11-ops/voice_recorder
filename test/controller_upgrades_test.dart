import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/storage/info_cache.dart';

import 'support/fakes.dart';

const _last = 'mem://kris n evan got back then zach.mp3';
final _now = DateTime(2026, 9, 23, 19, 14, 5);

/// 100 MPEG-1 Layer III frames (160 kbit/s, 44.1 kHz, mono): 2.61 s.
List<int> _mp3Frames() => [
  for (var i = 0; i < 100; i++) ...[
    0xFF,
    0xFB,
    0xA0,
    0xC0,
    ...List.filled(518, 0),
  ],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late Settings settings;
  late FakeStore store;
  late FakeEngine engine;
  late FakePlayback playback;
  late FakeNative native;
  late AppController app;

  /// Calls to the platform channel, with their arguments.
  late List<MethodCall> calls;
  String? launchAction;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_upgrades');
    calls = [];
    launchAction = null;
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takeLaunchAction') {
        final a = launchAction;
        launchAction = null;
        return a;
      }
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
  tearDown(() => work.delete(recursive: true));

  Future<AppController> build({
    Map<String, Object> prefs = const {
      'last_file': _last,
      'last_duration_ms': 2037000,
    },
    List<RecordingFile>? files,
    bool isAndroid = false,
    RecordingInfoCache? info,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    settings = await Settings.load();
    store = FakeStore(
      files: files ?? referenceRecordings(),
      free: referenceFreeBytes,
    );
    engine = FakeEngine();
    playback = FakePlayback();
    native = FakeNative();
    app = AppController(
      settings: settings,
      store: store,
      engine: engine,
      playback: playback,
      native: native,
      workDir: () async => work,
      isAndroid: isAndroid,
      info: info,
      clock: () => _now,
    );
    addTearDown(app.dispose);
    await app.init();
    return app;
  }

  Iterable<MethodCall> named(String method) =>
      calls.where((c) => c.method == method);

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Waits for work that does real file I/O (saving a recording).
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'condition not reached');
  }

  group('pause and resume', () {
    test('the timer and the level stop while paused', () async {
      await build();
      await app.toggleRecord();
      engine.levelController.add(1.0);
      await settle();
      expect(app.litSegments, 10);

      expect(await app.togglePauseRecording(), isTrue);
      expect(app.isPaused, isTrue);
      expect(engine.pauses, 1);
      expect(app.litSegments, 1);
      engine.levelController.add(1.0); // late level from before the pause
      await settle();
      expect(app.litSegments, 1);
      final atPause = app.timerValue;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(app.timerValue, atPause);

      expect(await app.togglePauseRecording(), isTrue);
      expect(app.isPaused, isFalse);
      expect(engine.resumes, 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(app.timerValue, greaterThan(atPause));
    });

    test('a resume that fails keeps the recording paused', () async {
      await build();
      await app.toggleRecord();
      await app.togglePauseRecording();
      engine.resumeError = Exception('interrupted');
      expect(await app.togglePauseRecording(), isFalse);
      expect(app.isPaused, isTrue);
      expect(app.isRecording, isTrue);
    });

    test('a paused recording is saved when stopped', () async {
      await build();
      await app.toggleRecord();
      await app.togglePauseRecording();
      expect(await app.toggleRecord(), RecordOutcome.stopped);
      expect(app.isPaused, isFalse);
      expect(store.saved, hasLength(1));
    });

    test('a pause that ends after a stop leaves nothing paused', () async {
      await build();
      await app.toggleRecord();
      engine.pauseGate = Completer<void>();
      final pausing = app.togglePauseRecording();
      final stopping = app.toggleRecord();
      engine.pauseGate!.complete();
      await pausing;
      expect(await stopping, RecordOutcome.stopped);
      expect(app.isRecording, isFalse);
      expect(app.isPaused, isFalse);
    });

    test('pausing does nothing without a recording', () async {
      await build();
      expect(await app.togglePauseRecording(), isFalse);
      expect(engine.pauses, 0);
    });

    test('Android: the notification follows, and its buttons pause, resume and '
        'stop', () async {
      await build(isAndroid: true);
      await app.toggleRecord();
      final name = app.currentPath!.split('/').last;

      native.eventController.add(const RecordingButton('pause'));
      await settle();
      expect(app.isPaused, isTrue);
      final paused = named('updateRecordingService').last.arguments as Map;
      expect(paused['paused'], isTrue);
      expect(paused['text'], 'Paused $name');

      native.eventController.add(const RecordingButton('resume'));
      await settle();
      expect(app.isPaused, isFalse);
      final resumed = named('updateRecordingService').last.arguments as Map;
      expect(resumed['paused'], isFalse);
      expect(resumed['text'], 'Recording $name');

      native.eventController.add(const RecordingButton('stop'));
      await until(() => store.saved.isNotEmpty && !app.isBusy);
      expect(app.isRecording, isFalse);
      expect(store.saved, [name]);
      expect(named('stopRecordingService'), hasLength(1));
    });

    test('the recording date and noise reduction reach the engine', () async {
      await build();
      settings.noiseReduction = true;
      await app.toggleRecord();
      expect(engine.recorded, _now);
      expect(engine.noiseReduction, isTrue);
    });
  });

  group('lock-screen controls', () {
    Map<Object?, Object?> lastUpdate() =>
        named('updateMediaSession').last.arguments as Map<Object?, Object?>;

    test('shown once playing, kept while paused, gone on stop', () async {
      await build();
      final file = app.currentFile!;
      await app.seek(file, 0); // loaded, not playing: nothing shown yet
      await settle();
      expect(named('updateMediaSession'), isEmpty);

      await app.togglePlay(file);
      await settle();
      expect(lastUpdate(), {
        'title': file.name,
        'durationMs': 180000,
        'positionMs': 0,
        'playing': true,
        'speed': 1.0,
      });

      await app.togglePlay(file);
      await settle();
      expect(lastUpdate()['playing'], isFalse);
      expect(named('clearMediaSession'), isEmpty);

      await app.toggleRecord(); // recording stops playback
      await settle();
      expect(named('clearMediaSession'), hasLength(1));
    });

    test('only a jump in the position is reported', () async {
      await build();
      await app.togglePlay(app.currentFile!);
      await settle();
      final before = named('updateMediaSession').length;
      playback.setPosition(const Duration(milliseconds: 500));
      await settle();
      expect(named('updateMediaSession'), hasLength(before));
      playback.setPosition(const Duration(minutes: 2));
      await settle();
      expect(named('updateMediaSession'), hasLength(before + 1));
      expect(lastUpdate()['positionMs'], 120000);
    });

    test('the buttons control the player', () async {
      await build();
      final file = app.currentFile!;
      await app.togglePlay(file);
      playback.setPosition(const Duration(seconds: 30));

      native.eventController.add(const MediaButton('pause'));
      await settle();
      expect(playback.playing, isFalse);
      native.eventController.add(const MediaButton('play'));
      await settle();
      expect(playback.playing, isTrue);
      native.eventController.add(const MediaButton('toggle'));
      await settle();
      expect(playback.playing, isFalse);

      native.eventController.add(const MediaButton('forward'));
      await settle();
      expect(playback.position, const Duration(seconds: 40));
      native.eventController.add(const MediaButton('rewind'));
      native.eventController.add(const MediaButton('rewind'));
      await settle();
      expect(playback.position, const Duration(seconds: 20));
      native.eventController.add(
        const MediaButton('seek', position: Duration(minutes: 5)),
      );
      await settle();
      expect(playback.position, const Duration(minutes: 3)); // the end

      native.eventController.add(const MediaButton('dismiss'));
      await settle();
      expect(named('clearMediaSession'), hasLength(1));
      // Still loaded, where it was.
      expect(playback.fileId, file.id);
      expect(playback.position, const Duration(minutes: 3));
      // Resuming by itself after a call (just_audio does), without the
      // controls: paused again.
      await playback.play(file.id, Uri.parse(file.id));
      await settle();
      expect(playback.playing, isFalse);
      // Dismissed controls come back with the next play in the app.
      await app.togglePlay(file);
      await settle();
      expect(playback.playing, isTrue);
      expect(lastUpdate()['playing'], isTrue);
    });

    test(
      'off in Settings: no controls, and playback stops with the app',
      () async {
        await build();
        await app.togglePlay(app.currentFile!);
        await settle();
        expect(named('updateMediaSession'), isNotEmpty);

        settings.lockScreenControls = false;
        await settle();
        expect(named('clearMediaSession'), hasLength(1));
        final updates = named('updateMediaSession').length;
        playback.setPosition(const Duration(minutes: 1));
        await settle();
        expect(named('updateMediaSession'), hasLength(updates));

        app.setForeground(false);
        await settle();
        expect(playback.playing, isFalse);
      },
    );

    test('on in Settings, playback goes on in the background', () async {
      await build();
      await app.togglePlay(app.currentFile!);
      app.setForeground(false);
      await settle();
      expect(playback.playing, isTrue);
    });
  });

  group('playback', () {
    test('skip moves 10 s and stays inside the recording', () async {
      await build();
      final file = app.currentFile!;
      await app.togglePlay(file);
      await app.skip(skipInterval);
      expect(playback.position, const Duration(seconds: 10));
      await app.skip(-skipInterval * 2);
      expect(playback.position, Duration.zero);
      playback.setPosition(const Duration(minutes: 2, seconds: 55));
      await app.skip(skipInterval);
      expect(playback.position, const Duration(minutes: 3));
    });

    test('skip in another recording loads it first', () async {
      await build();
      await app.togglePlay(app.currentFile!);
      final other = store.files.first;
      await app.skip(skipInterval, file: other);
      expect(playback.fileId, other.id);
      expect(playback.playing, isFalse);
      expect(playback.position, const Duration(seconds: 10));
    });

    test(
      'speed goes round 1x, 1.25x, 1.5x, 2x and reaches the player',
      () async {
        await build();
        final seen = <double>[];
        for (var i = 0; i < 4; i++) {
          app.cycleSpeed();
          await settle();
          seen.add(playback.speed);
        }
        expect(seen, [1.25, 1.5, 2.0, 1.0]);
        expect(settings.playbackSpeed, 1.0);
      },
    );

    test('the chosen speed is applied at start', () async {
      await build(prefs: const {'playback_speed': 1.5});
      expect(playback.speed, 1.5);
    });
  });

  group('library', () {
    test('lengths and dates come from the files', () async {
      final renamed = RecordingFile(
        id: 'mem://Meeting.mp3',
        name: 'Meeting.mp3',
        size: 53000,
        modified: DateTime(2026, 9, 24, 8), // copied yesterday
      );
      await build(files: [...referenceRecordings(), renamed]);
      // Recorded long ago, as its tag says.
      store.contents[renamed.id] = [
        ...id3DateTag(DateTime(2016, 5, 23, 18, 14)),
        ..._mp3Frames(),
      ];
      await app.refreshFiles();
      await settle();
      final f = app.files.firstWhere((f) => f.id == renamed.id);
      expect(f.recorded, DateTime(2016, 5, 23, 18, 14));
      expect(f.duration!.inMilliseconds, 2610);
      // Sorted by that date: the oldest.
      expect(app.files.last.id, renamed.id);

      // Other rows ask for their lengths as they are shown.
      final row = app.files.firstWhere(
        (f) => parseTimestampName(f.baseName) != null,
      );
      expect(row.duration, isNull);
      store.contents[row.id] = _mp3Frames();
      app.requestInfo(row);
      await settle();
      expect(
        app.files.firstWhere((f) => f.id == row.id).duration!.inMilliseconds,
        2610,
      );
    });

    test('a file that cannot be read is not read again and again', () async {
      await build();
      await app.refreshFiles();
      final f = app.files.first;
      store.unreadable.add(f.id);
      app.requestInfo(f);
      await settle();
      final opens = store.opens;
      app.requestInfo(f);
      await settle();
      expect(store.opens, opens);
    });

    test('sort orders', () async {
      await build();
      await app.refreshFiles();
      List<String> names() => [for (final f in app.files) f.name];
      expect(names().first, 'kris n evan got back then zach.mp3');
      settings.sortOrder = SortOrder.oldest;
      expect(names().first, '2026_09_16_15_48_15.mp3');
      settings.sortOrder = SortOrder.nameAscending;
      expect(names().first, '2026_09_16_15_48_15.mp3');
      expect(names().last, 'lunch w kris team convo .mp3');
      settings.sortOrder = SortOrder.nameDescending;
      expect(names().first, 'lunch w kris team convo .mp3');
      settings.sortOrder = SortOrder.largest;
      expect(names().first, '2026_09_20_17_26_27.mp3'); // 79381 KB
    });

    test('renaming keeps the date: it is stored in the file first', () async {
      await build();
      await app.refreshFiles();
      final f = app.files.firstWhere(
        (f) => f.name == '2026_09_18_21_23_04.mp3',
      );
      store.contents[f.id] = _mp3Frames();
      final renamed = await app.rename(f, 'late night idea');
      expect(renamed!.name, 'late night idea.mp3');
      expect(renamed.date, DateTime(2026, 9, 18, 21, 23, 4));
      final info = await readAudioInfo(
        MemoryBytes(store.contents[renamed.id]!),
        renamed.name,
      );
      expect(info.recorded, DateTime(2026, 9, 18, 21, 23, 4));
      // Still in its place by date, not by the file's modification time.
      final i = app.files.indexWhere((x) => x.id == renamed.id);
      expect(app.files[i - 1].name, '2026_09_20_17_26_27.mp3');
    });

    test('a file with its date already inside is not changed', () async {
      await build();
      await app.refreshFiles();
      final f = app.files.firstWhere(
        (f) => f.name == '2026_09_18_21_23_04.mp3',
      );
      final bytes = [
        ...id3DateTag(DateTime(2026, 9, 18, 21, 23, 4)),
        ..._mp3Frames(),
      ];
      store.contents[f.id] = [...bytes];
      final renamed = await app.rename(f, 'idea');
      expect(store.contents[renamed!.id], bytes);
    });

    test('dates and lengths are kept between launches', () async {
      final file = File('${work.path}/recording_info.json');
      final cache = RecordingInfoCache(file: () async => file);
      final f = referenceRecordings().first;
      cache.put(
        f,
        AudioInfo(
          recorded: DateTime(2016),
          duration: const Duration(seconds: 7),
        ),
      );
      await cache.save();
      cache.dispose();

      final again = RecordingInfoCache(file: () async => file);
      await again.load();
      expect(
        again[f],
        AudioInfo(
          recorded: DateTime(2016),
          duration: const Duration(seconds: 7),
        ),
      );
      // A changed file (other size) is read again.
      expect(again[f.copyWith(size: 1)], isNull);
      again.dispose();
    });
  });

  group('Recently deleted', () {
    test('several recordings go and come back together', () async {
      await build();
      await app.refreshFiles();
      final two = app.files.sublist(1, 3);
      final deleted = await app.delete(two);
      expect(deleted.items, hasLength(2));
      expect(app.files, hasLength(8));
      expect(await app.deletedRecordings(), hasLength(2));
      expect(await app.undoDelete(deleted), 2);
      expect(app.files, hasLength(10));
      expect(await app.deletedRecordings(), isEmpty);
    });

    test('restore and delete for good', () async {
      await build();
      await app.refreshFiles();
      await app.delete(app.files.sublist(0, 2));
      final trash = (await app.deletedRecordings())!;
      final restored = await app.restoreDeleted(trash.first);
      expect(restored, isNotNull);
      expect(app.files.map((f) => f.id), contains(restored!.id));
      expect(await app.deleteForever([trash.last]), 1);
      expect(await app.deletedRecordings(), isEmpty);
      expect(store.deletedForGood, [trash.last.file.name]);
    });

    test('a restored name that is taken gets a free variant', () async {
      await build();
      await app.refreshFiles();
      final f = app.files.first;
      final deleted = await app.delete([f]);
      store.files.add(f); // a new file with the same name meanwhile
      await app.undoDelete(deleted);
      expect(
        store.files.map((f) => f.name),
        containsAll([f.name, '${f.baseName} (1).mp3']),
      );
    });

    test('after 30 days a recording is deleted for good', () async {
      RecordingFile trashed(String name, Duration ago) {
        final hidden = TrashedRecording.hiddenName(name, _now.subtract(ago));
        return RecordingFile(
          id: 'mem://$hidden',
          name: hidden,
          size: 1,
          modified: _now,
        );
      }

      await build(
        files: [
          ...referenceRecordings(),
          trashed('old.mp3', const Duration(days: 31)),
          trashed('recent.mp3', const Duration(days: 29)),
        ],
      );
      await settle();
      expect(store.deletedForGood, hasLength(1));
      expect(store.deletedForGood.single, endsWith('-old.mp3'));
      final left = (await app.deletedRecordings())!;
      expect(left.single.originalName, 'recent.mp3');
      expect(left.single.daysLeft(_now), 1);
    });

    test('a folder that refuses: nothing is lost', () async {
      await build();
      await app.refreshFiles();
      store.failRenames = true;
      final deleted = await app.delete([app.files.first]);
      expect(deleted.items, isEmpty);
      expect(deleted.failed, 1);
      expect(app.files, hasLength(10));
    });

    test("other apps' trash is never taken for Recently deleted", () {
      RecordingFile named(String n) =>
          RecordingFile(id: 'x', name: n, size: 1, modified: _now);
      // Android's own trash: expiry in seconds (10 digits).
      expect(
        TrashedRecording.parse(named('.trashed-1790000000-a.mp3')),
        isNull,
      );
      // Not audio.
      expect(
        TrashedRecording.parse(named('.vr-deleted-1790000000000-a.txt')),
        isNull,
      );
      // Ours whatever the time (deleted with the phone's clock far off).
      expect(
        TrashedRecording.parse(named('.vr-deleted-0000000000123-a.mp3'))
            ?.originalName,
        'a.mp3',
      );
      // Ours, also from early test builds (milliseconds, 13 digits).
      final hidden = TrashedRecording.hiddenName('a.mp3', _now);
      expect(hidden, startsWith('.vr-deleted-'));
      expect(TrashedRecording.parse(named(hidden))!.deletedAt, _now);
      final early = TrashedRecording.parse(
        named('.trashed-${_now.millisecondsSinceEpoch}-a.mp3'),
      );
      expect(early!.originalName, 'a.mp3');
    });

    test("Android's trash files in the folder are left alone", () async {
      final theirs = RecordingFile(
        id: 'mem://.trashed-1700000000-kept.mp3',
        name: '.trashed-1700000000-kept.mp3',
        size: 1,
        modified: _now,
      );
      await build(files: [...referenceRecordings(), theirs]);
      await settle();
      expect(store.deletedForGood, isEmpty);
      expect(await app.deletedRecordings(), isEmpty);
    });

    test('a restored recording gets its length read again', () async {
      await build();
      await app.refreshFiles();
      final f = app.files.firstWhere(
        (f) => parseTimestampName(f.baseName) != null,
      );
      store.contents[f.id] = _mp3Frames();
      app.requestInfo(f); // queued...
      final deleted = await app.delete([f]); // ...and gone before it's read
      await settle();
      await app.undoDelete(deleted);
      final back = app.files.firstWhere((x) => x.name == f.name);
      app.requestInfo(back);
      await settle();
      expect(app.files.firstWhere((x) => x.name == f.name).duration, isNotNull);
    });

    test('hidden names stay within the file system limit', () {
      final long = '${'a' * 300}.mp3';
      final hidden = TrashedRecording.hiddenName(long, _now);
      expect(hidden.length, lessThanOrEqualTo(250));
      expect(hidden, endsWith('.mp3'));
      final parsed = TrashedRecording.parse(
        RecordingFile(id: 'x', name: hidden, size: 0, modified: _now),
      );
      expect(parsed!.deletedAt, _now);
      expect(parsed.originalName, endsWith('.mp3'));
    });
  });

  group('shortcut', () {
    test('a Record shortcut reaches the screen once', () async {
      launchAction = 'record';
      await build();
      final actions = <String>[];
      app.launchActions.listen(actions.add); // listens after start-up
      await settle();
      expect(actions, ['record']);
      await app.onResume();
      await settle();
      expect(actions, ['record']);

      launchAction = 'record'; // opened from the shortcut again
      await app.onResume();
      await settle();
      expect(actions, ['record', 'record']);
    });
  });

  test('the iPhone import is not offered elsewhere', () async {
    await build();
    expect(await app.importRecordings(), isNull);
  });

  test('a new recording carries its date and length in the list', () async {
    await build();
    await app.toggleRecord();
    await app.toggleRecord();
    await app.refreshFiles();
    final f = app.files.firstWhere(
      (f) => f.name == '${timestampName(_now)}.mp3',
    );
    expect(f.recorded, _now);
    expect(f.duration, isNotNull);
  });
}
