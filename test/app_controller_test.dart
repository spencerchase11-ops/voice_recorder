import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/wav_writer.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';

import 'support/fakes.dart';

const _last = 'mem://kris n evan got back then zach.mp3';

void main() {
  late Directory work;
  late Settings settings;
  late FakeStore store;
  late FakeEngine engine;
  late FakePlayback playback;
  late AppController app;

  Future<AppController> build({
    Map<String, Object> prefs = const {
      'last_file': _last,
      'last_duration_ms': 2037000,
    },
    bool ready = true,
    bool isAndroid = false,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    settings = await Settings.load();
    store = FakeStore(
      files: referenceRecordings(),
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
      native: const NativeBridge(),
      workDir: () async => work,
      isAndroid: isAndroid,
      clock: () => DateTime(2026, 9, 23, 19, 14, 5),
    );
    addTearDown(app.dispose);
    return app;
  }

  setUp(() async => work = await Directory.systemTemp.createTemp('vr_ctrl'));
  tearDown(() => work.delete(recursive: true));

  group('init', () {
    test('restores the last recording and its length', () async {
      await (await build()).init();
      expect(app.currentFile?.name, 'kris n evan got back then zach.mp3');
      expect(formatTimer(app.timerValue), '33:57');
      expect(
        app.currentPath,
        '/storage/emulated/0/Recorders/kris n evan got back then zach.mp3',
      );
      expect(formatRemaining(app.remaining!), '9665:13:10');
    });

    test('forgets a last recording that no longer exists', () async {
      await (await build(
        prefs: {'last_file': 'mem://gone.mp3', 'last_duration_ms': 5000},
      )).init();
      expect(app.currentFile, isNull);
      expect(settings.lastFile, isNull);
      expect(app.timerValue, Duration.zero);
      expect(app.currentPath, isNull);
    });

    test('remembers the new id of a recording that moved', () async {
      await build(
        prefs: {
          'last_file': 'old://container/$_last',
          'last_duration_ms': 2037000,
        },
      );
      store.aliases['old://container/$_last'] = _last;
      await app.init();
      expect(app.currentFile?.id, _last);
      expect(settings.lastFile, _last);
      expect(formatTimer(app.timerValue), '33:57');
    });

    test('saves recordings interrupted by a crash', () async {
      final pending = Directory('${work.path}/pending')..createSync();
      File('${pending.path}/2026_09_22_08_00_00.mp3')
          .writeAsBytesSync(List.filled(4000, 7));
      File('${pending.path}/2026_09_22_09_00_00.mp3')
          .writeAsBytesSync(const []);
      File('${pending.path}/2026_09_22_10_00_00.wav').writeAsBytesSync([
        ...WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: 0),
        ...Uint8List(3201),
      ]);
      await (await build(prefs: const {})).init();

      expect(
        store.saved,
        unorderedEquals(['2026_09_22_08_00_00.mp3', '2026_09_22_10_00_00.wav']),
      );
      expect(pending.listSync(), isEmpty);
      final wav = store.files.firstWhere((f) => f.name.endsWith('.wav'));
      expect(wav.size, 44 + 3201);
      expect(app.currentFile, isNotNull);
    });

    test(
      'leaves interrupted recordings alone until a folder is chosen',
      () async {
        final pending = Directory('${work.path}/pending')..createSync();
        File('${pending.path}/a.mp3').writeAsBytesSync(List.filled(10, 1));
        await (await build(prefs: const {}, ready: false)).init();
        expect(store.saved, isEmpty);
        expect(await app.chooseFolder(), isTrue);
        expect(store.saved, ['a.mp3']);
      },
    );
  });

  group('recording', () {
    test(
      'records into the work directory and saves to the folder on stop',
      () async {
        await (await build()).init();
        expect(await app.toggleRecord(), RecordOutcome.started);
        expect(app.isRecording, isTrue);
        expect(engine.path, '${work.path}/pending/2026_09_23_19_14_05.mp3');
        expect(
          engine.profile,
          RecordingProfile.of(RecordingType.mp3, RecordingQuality.best),
        );
        expect(
          app.currentPath,
          '/storage/emulated/0/Recorders/2026_09_23_19_14_05.mp3',
        );
        expect(app.timerValue, lessThan(const Duration(seconds: 1)));

        engine.levelController.add(0.5);
        await Future<void>.delayed(Duration.zero);
        expect(app.litSegments, 6);

        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(await app.toggleRecord(), RecordOutcome.stopped);
        expect(app.isRecording, isFalse);
        expect(app.litSegments, 1);
        expect(store.saved, ['2026_09_23_19_14_05.mp3']);
        expect(File(engine.path!).existsSync(), isFalse);
        expect(app.currentFile?.name, '2026_09_23_19_14_05.mp3');
        expect(settings.lastFile, 'mem://2026_09_23_19_14_05.mp3');
        expect(formatTimer(app.timerValue), '00:01');
        await Future<void>.delayed(Duration.zero);
        expect(
          app.files.map((f) => f.name),
          contains('2026_09_23_19_14_05.mp3'),
        );
      },
    );

    test('uses the type chosen in Settings', () async {
      await (await build()).init();
      settings.type = RecordingType.wav;
      settings.quality = RecordingQuality.low;
      await app.toggleRecord();
      expect(engine.path, endsWith('/2026_09_23_19_14_05.wav'));
      expect(engine.profile?.sampleRate, 8000);
      await app.toggleRecord();
      expect(store.saved, ['2026_09_23_19_14_05.wav']);
    });

    test('asks for a folder first', () async {
      await (await build(ready: false)).init();
      expect(await app.toggleRecord(), RecordOutcome.needsFolder);
      expect(app.isRecording, isFalse);
      expect(engine.path, isNull);
      await app.chooseFolder();
      expect(await app.toggleRecord(), RecordOutcome.started);
      await app.toggleRecord();
    });

    test('a second tap while starting is ignored', () async {
      await (await build()).init();
      final first = app.toggleRecord();
      expect(await app.toggleRecord(), RecordOutcome.busy);
      expect(await first, RecordOutcome.started);
      await app.toggleRecord();
    });

    test('a recording that cannot be saved is kept for later', () async {
      await (await build()).init();
      await app.toggleRecord();
      store.failSaves = true;
      expect(await app.toggleRecord(), RecordOutcome.notSaved);
      expect(app.isRecording, isFalse);
      final pending = Directory('${work.path}/pending').listSync();
      expect(pending, hasLength(1));
      expect(app.currentFile?.id, _last); // unchanged
      store.failSaves = false;
      await app.recoverInterrupted();
      expect(store.saved, ['2026_09_23_19_14_05.mp3']);
      expect(Directory('${work.path}/pending').listSync(), isEmpty);
    });

    test('reports a missing microphone permission', () async {
      await (await build()).init();
      engine.permission = false;
      expect(await app.toggleRecord(), RecordOutcome.noPermission);
      expect(app.isRecording, isFalse);
      expect(app.isBusy, isFalse);
    });

    test('stops playback before recording', () async {
      await (await build()).init();
      await app.togglePlayCurrent();
      expect(app.isPlayingCurrent, isTrue);
      await app.toggleRecord();
      expect(playback.fileId, isNull);
      await app.togglePlayCurrent(); // ignored while recording
      expect(playback.played, [_last]);
      await app.toggleRecord();
    });

    test(
      'pauses the timer while an interruption (a call) holds the microphone',
      () async {
        await (await build()).init();
        await app.toggleRecord();
        engine.interruptController.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(app.isInterrupted, isTrue);
        final t = app.timerValue;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(app.timerValue, t);
        engine.interruptController.add(false);
        await Future<void>.delayed(Duration.zero);
        expect(app.isInterrupted, isFalse);
        await app.toggleRecord();
      },
    );

    test('runs the Android foreground service around a recording', () async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.spencerchase.voicerecorder/native');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await (await build(isAndroid: true)).init();
      await app.toggleRecord();
      expect(calls, ['startRecordingService']);
      await app.toggleRecord();
      expect(calls, ['startRecordingService', 'stopRecordingService']);
    });
  });

  group('files', () {
    test('lists newest first', () async {
      await (await build()).init();
      await app.refreshFiles();
      expect(app.files.first.name, 'kris n evan got back then zach.mp3');
      expect(app.files.last.name, '2026_09_16_15_48_15.mp3');
    });

    test('playback drives the timer', () async {
      await (await build()).init();
      await app.togglePlayCurrent();
      playback.setPosition(const Duration(minutes: 1, seconds: 2));
      expect(formatTimer(app.timerValue), '01:02');
      await app.togglePlayCurrent();
      expect(app.isPlayingCurrent, isFalse);
      expect(formatTimer(app.timerValue), '01:02');
    });

    test(
      'rename keeps the extension and updates the current recording',
      () async {
        await (await build()).init();
        await app.refreshFiles();
        final renamed = await app.rename(
          app.currentFile!,
          '  kris/evan: part 2 ',
        );
        expect(renamed?.name, 'kris_evan_ part 2.mp3');
        expect(app.currentFile?.name, 'kris_evan_ part 2.mp3');
        expect(settings.lastFile, 'mem://kris_evan_ part 2.mp3');
        expect(formatTimer(app.timerValue), '33:57');
        expect(app.files.map((f) => f.name), contains('kris_evan_ part 2.mp3'));
      },
    );

    test('rename to an empty or unchanged name does nothing', () async {
      await (await build()).init();
      final cur = app.currentFile!;
      expect(await app.rename(cur, '   '), same(cur));
      expect(
        await app.rename(cur, 'kris n evan got back then zach'),
        same(cur),
      );
      expect(store.files.map((f) => f.name), contains(cur.name));
    });

    test('delete removes the file and clears the Recorder screen', () async {
      await (await build()).init();
      await app.refreshFiles();
      await app.togglePlayCurrent();
      expect(await app.delete(app.currentFile!), isTrue);
      expect(playback.fileId, isNull);
      expect(app.currentFile, isNull);
      expect(settings.lastFile, isNull);
      expect(app.timerValue, Duration.zero);
      expect(app.files, hasLength(9));
      expect(store.files, hasLength(9));
    });

    test('a file that fails to open can be retried', () async {
      await (await build()).init();
      playback.broken.add(_last);
      expect(await app.togglePlayCurrent(), isFalse);
      expect(playback.fileId, isNull);
      playback.broken.clear();
      expect(await app.togglePlayCurrent(), isTrue);
      expect(app.isPlayingCurrent, isTrue);
    });

    test('seek loads a file paused and moves to the fraction', () async {
      await (await build()).init();
      final f = store.files.firstWhere((f) => f.name.startsWith('2026_09_20'));
      expect(await app.seek(f, 0.5), isTrue);
      expect(playback.fileId, f.id);
      expect(playback.playing, isFalse);
      expect(playback.position, const Duration(minutes: 1, seconds: 30));
      playback.broken.add('mem://missing.mp3');
      final missing = f.copyWith(id: 'mem://missing.mp3');
      expect(await app.seek(missing, 0.5), isFalse);
    });

    test(
      'on resume, a last recording deleted elsewhere is forgotten',
      () async {
        await (await build()).init();
        await app.togglePlayCurrent();
        store.files.removeWhere((f) => f.id == _last);
        store.free = referenceFreeBytes ~/ 2;
        await app.onResume();
        expect(app.currentFile, isNull);
        expect(settings.lastFile, isNull);
        expect(playback.fileId, isNull);
        expect(formatRemaining(app.remaining!), '4832:36:35');
      },
    );

    test('on resume, an unreachable folder keeps the last recording', () async {
      await (await build()).init();
      final throwing = _ThrowingFind(store);
      final app2 = AppController(
        settings: settings,
        store: throwing,
        engine: engine,
        playback: playback,
        native: const NativeBridge(),
        workDir: () async => work,
      );
      addTearDown(app2.dispose);
      await app2.init(); // find() throws: no current file yet
      expect(app2.currentFile, isNull);
      throwing.fail = false;
      await app2.init();
      expect(app2.currentFile?.id, _last);
      throwing.fail = true;
      await app2.onResume();
      expect(app2.currentFile?.id, _last);
    });

    test('share goes to the store', () async {
      await (await build()).init();
      await app.share(app.currentFile!);
      expect(store.shared, ['kris n evan got back then zach.mp3']);
    });

    test('remaining time follows the recording settings', () async {
      await (await build()).init();
      settings.type = RecordingType.wav; // 88200 B/s instead of 20000 B/s
      await Future<void>.delayed(Duration.zero);
      expect(
        app.remaining,
        RecordingProfile.of(
          RecordingType.wav,
          RecordingQuality.best,
        ).remainingFor(referenceFreeBytes),
      );
      store.free = null;
      await app.refreshRemaining();
      expect(app.remaining, isNull);
    });
  });
}

/// A store whose lookups fail while [fail] is set (storage unreachable).
class _ThrowingFind extends FakeStore {
  _ThrowingFind(FakeStore base)
    : super(files: base.files, free: base.free, ready: base.ready);

  bool fail = true;

  @override
  Future<RecordingFile?> find(String id) {
    if (fail) throw StateError('storage unreachable');
    return super.find(id);
  }
}
