// The fifth audit: dates that must never be lost, and Recently deleted
// that must never empty itself early.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/storage/info_cache.dart';

import 'support/fakes.dart';

/// [count] MPEG-1 Layer III frames: 160 kbit/s, 44.1 kHz, mono.
List<int> _mp3([int count = 40]) => [
  for (var i = 0; i < count; i++) ...[
    0xFF,
    0xFB,
    0xA0,
    0xC0,
    ...List.filled(518, 0),
  ],
];

/// An MP3 another program tagged: an APE tag, then ID3v1 at the very end.
/// A date tag appended after the APE tag would hide it, so none is added.
List<int> _mp3WithApe() => [
  ..._mp3(),
  ...'APETAGEX'.codeUnits,
  ...[0xD0, 0x07, 0, 0], // version 2000
  ...[32, 0, 0, 0], // size: just this footer
  ...[0, 0, 0, 0], // no items
  ...[0, 0, 0, 0], // flags: no header
  ...List.filled(8, 0),
  ...'TAG'.codeUnits,
  ...List.filled(125, 0),
];

RecordingFile _file(String name, DateTime modified, {int size = 20880}) =>
    RecordingFile(
      id: 'mem://$name',
      name: name,
      size: size,
      modified: modified,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late FakeStore store;
  late FakeEngine engine;
  late AppController app;
  var now = DateTime(2026, 9, 25, 12);

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_audit5');
    now = DateTime(2026, 9, 25, 12);
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
  tearDown(() => work.delete(recursive: true));

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The app on [store], started. [restart]: with the settings the last
  /// one left (the app was closed and opened again).
  Future<AppController> start({bool restart = false}) async {
    if (!restart) SharedPreferences.setMockInitialValues({});
    engine = FakeEngine();
    final controller = app = AppController(
      settings: await Settings.load(),
      store: store,
      engine: engine,
      playback: FakePlayback(),
      native: FakeNative(),
      workDir: () async => work,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.init();
    return controller;
  }

  Future<AppController> build(List<RecordingFile> files) {
    store = FakeStore(files: files, free: 1 << 30);
    return start();
  }

  RecordingFile row(String name) =>
      app.files.singleWhere((f) => f.name == name);

  group('a date kept only in the app', () {
    // AAC can't hold a date: after a rename, the app's memory is the only
    // place it is written.
    final old = _file('2016_05_23_18_14_00.aac', DateTime(2026, 9, 1));
    final recorded = DateTime(2016, 5, 23, 18, 14);

    Future<void> renamed() async {
      await build([old, _file('b.mp3', DateTime(2026))]);
      await app.refreshFiles();
      final lunch = await app.rename(row(old.name), 'lunch');
      expect(lunch!.date, recorded);
    }

    test(
      'survives Recently deleted, with the list refreshed meanwhile',
      () async {
        await renamed();
        await app.delete([row('lunch.aac')]);
        await app.refreshFiles(); // e.g. Settings opened on Android
        await app.restoreDeleted((await app.deletedRecordings())!.single);
        expect(row('lunch.aac').date, recorded);
      },
    );

    test('survives an undo after a refresh', () async {
      await renamed();
      final deleted = await app.delete([row('lunch.aac')]);
      await app.refreshFiles();
      await app.undoDelete(deleted);
      expect(row('lunch.aac').date, recorded);
    });

    test('survives switching to another folder and back', () async {
      await renamed();
      final here = [...store.files];
      store.files
        ..clear()
        ..add(_file('elsewhere.mp3', DateTime(2026)));
      await app.refreshFiles();
      store.files
        ..clear()
        ..addAll(here);
      await app.refreshFiles();
      expect(row('lunch.aac').date, recorded);
    });

    test('comes back under the name it gets when its own is taken', () async {
      await renamed();
      await app.delete([row('lunch.aac')]);
      store.files.add(_file('lunch.aac', DateTime(2026, 10), size: 999));
      await app.refreshFiles();
      await app.restoreAll((await app.deletedRecordings())!);
      expect(row('lunch (1).aac').date, recorded);
      expect(row('lunch.aac').date, DateTime(2026, 10)); // the other one
    });

    test('an MP3 that refuses a date keeps it too, and is not offered for '
        'storing', () async {
      final f = _file('2016_05_23_18_14_00.mp3', DateTime(2026, 9, 1));
      await build([f, _file('b.mp3', DateTime(2026))]);
      store.contents[f.id] = _mp3WithApe();
      await app.refreshFiles();
      await app.rename(row(f.name), 'lunch');
      expect(row('lunch.mp3').date, recorded);
      expect(app.datesToStore, isEmpty);
      await app.delete([row('lunch.mp3')]);
      await app.refreshFiles();
      await app.restoreDeleted((await app.deletedRecordings())!.single);
      expect(row('lunch.mp3').date, recorded);
    });

    test('a file whose date is in it is still forgotten once gone', () {
      final cache = RecordingInfoCache();
      final mp3 = _file('lunch.mp3', DateTime(2026));
      final aac = _file('lunch.aac', DateTime(2026));
      final unknown = _file('memo.aac', DateTime(2026));
      cache
        ..put(mp3, AudioInfo(recorded: recorded))
        ..put(aac, AudioInfo(recorded: recorded))
        ..put(unknown, AudioInfo.empty)
        ..retainOnly([]);
      expect(cache.contains(mp3), isFalse); // read again if it comes back
      expect(cache.contains(unknown), isFalse);
      expect(cache[aac], AudioInfo(recorded: recorded));
    });
  });

  test("an odd entry in the cache's file doesn't stop the list", () async {
    final dir = await Directory.systemTemp.createTemp('vr_cache');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/recording_info.json')
      ..writeAsStringSync('{"junk": ["2016-05-23T18:14:00.000", 1000]}');
    final cache = RecordingInfoCache(file: () async => file);
    await cache.load();
    cache.retainOnly([_file('a.mp3', DateTime(2026))]);
    expect(cache.contains(_file('a.mp3', DateTime(2026))), isFalse);
  });

  group('renaming', () {
    test('a date write that fails is offered for storing again', () async {
      final f = _file('2016_05_23_18_14_00.mp3', DateTime(2016, 5, 23, 18, 44));
      await build([f, _file('b.mp3', DateTime(2026))]);
      store.contents[f.id] = _mp3();
      store.roomFor[f.id] = 0; // the storage is full
      await app.refreshFiles();
      await settle();
      await app.rename(row(f.name), 'lunch');
      expect(app.datesToStore!.map((x) => x.name), ['lunch.mp3']);
      // There is room again: storing it writes the date the name had.
      final r = await app.storeDates(app.datesToStore!);
      expect(r.stored, 1);
      final info = await readAudioInfo(
        MemoryBytes(store.contents['mem://lunch.mp3']!),
        'lunch.mp3',
      );
      expect(info.recorded, DateTime(2016, 5, 23, 18, 14));
      expect(app.datesToStore, isEmpty);
    });

    test(
      'a date write that failed is tried again by the next rename',
      () async {
        final f = _file(
          '2016_05_23_18_14_00.mp3',
          DateTime(2016, 5, 23, 18, 44),
        );
        await build([f, _file('b.mp3', DateTime(2026))]);
        store.contents[f.id] = _mp3();
        store.roomFor[f.id] = 0;
        await app.refreshFiles();
        await app.rename(row(f.name), 'lunch');
        await app.rename(row('lunch.mp3'), 'team lunch');
        final info = await readAudioInfo(
          MemoryBytes(store.contents['mem://team lunch.mp3']!),
          'team lunch.mp3',
        );
        expect(info.recorded, DateTime(2016, 5, 23, 18, 14));
      },
    );

    test("iPhone: a date typed into the name isn't hidden by the copy's "
        'file time', () async {
      await build([_file('lunch.aac', DateTime(2026, 9, 24))]);
      store.timesAreDates = false;
      await app.refreshFiles();
      final renamed = await app.rename(
        app.files.single,
        '2016_05_23_18_14_00 lunch',
      );
      expect(renamed!.date, DateTime(2016, 5, 23, 18, 14));
      expect(app.files.single.date, DateTime(2016, 5, 23, 18, 14));
    });
  });

  group('storing dates for a new phone', () {
    test('one that refuses a date is not offered again', () async {
      final f = _file('lunch.mp3', DateTime(2016, 5, 23, 18, 44));
      await build([f]);
      store.contents[f.id] = _mp3WithApe();
      await app.refreshFiles();
      for (var i = 0; i < 50 && app.datesToStore == null; i++) {
        await settle();
      }
      expect(app.datesToStore!.map((x) => x.name), ['lunch.mp3']);
      final r = await app.storeDates(app.datesToStore!);
      expect(r.refused, ['lunch.mp3']);
      expect(app.datesToStore, isEmpty);
    });

    test('a refusal is remembered between launches', () async {
      final dir = await Directory.systemTemp.createTemp('vr_cache');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/recording_info.json');
      final f = _file('lunch.mp3', DateTime(2016));
      final a = RecordingInfoCache(file: () async => file)
        ..put(f, AudioInfo(recorded: DateTime(2016)), refused: true);
      await a.save();
      final b = RecordingInfoCache(file: () async => file);
      await b.load();
      expect(b.dateRefused(f), isTrue);
      expect(b.dateOnlyHere(f), isFalse);
      b.put(f, AudioInfo(recorded: DateTime(2016))); // written after all
      expect(b.dateRefused(f), isFalse);
    });
  });

  group('Recently deleted with a clock set back', () {
    final memo = _file('memo.mp3', DateTime(2026, 9));
    final other = _file('b.mp3', DateTime(2026, 9));

    test('what was deleted meanwhile gets its 30 days once the clock is '
        'right again', () async {
      now = DateTime(2026, 10, 1);
      await build([memo, other]);
      await app.refreshFiles();
      await app.deletedRecordings();
      now = DateTime(2026, 3, 1); // set by hand, or lost by the phone
      await app.delete([row('memo.mp3')]);
      now = DateTime(2026, 10, 2); // corrected
      final items = (await app.deletedRecordings())!;
      expect(items.single.originalName, 'memo.mp3');
      expect(items.single.daysLeft(now), 30);
      expect(store.deletedForGood, isEmpty);
      // And it does go once its 30 days are over.
      now = DateTime(2026, 11, 2);
      expect(await app.deletedRecordings(), isEmpty);
      expect(store.deletedForGood, [
        '.vr-deleted-'
            '${DateTime(2026, 10, 2).millisecondsSinceEpoch}-memo.mp3',
      ]);
    });

    test('also when the app was closed in between', () async {
      now = DateTime(2026, 10, 1);
      await build([memo, other]);
      await app.deletedRecordings();
      now = DateTime(2026, 3, 1);
      await start(restart: true);
      await app.refreshFiles();
      await app.delete([row('memo.mp3')]);
      now = DateTime(2026, 10, 2);
      await start(restart: true);
      expect(await app.deletedRecordings(), hasLength(1));
      expect(store.deletedForGood, isEmpty);
    });

    test(
      'one dated before 2025 and re-dated meanwhile gets them too',
      () async {
        now = DateTime(2026, 10, 1);
        await build([other]);
        await app.deletedRecordings();
        // Copied in from an old phone, and first listed while the clock was
        // set back.
        store.files.add(
          _file(TrashedRecording.hiddenName('early.mp3', DateTime(2024)), now),
        );
        now = DateTime(2026, 3, 1);
        await app.deletedRecordings();
        now = DateTime(2026, 10, 2);
        final items = (await app.deletedRecordings())!;
        expect(items.single.originalName, 'early.mp3');
        expect(items.single.daysLeft(now), 30);
      },
    );

    test('a clock that was once far ahead holds nothing up', () async {
      now = DateTime(2030); // set forward once
      await build([memo, other]);
      await app.deletedRecordings();
      now = DateTime(2026, 11, 8); // and back to the right time
      await app.refreshFiles();
      await app.delete([row('memo.mp3')]);
      now = DateTime(2026, 12, 9);
      expect(await app.deletedRecordings(), isEmpty);
      expect(store.deletedForGood, hasLength(1));
    });

    test("a few minutes' correction is not a clock set back", () async {
      now = DateTime(2026, 10, 1, 12);
      await build([memo, other]);
      await app.deletedRecordings();
      now = DateTime(2026, 10, 1, 11, 55);
      await app.refreshFiles();
      await app.delete([row('memo.mp3')]);
      now = DateTime(2026, 11, 1, 12);
      expect(await app.deletedRecordings(), isEmpty);
    });
  });

  group('the WAV size limit', () {
    Future<String> stoppedAt(RecordingQuality quality) async {
      await build([]);
      app.settings
        ..type = RecordingType.wav
        ..quality = quality;
      final notices = <String>[];
      app.notices.listen(notices.add);
      expect(await app.toggleRecord(), RecordOutcome.started);
      engine.endedController.add(CaptureEnd.sizeLimit);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(app.isRecording, isFalse);
      return notices.single;
    }

    test('is told for the quality recorded', () async {
      expect(await stoppedAt(RecordingQuality.low), contains('about 74 hours'));
    });

    test('at the best quality, about 13 hours', () async {
      expect(
        await stoppedAt(RecordingQuality.best),
        contains('about 13 hours'),
      );
    });
  });
}
