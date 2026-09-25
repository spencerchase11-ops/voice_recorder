// Behaviour fixed after the third audit: playback that mustn't run,
// Recently deleted edge cases, dates kept on rename, and the date cache.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/storage/info_cache.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';
import 'package:voice_recorder/src/ui/screens/common_actions.dart';

import 'support/fakes.dart';

const _last = 'mem://kris n evan got back then zach.mp3';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  late Settings settings;
  late FakeStore store;
  late FakeEngine engine;
  late FakePlayback playback;
  late AppController app;
  var now = DateTime(2026, 9, 23, 19, 14, 5);

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_audit');
    now = DateTime(2026, 9, 23, 19, 14, 5);
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
  tearDown(() => work.delete(recursive: true));

  Future<AppController> build({
    List<RecordingFile>? files,
    Map<String, Object> prefs = const {
      'last_file': _last,
      'last_duration_ms': 2037000,
    },
    RecordingInfoCache? info,
    bool ready = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    settings = await Settings.load();
    store = FakeStore(
      files: files ?? referenceRecordings(),
      free: referenceFreeBytes,
      ready: ready,
    );
    engine = FakeEngine();
    playback = FakePlayback();
    app = AppController(
      settings: settings,
      store: store,
      engine: engine,
      playback: playback,
      native: FakeNative(),
      workDir: () async => work,
      info: info,
      clock: () => now,
    );
    addTearDown(app.dispose);
    await app.init();
    return app;
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('playback that must not run', () {
    test('a file still opening when Record is tapped never plays', () async {
      await build();
      final gate = playback.loadGate = Completer<void>();
      final playing = app.togglePlay(app.currentFile!);
      await settle();
      expect(playback.fileId, isNull); // still opening
      expect(await app.toggleRecord(), RecordOutcome.started);
      gate.complete();
      await playing;
      await settle();
      expect(playback.playing, isFalse);
      expect(playback.played, isEmpty);
      await app.toggleRecord();
    });

    test('starting in the background with lock-screen controls off', () async {
      await build();
      settings.lockScreenControls = false;
      final gate = playback.loadGate = Completer<void>();
      final playing = app.togglePlay(app.currentFile!);
      app.setForeground(false); // left the app while it opened
      gate.complete();
      await playing;
      await settle();
      expect(playback.playing, isFalse);
      // With the controls on, it plays on in the background.
      app.setForeground(true);
      settings.lockScreenControls = true;
      await app.togglePlay(app.currentFile!);
      app.setForeground(false);
      await settle();
      expect(playback.playing, isTrue);
    });
  });

  group('Recently deleted', () {
    test('a wrong clock still deletes into Recently deleted', () async {
      now = DateTime(2024, 1, 1); // a phone that lost the time
      await build();
      await app.refreshFiles();
      final f = app.files.first;
      final deleted = await app.delete([f]);
      expect(deleted.items, hasLength(1));
      final trash = (await app.deletedRecordings())!;
      expect(trash.single.originalName, f.name);
    });

    test(
      'a folder that changes the hidden name: the file is put back',
      () async {
        await build();
        await app.refreshFiles();
        final f = app.files.first;
        store.alterName = (name) =>
            name.startsWith('.') ? name.substring(1) : name;
        final deleted = await app.delete([f]);
        expect(deleted.items, isEmpty);
        expect(deleted.failed, 1);
        expect(store.files.map((x) => x.name), contains(f.name));
      },
    );

    test('an undo that fails says so, and the rest comes back', () async {
      await build();
      await app.refreshFiles();
      final notices = <String>[];
      app.notices.listen(notices.add);
      final targets = app.files.sublist(0, 3);
      final deleted = await app.delete(targets);
      // One of them was deleted for good meanwhile (elsewhere).
      store.files.removeWhere((x) => x.id == deleted.items[1].file.id);
      expect(await app.undoDelete(deleted), 2);
      await settle();
      expect(notices.single, contains("couldn't be put back"));
      expect(app.files, hasLength(9));
    });

    test('an undo of many is sorted like the list', () async {
      await build();
      await app.refreshFiles();
      final before = [...app.files.map((f) => f.name)];
      final deleted = await app.delete([...app.files]);
      expect(app.files, isEmpty);
      await app.undoDelete(deleted);
      expect(app.files.map((f) => f.name), before);
    });

    test(
      'expired recordings go while the app runs, and are never listed',
      () async {
        await build();
        await app.refreshFiles();
        await app.delete([app.files.first]);
        now = now.add(const Duration(days: 31));
        // Listed: gone (deleted for good first).
        expect(await app.deletedRecordings(), isEmpty);
        expect(store.deletedForGood, hasLength(1));

        await app.delete([app.files.first]);
        now = now.add(const Duration(days: 31));
        await app.onResume(); // hours later: cleared on return
        await settle();
        expect(store.deletedForGood, hasLength(2));
      },
    );

    test("the trash version changes, for the screens that show it", () async {
      await build();
      await app.refreshFiles();
      final v = app.trashVersion;
      final deleted = await app.delete([app.files.first]);
      expect(app.trashVersion, greaterThan(v));
      final w = app.trashVersion;
      await app.undoDelete(deleted);
      expect(app.trashVersion, greaterThan(w));
    });
  });

  group('names and dates', () {
    test('typing the extension does not double it', () async {
      await build();
      await app.refreshFiles();
      final f = app.files.firstWhere(
        (x) => x.name == '2026_09_20_17_26_27.mp3',
      );
      final renamed = await app.rename(f, 'meeting notes.MP3');
      expect(renamed!.name, 'meeting notes.mp3');
    });

    test("an old M4A keeps its start time (the name's) when renamed", () async {
      // Made by the original app: stamped when it stopped, 30 minutes later.
      final start = DateTime(2016, 9, 18, 23, 40);
      final m4a = RecordingFile(
        id: 'mem://2016_09_18_23_40_00.m4a',
        name: '2016_09_18_23_40_00.m4a',
        size: 1,
        modified: DateTime(2026),
      );
      await build(files: [...referenceRecordings(), m4a]);
      store.contents[m4a.id] = _m4a(
        seconds: 1800,
        created: start.add(const Duration(minutes: 30)),
      );
      await app.refreshFiles();
      final renamed = await app.rename(
        app.files.firstWhere((x) => x.id == m4a.id),
        'night walk',
      );
      expect(renamed!.date, start);
      // And it is stored in the file.
      final info = await readAudioInfo(
        MemoryBytes(store.contents[renamed.id]!),
        renamed.name,
      );
      expect(info.recorded, start);
    });

    test('the date cache survives a folder that is out of reach', () async {
      final info = RecordingInfoCache();
      await build(info: info);
      await app.refreshFiles();
      final f = app.files.first;
      info.put(f, AudioInfo(recorded: DateTime(2016), duration: Duration.zero));
      store.ready = false; // access lost: the list is empty
      await app.refreshFiles();
      expect(info.contains(f), isTrue);
    });

    test('an M4A is saved with its length from the file', () async {
      await build();
      settings.type = RecordingType.m4a;
      engine.content = _m4a(seconds: 90, created: now);
      await app.toggleRecord();
      await app.toggleRecord();
      final saved = store.files.last;
      expect(saved.name, endsWith('.m4a'));
      expect(settings.lastDuration, const Duration(seconds: 90));
    });
  });

  group('many recordings', () {
    test(
      'every renamed recording is read for its date, not just 200',
      () async {
        // 300 renamed recordings, their dates stored inside, all with the same
        // file time (copied to this phone in one go).
        final copied = DateTime(2026, 9, 20);
        final many = [
          for (var i = 0; i < 300; i++)
            RecordingFile(
              id: 'mem://note $i.mp3',
              name: 'note $i.mp3',
              size: 1,
              modified: copied,
            ),
        ];
        await build(files: many, prefs: const {});
        for (var i = 0; i < 300; i++) {
          store.contents['mem://note $i.mp3'] = [
            ...id3DateTag(DateTime(2016).add(Duration(days: i))),
            for (var f = 0; f < 3; f++) ...[
              0xFF,
              0xFB,
              0xA0,
              0xC0,
              ...List.filled(518, 0),
            ],
          ];
        }
        await app.refreshFiles();
        for (
          var i = 0;
          i < 300 && app.files.any((f) => f.recorded == null);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(app.files.where((f) => f.recorded == null), isEmpty);
        // In the order they were recorded, newest first.
        expect(app.files.first.name, 'note 299.mp3');
        expect(app.files.last.name, 'note 0.mp3');
      },
    );
  });

  group('iPhone import', () {
    test('progress while it runs, then what it did', () async {
      final docs = await Directory.systemTemp.createTemp('ios_docs');
      addTearDown(() => docs.delete(recursive: true));
      final native = FakeNative();
      final answer = Completer<Map<String, int>>();
      const channel = MethodChannel('com.spencerchase.voicerecorder/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async =>
                call.method == 'importRecordings' ? answer.future : null,
          );
      SharedPreferences.setMockInitialValues({});
      final ios = IosRecordingStore(native, documents: () async => docs);
      final app = AppController(
        settings: await Settings.load(),
        store: ios,
        engine: FakeEngine(),
        playback: FakePlayback(),
        native: native,
        workDir: () async => work,
      );
      addTearDown(app.dispose);
      await app.init();

      final running = app.importRecordings();
      await settle();
      expect(app.importProgress, isNull); // the picker is still open
      native.eventController.add(const ImportProgress(0, 0));
      await settle();
      expect(app.importProgress, (done: 0, total: 0)); // looking
      native.eventController.add(const ImportProgress(1200, 2464));
      await settle();
      expect(app.importProgress, (done: 1200, total: 2464));
      expect(await app.importRecordings(), isNull); // one at a time
      answer.complete({'copied': 2400, 'skipped': 60, 'failed': 4});
      expect(await running, (copied: 2400, skipped: 60, failed: 4));
      expect(app.importProgress, isNull);
    });

    test('the message says what happened', () {
      expect(
        importMessage((copied: 2400, skipped: 60, failed: 4)),
        "2,400 recordings imported. 60 were already here. 4 couldn't be "
        'copied. Is the iPhone full?',
      );
      expect(
        importMessage((copied: 1, skipped: 1, failed: 0)),
        '1 recording imported. 1 was already here.',
      );
      expect(
        importMessage((copied: 0, skipped: 12, failed: 0)),
        'Nothing new to import. 12 were already here.',
      );
      expect(
        importMessage((copied: 0, skipped: 0, failed: 0)),
        'No recordings were found there (MP3, WAV, M4A, AAC or FLAC).',
      );
    });
  });

  test('an MP3 cut off before any sound is not recovered', () async {
    final pending = Directory('${work.path}/pending')..createSync();
    final f = File('${pending.path}/2026_09_23_19_00_00.mp3')
      ..writeAsBytesSync(id3DateTag(DateTime(2026, 9, 23, 19)));
    await build();
    expect(store.saved, isEmpty);
    expect(f.existsSync(), isFalse);
  });

  test('sharing is limited to $maxShareCount recordings', () async {
    final many = [
      for (var i = 0; i < maxShareCount + 1; i++)
        RecordingFile(
          id: 'mem://$i.mp3',
          name: '$i.mp3',
          size: 1,
          modified: DateTime(2026),
        ),
    ];
    await build(files: many);
    expect(await app.shareAll(many), isFalse);
    expect(store.shared, isEmpty);
    expect(await app.shareAll(many.sublist(1)), isTrue);
    expect(store.shared, hasLength(maxShareCount));
  });

  test(
    'a second pause tap while the first is carried out is ignored',
    () async {
      await build();
      await app.toggleRecord();
      final gate = engine.pauseGate = Completer<void>();
      final first = app.togglePauseRecording();
      expect(await app.togglePauseRecording(), isTrue); // not a failure
      gate.complete();
      expect(await first, isTrue);
      expect(engine.pauses, 1);
      expect(app.isPaused, isTrue);
      await app.toggleRecord();
    },
  );
}
