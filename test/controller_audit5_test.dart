// The fifth audit: dates that must never be lost, and Recently deleted
// that must never empty itself early.
import 'dart:async';
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

/// An M4A of [seconds] whose movie header was created at [created].
List<int> _m4a({required int seconds, required DateTime created}) {
  List<int> box(String type, List<int> body) {
    final size = 8 + body.length;
    return [
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      ...type.codeUnits,
      ...body,
    ];
  }

  final mvhd = ByteData(20)
    ..setUint32(4, created.millisecondsSinceEpoch ~/ 1000 + 2082844800)
    ..setUint32(12, 1000)
    ..setUint32(16, seconds * 1000);
  return [
    ...box('ftyp', 'M4A isom'.codeUnits),
    ...box('mdat', List.filled(2000, 1)),
    ...box(
      'moov',
      box('mvhd', [...mvhd.buffer.asUint8List(), ...List.filled(80, 0)]),
    ),
  ];
}

RecordingFile _file(String name, DateTime modified, {int size = 20880}) =>
    RecordingFile(
      id: 'mem://$name',
      name: name,
      size: size,
      modified: modified,
    );

/// Like the Android store: Recently deleted lists nothing while the folder
/// is out of reach (its access was lost).
class _OutOfReachStore extends FakeStore {
  _OutOfReachStore(List<RecordingFile> files)
    : super(files: files, free: 1 << 30);

  @override
  Future<List<TrashedRecording>> listTrash() async =>
      ready ? super.listTrash() : const [];
}

/// A folder that gives a file a new time whenever it is renamed.
class _RestampingStore extends FakeStore {
  _RestampingStore(List<RecordingFile> files)
    : super(files: files, free: 1 << 30);

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) async {
    final r = await super.renameTo(file, fileName);
    if (r == null) return null;
    final stamped = r.copyWith(
      modified: r.modified.add(const Duration(seconds: 1)),
    );
    files[files.indexWhere((f) => f.id == r.id)] = stamped;
    return stamped;
  }
}

/// A folder whose files keep their id when renamed (the id isn't the
/// path), whose renames wait while [hold] is set (a network folder).
class _KeepIdStore extends FakeStore {
  _KeepIdStore(List<RecordingFile> files) : super(files: files, free: 1 << 30);

