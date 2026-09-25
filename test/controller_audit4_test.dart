// The fourth audit: moving thousands of recordings to a new phone, and the
// fixes that came with it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';
import 'package:voice_recorder/src/ui/screens/common_actions.dart';
import 'package:voice_recorder/src/ui/widgets/toast.dart';

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

RecordingFile _file(String name, DateTime modified) => RecordingFile(
  id: 'mem://$name',
  name: name,
  size: 20880,
  modified: modified,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late FakeStore store;
  late FakePlayback playback;
  late AppController app;
  var now = DateTime(2026, 9, 25, 12);
  final calls = <MethodCall>[];

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_audit4');
    now = DateTime(2026, 9, 25, 12);
    calls.clear();
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
  tearDown(() => work.delete(recursive: true));

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<AppController> build(List<RecordingFile> files) async {
    SharedPreferences.setMockInitialValues({});
    store = FakeStore(files: files, free: 1 << 30);
    playback = FakePlayback();
    app = AppController(
      settings: await Settings.load(),
      store: store,
      engine: FakeEngine(),
      playback: playback,
      native: FakeNative(),
      workDir: () async => work,
      clock: () => now,
    );
    addTearDown(app.dispose);
    await app.init();
    return app;
  }

  group('storing dates for a new phone', () {
    final ended = DateTime(2016, 5, 23, 18, 44, 10);
    final renamed = _file('lunch w kris team convo .mp3', ended);
    final named = _file('2016_05_23_18_14_00.mp3', ended);
    final other = _file('talk.aac', ended);
    final broken = _file('not really.mp3', ended);

    Future<void> ready() async {
      await build([renamed, named, other, broken]);
      store.contents[renamed.id] = _mp3();
      store.contents[named.id] = _mp3();
      store.contents[broken.id] = List.filled(3000, 0x11);
      await app.refreshFiles();
      for (var i = 0; i < 50 && app.datesToStore == null; i++) {
        await settle();
      }
    }

    test('only renamed recordings with no date inside need it', () async {
      await ready();
      // Timestamp names carry their date; AAC can't hold one; a damaged
      // file isn't touched.
      expect(app.datesToStore!.map((f) => f.name), [renamed.name]);
    });

    test('the date the list shows goes inside; nothing else changes', () async {
      await ready();
      final before = app.files.map((f) => (f.name, f.date)).toList();
      final progress = <(int, int)>[];
      final r = await app.storeDates(
        app.datesToStore!,
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(r.stored, 1);
      expect(r.refused, isEmpty);
      expect(r.stoppedAt, isNull);
      expect(progress, [(1, 1)]);
      final info = await readAudioInfo(
        MemoryBytes(store.contents[renamed.id]!),
        renamed.name,
      );
      expect(info.recorded, ended);
      expect(app.files.map((f) => (f.name, f.date)), before);
      expect(app.datesToStore, isEmpty);
    });

    test('a write that fails stops it, and the date stays known', () async {
      await ready();
      store.roomFor[renamed.id] = 10;
      final original = [...store.contents[renamed.id]!];
      final r = await app.storeDates(app.datesToStore!);
      expect(r.stored, 0);
      expect(r.stoppedAt, renamed.name);
      expect(store.contents[renamed.id], original); // put back as it was
      expect(app.files.firstWhere((f) => f.id == renamed.id).date, ended);
    });

    test('cancelled: stops before the next one', () async {
      final many = [
        for (var i = 0; i < 30; i++)
          _file('memo $i.mp3', ended.add(Duration(minutes: i))),
      ];
      await build(many);
      for (final f in many) {
        store.contents[f.id] = _mp3();
      }
      await app.refreshFiles();
      for (var i = 0; i < 50 && app.datesToStore == null; i++) {
        await settle();
      }
      var stop = false;
      final r = await app.storeDates(
        app.datesToStore!,
        onProgress: (done, _) => stop = done == 12,
        cancelled: () => stop,
      );
      expect(r.stored, 12);
      expect(app.datesToStore, hasLength(18));
      // A long job keeps the screen on, and lets it sleep again after.
      List<Object?> screen() => [
        for (final c in calls)
          if (c.method == 'keepScreenOn') (c.arguments as Map)['on'],
      ];
      expect(screen(), [true, false]);
    });

    test('two long jobs at once: the screen sleeps only after both', () async {
      await build([for (var i = 0; i < 50; i++) _file('memo $i.mp3', ended)]);
      await app.refreshFiles();
      List<Object?> screen() => [
        for (final c in calls)
          if (c.method == 'keepScreenOn') (c.arguments as Map)['on'],
      ];
      final gate = Completer<void>();
      store.slow = gate;
      final first = app.delete(app.files.sublist(0, 25));
      await settle();
      final second = app.delete(app.files.sublist(25));
      await settle();
      expect(screen(), [true]);
      gate.complete();
      store.slow = null;
      await first;
      await second;
      expect(screen(), [true, false]);
    });

    test('unknown until the folder has been listed (Settings first)', () async {
      await build([renamed]);
      store.contents[renamed.id] = _mp3();
      expect(app.datesToStore, isNull);
      await app.refreshFiles();
      for (var i = 0; i < 50 && app.datesToStore == null; i++) {
        await settle();
      }
      expect(app.datesToStore!.map((f) => f.name), [renamed.name]);
      // And unknown while the folder can't be read.
      store.failLists = true;
      await app.refreshFiles();
      expect(app.datesToStore, isNull);
    });

    test('a write that failed is tried again, with the same date', () async {
      await ready();
      store.roomFor[renamed.id] = 10;
      await app.storeDates(app.datesToStore!);
      expect(app.datesToStore!.map((f) => f.name), [renamed.name]);
      store.roomFor.remove(renamed.id);
      final r = await app.storeDates(app.datesToStore!);
      expect(r.stored, 1);
      final info = await readAudioInfo(
        MemoryBytes(store.contents[renamed.id]!),
        renamed.name,
      );
      expect(info.recorded, ended);
      expect(app.datesToStore, isEmpty);
    });

    test('one deleted before it was read and brought back is read', () async {
      await build([renamed]);
      store.contents[renamed.id] = _mp3();
      store.unreadable.add(renamed.id); // not readable for now
      await app.refreshFiles();
      await settle();
      final deleted = await app.delete([...app.files]);
      store.unreadable.clear();
      await app.undoDelete(deleted);
      for (var i = 0; i < 50 && app.datesToStore == null; i++) {
        await settle();
      }
      expect(app.datesToStore, hasLength(1));
    });

    test('the message says what happened', () {
      expect(
        storedDatesMessage((
          stored: 810,
          refused: ['a.mp3', 'b.mp3'],
          stoppedAt: null,
        ), of: 812),
        'The date is now stored in 810 recordings. 2 recordings couldn\'t '
        'take one: "a.mp3", "b.mp3". To keep their dates, start their names '
        'with the date, like "2016_05_23_18_14_00 lunch".',
      );
      expect(
        storedDatesMessage((stored: 3, refused: [], stoppedAt: 'x.mp3'), of: 9),
        'The date is now stored in 3 recordings. "x.mp3" couldn\'t be '
        'written, so it stopped there. Is the storage full? Its date is kept '
        'in the app.',
      );
      expect(
        storedDatesMessage((stored: 1, refused: [], stoppedAt: null), of: 5),
        'The date is now stored in 1 recording. It was stopped. The others '
        'can be done later.',
      );
    });
  });

  group('renaming', () {
    test('OK without a change leaves the file alone', () async {
      final f = _file('lunch w kris team convo .mp3', DateTime(2016));
      await build([f]);
      store.contents[f.id] = _mp3();
      await app.refreshFiles();
      final before = [...store.contents[f.id]!];
      final same = await app.rename(app.files.single, f.baseName);
      expect(same!.name, f.name);
      expect(store.contents[f.id], before); // no date written either
    });
  });

  test("iPhone: renaming doesn't write a copy's file time into it", () async {
    final f = _file('lunch.mp3', DateTime(2026, 9, 24)); // the day it came
    await build([f]);
    store.timesAreDates = false;
    store.contents[f.id] = _mp3();
    await app.refreshFiles();
    final before = [...store.contents[f.id]!];
    final renamed = await app.rename(app.files.single, 'team lunch');
    expect(renamed!.name, 'team lunch.mp3');
    expect(store.contents[renamed.id], before);
    // Nor are there recordings to store dates in.
    expect(app.datesToStore, isEmpty);
  });

  group('the list', () {
    test('a passing read error keeps what was listed', () async {
      await build([
        _file('a.mp3', DateTime(2026)),
        _file('b.mp3', DateTime(2025)),
      ]);
      await app.refreshFiles();
      expect(app.files, hasLength(2));
      store.failLists = true;
      await app.refreshFiles();
      expect(app.filesError, isTrue);
      expect(app.files, hasLength(2));
      store.failLists = false;
      await app.refreshFiles();
      expect(app.filesError, isFalse);
    });

    test('an unchanged folder keeps the same list', () async {
      await build([
        _file('a.mp3', DateTime(2026)),
        _file('b.mp3', DateTime(2025)),
      ]);
      await app.refreshFiles();
      final shown = app.files;
      await app.refreshFiles();
      expect(identical(app.files, shown), isTrue);
      store.files.add(_file('c.mp3', DateTime(2027)));
      await app.refreshFiles();
      expect(app.files.map((f) => f.name), ['c.mp3', 'a.mp3', 'b.mp3']);
    });
  });

  group('Recently deleted', () {
    test('what was deleted while the clock was set before 2025 gets its 30 '
        'days from now; two of the same name stay two', () async {
      final old = [
        _file(TrashedRecording.hiddenName('memo.mp3', DateTime(2024, 3)), now),
        _file(TrashedRecording.hiddenName('memo.mp3', DateTime(2024, 4)), now),
      ];
      await build(old);
      final items = (await app.deletedRecordings())!;
      expect(items.map((t) => t.originalName), ['memo.mp3', 'memo.mp3']);
      expect(items.map((t) => t.file.name).toSet(), hasLength(2));
      for (final t in items) {
        expect(t.daysLeft(now), 30);
      }
      expect(store.deletedForGood, isEmpty);
    });

    test(
      'one dated in the future is left alone (the clock may be wrong '
      'now), and nothing is deleted while the clock is before 2025',
      () async {
        final ahead = _file(
          TrashedRecording.hiddenName('ahead.mp3', DateTime(2027)),
          now,
        );
        final old = _file(
          TrashedRecording.hiddenName('old.mp3', DateTime(2026, 1)),
          now,
        );
        await build([ahead, old]);
        now = DateTime(2020); // booted with a stale clock
        final items = (await app.deletedRecordings())!;
        expect(items.map((t) => t.file.name), {ahead.name, old.name});
        expect(store.deletedForGood, isEmpty);
        now = DateTime(2026, 9, 25, 12); // the clock is right again
        final later = (await app.deletedRecordings())!;
        expect(later.single.originalName, 'ahead.mp3'); // old.mp3 expired
        expect(later.single.daysLeft(now), 30);
      },
    );

    test('iPhone: two of the same name re-dated at once stay two', () async {
      final docs = await Directory.systemTemp.createTemp('ios_docs');
      addTearDown(() => docs.delete(recursive: true));
      final dir = Directory('${docs.path}/Recorders')..createSync();
      for (final at in [DateTime(2024, 3), DateTime(2024, 4)]) {
        File('${dir.path}/${TrashedRecording.hiddenName('memo.mp3', at)}')
            .writeAsBytesSync([at.month]);
      }
      SharedPreferences.setMockInitialValues({});
      final ios = AppController(
        settings: await Settings.load(),
        store: IosRecordingStore(FakeNative(), documents: () async => docs),
        engine: FakeEngine(),
        playback: FakePlayback(),
        native: FakeNative(),
        workDir: () async => work,
        clock: () => now,
      );
      addTearDown(ios.dispose);
      await ios.init();
      final items = (await ios.deletedRecordings())!;
      expect(items, hasLength(2));
      expect(
        {for (final t in items) File(t.file.id).readAsBytesSync().single},
        {3, 4},
      );
    });

    test('listing it from a screen that purges is not a change', () async {
      await build([_file('a.mp3', now), _file('b.mp3', now)]);
      await app.refreshFiles();
      await app.delete([app.files.first]);
      now = now.add(const Duration(days: 31));
      final version = app.trashVersion;
      expect(await app.deletedRecordings(), isEmpty);
      expect(store.deletedForGood, hasLength(1));
      // No reload of the screens (which would list and purge again).
      expect(app.trashVersion, version);
    });

    test('several deleted at once are listed by name', () async {
      await build([
        _file('b.mp3', now),
        _file('C.mp3', now),
        _file('a.mp3', now),
      ]);
      await app.refreshFiles();
      await app.delete([...app.files]);
      final items = await app.deletedRecordings();
      expect(items!.map((t) => t.originalName), ['a.mp3', 'b.mp3', 'C.mp3']);
    });

    test('restore all brings everything back', () async {
      await build([_file('a.mp3', now), _file('b.mp3', now)]);
      await app.refreshFiles();
      await app.delete([...app.files]);
      final items = (await app.deletedRecordings())!;
      expect(await app.restoreAll(items), 2);
      expect(app.files, hasLength(2));
      expect(await app.deletedRecordings(), isEmpty);
    });

    test('an undo that is cancelled keeps the rest in Recently deleted, '
        'and says nothing of them', () async {
      final files = [for (var i = 0; i < 5; i++) _file('$i.mp3', now)];
      await build(files);
      await app.refreshFiles();
      final notices = <String>[];
      app.notices.listen(notices.add);
      final deleted = await app.delete([...app.files]);
      var stop = false;
      expect(
        await app.undoDelete(
          deleted,
          onProgress: (done, _) => stop = done == 2,
          cancelled: () => stop,
        ),
        2,
      );
      await settle();
      expect(notices, isEmpty);
      expect(await app.deletedRecordings(), hasLength(3));
    });
  });

  group('playback on hold', () {
    test(
      "a pause that is still coming doesn't bring the controls back",
      () async {
        final f = _file('a.mp3', now);
        await build([f]);
        final native = app.native as FakeNative;
        await app.refreshFiles();
        final file = app.files.single;
        await app.togglePlay(file);
        await app.togglePlay(file); // paused
        await settle();
        native.eventController.add(const MediaButton('dismiss'));
        await settle();
        int updates() =>
            calls.where((c) => c.method == 'updateMediaSession').length;
        final shown = updates();
        // It resumes by itself after a call; the player says it paused again
        // only a moment later.
        playback.pauseGate = Completer<void>();
        await playback.play(file.id, Uri.parse(file.id));
        await settle();
        expect(updates(), shown);
        playback.pauseGate!.complete();
        await settle();
        expect(playback.playing, isFalse);
        expect(updates(), shown);
      },
    );
  });

  test('toasts stay up longer for longer messages', () {
    expect(toastDuration('Saved'), const Duration(seconds: 2));
    expect(
      toastDuration('Saved', long: true),
      const Duration(milliseconds: 3500),
    );
    expect(toastDuration('x' * 80), const Duration(seconds: 5));
    expect(toastDuration('x' * 400), const Duration(seconds: 7));
  });
}