  Completer<void>? hold;

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) async {
    await hold?.future;
    final i = files.indexWhere((f) => f.id == file.id);
    if (i < 0) return null;
    return files[i] = files[i].copyWith(name: fileName);
  }
}

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

  /// Waits until every recording has been read (Store dates knows then
  /// what to offer).
  Future<void> datesKnown() async {
    for (var i = 0; i < 50 && app.datesToStore == null; i++) {
      await settle();
    }
  }

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
      // Not offered here because the app knows its date (this holds without
      // the refusal being marked, too).
      expect(app.datesToStore, isEmpty);
      await app.delete([row('lunch.mp3')]);
      await app.refreshFiles();
      await app.restoreDeleted((await app.deletedRecordings())!.single);
      expect(row('lunch.mp3').date, recorded);
      // The mark is what keeps both through Recently deleted: read again,
      // the file has no date and would be offered (and refuse again).
      await datesKnown();
      expect(app.datesToStore, isEmpty);
    });

    test('a long name, shortened in Recently deleted, keeps it', () async {
      await build([old, _file('b.mp3', DateTime(2026))]);
      await app.refreshFiles();
      // As long as a name typed in the app can be (240 bytes with ".aac").
      final long = 'a' * 236;
      await app.rename(row(old.name), long);
      await app.delete([row('$long.aac')]);
      await app.refreshFiles();
      final t = (await app.deletedRecordings())!.single;
      // The hidden name had no room for all of it: it comes back shorter.
      expect(t.originalName, '${'a' * 220}.aac');
      await app.restoreDeleted(t);
      expect(row(t.originalName).date, recorded);
    });

    test('a folder that gives renamed files a new time keeps it, also when '
        'Recently deleted re-dates them', () async {
      now = DateTime(2026, 10, 1);
      store = _RestampingStore([old, _file('b.mp3', DateTime(2026))]);
      await start();
      await app.refreshFiles();
      await app.rename(row(old.name), 'lunch');
      await app.deletedRecordings();
      now = DateTime(2026, 3, 1); // the clock set back: re-dated later
      await app.delete([row('lunch.aac')]);
      now = DateTime(2026, 10, 2);
      final t = (await app.deletedRecordings())!.single;
      expect(t.deletedAt, now);
      await app.refreshFiles();
      await app.restoreDeleted(t);
      expect(row('lunch.aac').date, recorded);
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
    // Before the folder goes: its save timer would write into it later.
    addTearDown(cache.dispose);
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

    test('a refusal is kept while the file is in Recently deleted', () async {
      // The app knows no date for it, only that it refuses one.
      final f = _file('lunch.mp3', DateTime(2016, 5, 23, 18, 44));
      await build([f, _file('b.mp3', DateTime(2026))]);
      store.contents[f.id] = _mp3WithApe();
      await app.refreshFiles();
      await datesKnown();
      final r = await app.storeDates(app.datesToStore!);
      expect(r.refused, ['lunch.mp3']);
      await app.delete([row('lunch.mp3')]);
      await app.refreshFiles();
      await app.restoreDeleted((await app.deletedRecordings())!.single);
      await datesKnown();
      expect(app.datesToStore, isEmpty);
    });

    test('a refusal is remembered between launches', () async {
      final dir = await Directory.systemTemp.createTemp('vr_cache');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/recording_info.json');
      final f = _file('lunch.mp3', DateTime(2016));
      final a = RecordingInfoCache(file: () async => file)
        ..put(f, AudioInfo(recorded: DateTime(2016)), refused: true);
      // Before the folder goes: a save timer would write into it later.
      addTearDown(a.dispose);
      await a.save();
      final b = RecordingInfoCache(file: () async => file);
      addTearDown(b.dispose);
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

    /// Deletes memo.mp3 while the clock is set back to March; the clock is
    /// right again from October 2nd.
    Future<void> deletedWhileSetBack() async {
      now = DateTime(2026, 10, 1);
      await start();
      await app.refreshFiles();
      await app.deletedRecordings();
      now = DateTime(2026, 3, 1);
      await app.delete([row('memo.mp3')]);
      now = DateTime(2026, 10, 2);
    }

    /// Android: another folder is chosen, and its Recently deleted listed.
    /// Returns what was in the first one.
    List<RecordingFile> switchFolder() {
      final here = [...store.files];
      store.files
        ..clear()
        ..add(_file('elsewhere.mp3', DateTime(2026)));
      return here;
    }

    test("another folder's Recently deleted doesn't end it", () async {
      store = FakeStore(files: [memo, other], free: 1 << 30);
      await deletedWhileSetBack();
      final here = switchFolder();
      expect(await app.deletedRecordings(), isEmpty);
      now = DateTime(2026, 10, 20);
      store.files
        ..clear()
        ..addAll(here);
      final items = (await app.deletedRecordings())!;
      expect(items.single.daysLeft(now), 30);
      expect(store.deletedForGood, isEmpty);
    });

    test('nor a listing while the folder is out of reach', () async {
      store = _OutOfReachStore([memo, other]);
      await deletedWhileSetBack();
      store.ready = false;
      expect(await app.deletedRecordings(), isEmpty);
      store.ready = true;
      final items = (await app.deletedRecordings())!;
      expect(items.single.daysLeft(now), 30);
      expect(store.deletedForGood, isEmpty);
    });

    test('30 days after the clock was right, what is left goes by its date '
        '(its 30 days are over, wherever it was deleted)', () async {
      // That the wait above ends: this held before it, too.
      store = FakeStore(files: [memo, other], free: 1 << 30);
      await deletedWhileSetBack();
      final here = switchFolder();
      await app.deletedRecordings();
      now = DateTime(2026, 11, 2);
      await app.deletedRecordings();
      store.files
        ..clear()
        ..addAll(here);
      expect(await app.deletedRecordings(), isEmpty);
      expect(store.deletedForGood, [
        '.vr-deleted-${DateTime(2026, 3, 1).millisecondsSinceEpoch}-memo.mp3',
      ]);
    });

    test("one that can't be re-dated doesn't keep the clock being set back "
        'again from being noticed', () async {
      final early = _file(
        TrashedRecording.hiddenName('early.mp3', DateTime(2024)),
        DateTime(2024),
      );
      store = FakeStore(files: [memo, other, early], free: 1 << 30)
        // The folder won't take its new name: it stays dated 2024.
        ..alterName = (name) =>
            name != early.name && name.endsWith('-early.mp3')
            ? name.substring(1)
            : name;
      await deletedWhileSetBack();
      await app.deletedRecordings();
      now = DateTime(2026, 12, 1);
      await app.deletedRecordings();
      now = DateTime(2026, 11, 15); // set back again, by two weeks
      await app.delete([row('b.mp3')]);
      now = DateTime(2026, 12, 2);
      final items = (await app.deletedRecordings())!;
      expect(items.map((t) => t.originalName), ['b.mp3', 'early.mp3']);
      expect(items.first.daysLeft(now), 30);
    });

    test('set back again while it waits, by a little: it waits on until '
        'the clock is right', () async {
      store = FakeStore(files: [memo, other], free: 1 << 30);
      await deletedWhileSetBack();
      final here = switchFolder();
      await app.deletedRecordings(); // the clock is right: its 30 days run
      now = DateTime(2026, 10, 9, 10);
      await app.deletedRecordings();
      now = DateTime(2026, 10, 9, 8); // two hours back
      store.files
        ..clear()
        ..addAll(here);
      final held = (await app.deletedRecordings())!;
      expect(store.deletedForGood, isEmpty);
      // Nor re-dated (renamed) at each listing by a clock that is behind.
      expect(held.single.deletedAt, DateTime(2026, 3, 1));
      now = DateTime(2026, 10, 9, 10, 30); // right again
      final items = (await app.deletedRecordings())!;
      expect(items.single.daysLeft(now), 30);
      expect(store.deletedForGood, isEmpty);
    });

    test('set back again by months: what is deleted then gets its 30 days '
        'from when the clock is right, however late', () async {
      store = FakeStore(files: [memo, other], free: 1 << 30);
      await deletedWhileSetBack();
      await app.deletedRecordings();
      now = DateTime(2026, 10, 9);
      await app.deletedRecordings();
      now = DateTime(2026, 6, 1);
      await app.delete([row('b.mp3')]);
      final here = switchFolder();
      now = DateTime(2026, 12, 1); // right again, more than 30 days on
      await app.deletedRecordings();
      store.files
        ..clear()
        ..addAll(here);
      now = DateTime(2026, 12, 20);
      final items = (await app.deletedRecordings())!;
      expect(items.map((t) => t.originalName), contains('b.mp3'));
      expect(store.deletedForGood, isEmpty);
    });

    test(
      're-dated on return to the app, an open screen lists it again',
      () async {
        now = DateTime(2026, 10, 1);
        await build([memo, other]);
        await app.refreshFiles();
        await app.deletedRecordings();
        now = DateTime(2026, 3, 1);
        await app.delete([row('memo.mp3')]);
        final shown = (await app.deletedRecordings())!; // the screen's list
        final v = app.trashVersion;
        now = DateTime(2026, 10, 2); // corrected while the app was away
        await app.onResume();
        await settle();
        expect(app.trashVersion, isNot(v));
        // Restoring from the old list (another id now) says it again.
        final w = app.trashVersion;
        expect(await app.restoreDeleted(shown.single), isNull);
        expect(app.trashVersion, isNot(w));
        final items = (await app.deletedRecordings())!;
        expect(await app.restoreDeleted(items.single), isNotNull);
        expect(row('memo.mp3'), isNotNull);
      },
    );
  });

  group('Recently deleted, while an Undo still puts recordings back,', () {
    late _KeepIdStore keep;
    late DeletedRecordings deleted;
    late List<TrashedRecording> listed;

    /// a.mp3 and b.mp3 deleted and listed; renames wait from now on.
    Future<void> undoComing() async {
      store = keep = _KeepIdStore([
        _file('a.mp3', now),
        _file('b.mp3', now),
        _file('c.mp3', now),
      ]);
      await start();
      await app.refreshFiles();
      deleted = await app.delete([row('a.mp3'), row('b.mp3')]);
      listed = (await app.deletedRecordings())!;
      keep.hold = Completer<void>();
    }

    test("Delete forever doesn't delete what it puts back", () async {
      await undoComing();
      final undo = app.undoDelete(deleted);
      final gone = app.deleteForever(listed);
      keep.hold!.complete();
      expect(await undo, 2);
      expect(await gone, 0);
      expect(store.deletedForGood, isEmpty);
      expect(store.files.map((f) => f.name), ['a.mp3', 'b.mp3', 'c.mp3']);
    });

    test("Restore doesn't rename what it puts back", () async {
      await undoComing();
      final notices = <String>[];
      app.notices.listen(notices.add);
      final undo = app.undoDelete(deleted);
      final one = app.restoreDeleted(listed.first);
      final all = app.restoreAll(listed);
      keep.hold!.complete();
      expect(await undo, 2);
      expect(await one, isNull);
      expect(await all, 0);
      await settle();
      expect(notices, isEmpty);
      expect(store.files.map((f) => f.name), ['a.mp3', 'b.mp3', 'c.mp3']);
      expect(app.files.map((f) => f.name).toSet(), {'a.mp3', 'b.mp3', 'c.mp3'});
    });

    test("one that fails doesn't stop those after it", () async {
      await undoComing();
      final failing = app.restoreAll(
        listed,
        onProgress: (_, _) => throw StateError('x'),
      );
      // Asked for while it still runs.
      final next = app.deletedRecordings();
      final rest = app.restoreAll(listed);
      keep.hold!.complete();
      await expectLater(failing, throwsStateError);
      expect(await next, hasLength(1));
      expect(await rest, 1); // b.mp3 (a.mp3 is back)
    });
  });

  test('renaming an M4A read in another time zone keeps the time in its '
      'name', () async {
    final named = DateTime(2026, 7, 14, 1, 30);
    final f = _file('2026_07_14_01_30_00.m4a', DateTime(2026, 7, 14, 1, 40));
    await build([f, _file('b.mp3', DateTime(2026))]);
    // Its movie header holds the moment it was recorded, which reads 6
    // hours earlier in the zone the phone is in now.
    store.contents[f.id] = _m4a(
      seconds: 600,
      created: named.subtract(const Duration(hours: 6)),
    );
    await app.refreshFiles();
    await datesKnown();
    expect(row(f.name).date, named);
    final renamed = await app.rename(row(f.name), 'Meeting');
    expect(renamed!.date, named);
    expect(row('Meeting.m4a').date, named);
    // Read again from the file, with nothing cached: the name's time was
    // written into it (as a moment in this zone).
    final info = await readAudioInfo(
      MemoryBytes(store.contents['mem://Meeting.m4a']!),
      'Meeting.m4a',
    );
    expect(info.recorded, named);
    await start(restart: true);
    await app.refreshFiles();
    for (var i = 0; i < 50 && row('Meeting.m4a').recorded == null; i++) {
      await settle();
    }
    expect(row('Meeting.m4a').date, named);
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
