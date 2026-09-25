import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/audio/wav_writer.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';

import 'support/fakes.dart';

const _last = 'mem://kris n evan got back then zach.mp3';

final wavBest = RecordingProfile.of(RecordingType.wav, RecordingQuality.best);

void main() {
  late Directory work;
  late Settings settings;
  late FakeStore store;
  late FakeEngine engine;
  late FakePlayback playback;
  late FakeNative native;
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
    native = FakeNative();
    app = AppController(
      settings: settings,
      store: store,
      engine: engine,
      playback: playback,
      native: native,
      workDir: () async => work,
      isAndroid: isAndroid,
      clock: () => DateTime(2026, 9, 23, 19, 14, 5),
    );
    addTearDown(app.dispose);
    return app;
  }

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_ctrl');
    // The platform side answers nothing (tests that look at the calls mock
    // it themselves).
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
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
      // The half sample at the end is dropped; the date chunk (40 bytes)
      // is added.
      expect(wav.size, 44 + 3200 + 40);
      expect(app.currentFile, isNotNull);
      // Both carry their recording date inside now.
      for (final name in ['2026_09_22_10_00_00.wav']) {
        final info = await readAudioInfo(
          MemoryBytes(store.savedBytes[name]!),
          name,
        );
        expect(info.recorded, DateTime(2026, 9, 22, 10));
        expect(info.duration, const Duration(milliseconds: 100));
      }
    });

    test('drops empty recordings and keeps cut-off M4A files out', () async {
      List<int> box(String type, int length, {int? size}) {
        final b = ByteData(8)..setUint32(0, size ?? length + 8);
        for (var i = 0; i < 4; i++) {
          b.setUint8(4 + i, type.codeUnitAt(i));
        }
        return [...b.buffer.asUint8List(), ...List.filled(length, 1)];
      }

      final pending = Directory('${work.path}/pending')..createSync();
      File('${pending.path}/a.wav').writeAsBytesSync(
        WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: 0),
      );
      File('${pending.path}/b.m4a')
          .writeAsBytesSync([...box('ftyp', 16), ...box('mdat', 500, size: 0)]);
      File('${pending.path}/c.m4a').writeAsBytesSync([
        ...box('ftyp', 16),
        ...box('mdat', 500),
        ...box('moov', 50),
      ]);
      await build(prefs: const {});
      final notices = <String>[];
      app.notices.listen(notices.add);
      await app.init();
      await Future<void>.delayed(Duration.zero);

      expect(store.saved, ['c.m4a']);
      expect(File('${pending.path}/a.wav').existsSync(), isFalse);
      expect(File('${pending.path}/b.m4a.incomplete').existsSync(), isTrue);
      expect(notices, hasLength(1));

      // Later recoveries leave it alone.
      await app.recoverInterrupted();
      await Future<void>.delayed(Duration.zero);
      expect(store.saved, ['c.m4a']);
      expect(notices, hasLength(1));
    });

    test('messages from before anyone listened are delivered later', () async {
      final pending = Directory('${work.path}/pending')..createSync();
      File('${pending.path}/x.m4a').writeAsBytesSync(List.filled(64, 0));
      await (await build(prefs: const {})).init(); // nobody listening yet
      final notices = <String>[];
      app.notices.listen(notices.add);
      await Future<void>.delayed(Duration.zero);
      expect(notices, hasLength(1));
    });

    test(
      'a recording saved later becomes the Recorder screen recording',
      () async {
        await (await build()).init();
        await app.toggleRecord();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        store.failSaves = true;
        expect(await app.toggleRecord(), RecordOutcome.notSaved);
        expect(app.currentFile?.id, _last);
        store.failSaves = false;
        await app.chooseFolder();
        expect(app.currentFile?.name, '2026_09_23_19_14_05.mp3');
        expect(settings.lastFile, 'mem://2026_09_23_19_14_05.mp3');
        expect(formatTimer(app.timerValue), '00:01');
      },
    );

    test('a recovered recording is remembered, with its length', () async {
      final pending = Directory('${work.path}/pending')..createSync();
      File('${pending.path}/2026_09_24_07_00_00.wav').writeAsBytesSync([
        ...WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: 0),
        ...Uint8List(32000 * 3), // 3 s
      ]);
      await (await build()).init();
      expect(app.currentFile?.name, '2026_09_24_07_00_00.wav');
      expect(settings.lastFile, 'mem://2026_09_24_07_00_00.wav');
      expect(formatTimer(app.timerValue), '00:03');
    });

    test('unplayable leftovers are cleaned up after a week', () async {
      final pending = Directory('${work.path}/pending')..createSync();
      final old = File('${pending.path}/a.m4a.incomplete')
        ..writeAsBytesSync([1])
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
      final recent = File('${pending.path}/b.m4a.incomplete')
        ..writeAsBytesSync([1]);
      await (await build()).init();
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
    });

    test(
      'choosing another folder forgets a last recording not in it',
      () async {
        await (await build()).init();
        store.files.removeWhere((f) => f.id == _last);
        expect(await app.chooseFolder(), isTrue);
        expect(app.currentFile, isNull);
        expect(settings.lastFile, isNull);
      },
    );

    test(
      'leaves interrupted recordings alone until a folder is chosen',
      () async {
        final pending = Directory('${work.path}/pending')..createSync();
        File('${pending.path}/a.mp3').writeAsBytesSync(List.filled(100, 1));
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

    test(
      'iOS: the audio session sample rate is restored after recording',
      () async {
        final calls = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel('com.spencerchase.voicerecorder/native');
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await (await build()).init();
        await app.toggleRecord();
        await app.toggleRecord();
        await Future<void>.delayed(Duration.zero);
        expect(calls, contains('resetAudioSampleRate'));
      },
    );

    test('capture that ends on its own is stopped, saved and reported', () async {
      await (await build()).init();
      final notices = <String>[];
      app.notices.listen(notices.add);
      await app.toggleRecord();
      engine.endedController.add(CaptureEnd.stopped);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(app.isRecording, isFalse);
      expect(store.saved, ['2026_09_23_19_14_05.mp3']);
      expect(notices, [
        'The recording stopped unexpectedly. What was recorded has been saved.',
      ]);
    });

    test('running out of storage stops and saves the recording', () async {
      await (await build()).init();
      final notices = <String>[];
      app.notices.listen(notices.add);
      await app.toggleRecord();
      store.free = 20000 * 20; // 20 s left at 160 kbps
      await app.checkSpace();
      await Future<void>.delayed(Duration.zero);
      expect(app.isRecording, isFalse);
      expect(store.saved, hasLength(1));
      expect(notices.single, startsWith('Storage is almost full'));
    });

    test('no recording starts without room for it', () async {
      await (await build()).init();
      store.free = 20000 * 10;
      expect(await app.toggleRecord(), RecordOutcome.noSpace);
      expect(engine.path, isNull);
      expect(app.isRecording, isFalse);
    });

    test(
      'a WAV whose recorder failed to stop is repaired before saving',
      () async {
        await (await build()).init();
        settings.type = RecordingType.wav;
        engine
          ..content = [
            ...WavWriter.header(sampleRate: 44100, channels: 1, dataBytes: 0),
            ...List.filled(1000, 5),
          ]
          ..stopError = StateError('recorder failed');
        await app.toggleRecord();
        expect(await app.toggleRecord(), RecordOutcome.stopped);
        final saved = Uint8List.fromList(
          store.savedBytes['2026_09_23_19_14_05.wav']!,
        );
        expect(ByteData.sublistView(saved).getUint32(40, Endian.little), 1000);
      },
    );

    test(
      'an interruption zeroes the meter; returning to the app resumes',
      () async {
        await (await build()).init();
        await app.toggleRecord();
        engine.levelController.add(0.8);
        await Future<void>.delayed(Duration.zero);
        expect(app.litSegments, greaterThan(1));
        engine.interruptController.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(app.litSegments, 1);
        await app.onResume();
        expect(engine.resumes, 1);
        await app.toggleRecord();
      },
    );

    test(
      'storage failing mid-recording stops it with an explanation',
      () async {
        await (await build()).init();
        final notices = <String>[];
        app.notices.listen(notices.add);
        await app.toggleRecord();
        engine.endedController.add(CaptureEnd.writeFailed);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(app.isRecording, isFalse);
        expect(notices.single, contains("couldn't be written"));
      },
    );

    test(
      'remaining time follows the running recording, not Settings',
      () async {
        await (await build()).init();
        settings.quality = RecordingQuality.low; // MP3 32 kbit/s
        await app.toggleRecord();
        settings
          ..type = RecordingType.wav
          ..quality = RecordingQuality.best; // for the next recording
        await app.refreshRemaining();
        final low = RecordingProfile.of(
          RecordingType.mp3,
          RecordingQuality.low,
        );
        expect(app.remaining, low.remainingFor(referenceFreeBytes));
        await app.toggleRecord();
        await app.refreshRemaining();
        expect(app.remaining, wavBest.remainingFor(referenceFreeBytes));
      },
    );

    test(
      'play is refused while a recording starts, and stopped before it',
      () async {
        await (await build()).init();
        engine.startGate = Completer<void>();
        final starting = app.toggleRecord();
        await Future<void>.delayed(Duration.zero);
        expect(await app.togglePlayCurrent(), PlayOutcome.recording);
        engine.startGate!.complete();
        expect(await starting, RecordOutcome.started);
        expect(playback.playing, isFalse);
        await app.toggleRecord();
      },
    );

    test('messages wait while the app is in the background', () async {
      await (await build()).init();
      final notices = <String>[];
      app.notices.listen(notices.add);
      await app.toggleRecord();
      app.setForeground(false);
      engine.endedController.add(CaptureEnd.stopped);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(app.isRecording, isFalse);
      expect(notices, isEmpty);
      app.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(notices, hasLength(1));
    });

    test(
      "a recording that can't continue yet stays paused (a call goes on)",
      () async {
        await (await build()).init();
        final notices = <String>[];
        app.notices.listen(notices.add);
        await app.toggleRecord();
        engine.interruptController.add(true);
        await Future<void>.delayed(Duration.zero);
        // Back in the app during the call: the microphone is still taken.
        engine.resumeError = StateError('microphone still in use');
        await app.onResume();
        await Future<void>.delayed(Duration.zero);
        expect(app.isRecording, isTrue);
        expect(app.isInterrupted, isTrue);
        expect(store.saved, isEmpty);
        expect(notices, isEmpty);
        // The call ends; the recording goes on, and is saved when stopped.
        engine.resumeError = null;
        engine.interruptController.add(false);
        await Future<void>.delayed(Duration.zero);
        expect(app.isInterrupted, isFalse);
        await app.toggleRecord();
        expect(store.saved, hasLength(1));
      },
    );

    test('an M4A the recorder failed to finish is not saved', () async {
      await (await build()).init();
      settings.type = RecordingType.m4a;
      engine.content = List.filled(500, 0); // no MP4 index
      await app.toggleRecord();
      expect(await app.toggleRecord(), RecordOutcome.failed);
      expect(store.saved, isEmpty);
      expect(
        File('${work.path}/pending/2026_09_23_19_14_05.m4a.incomplete')
            .existsSync(),
        isTrue,
      );
    });

    test('recording waits for the app to finish starting up', () async {
      await build();
      final pending = app.toggleRecord(); // before init()
      await app.init();
      expect(await pending, RecordOutcome.started);
      await app.toggleRecord();
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
        // Note how many files were saved when each call arrives.
        calls.add('${call.method}:${store.saved.length}');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await (await build(isAndroid: true)).init();
      Iterable<String> service() => calls.where((c) => c.contains('Service'));
      await app.toggleRecord();
      await Future<void>.delayed(Duration.zero);
      // Started, then its timer set to the recording's.
      expect(service(), [
        'startRecordingService:0',
        'updateRecordingService:0',
      ]);
      await app.toggleRecord();
      // The service keeps the process alive until the file is in the folder.
      expect(service().last, 'stopRecordingService:1');
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

    test('delete moves the file to Recently deleted and clears the Recorder '
        'screen; undo brings both back', () async {
      await (await build()).init();
      await app.refreshFiles();
      await app.togglePlayCurrent();
      final deleted = await app.delete([app.currentFile!]);
      expect(deleted.items.single.originalName, _last.substring(6));
      expect(deleted.failed, 0);
      expect(playback.fileId, isNull);
      expect(app.currentFile, isNull);
      expect(settings.lastFile, isNull);
      expect(app.timerValue, Duration.zero);
      expect(app.files, hasLength(9));
      expect(await store.list(), hasLength(9));
      expect(await app.deletedRecordings(), hasLength(1));

      expect(await app.undoDelete(deleted), 1);
      expect(app.files, hasLength(10));
      expect(app.currentFile?.name, _last.substring(6));
      expect(settings.lastDuration, const Duration(minutes: 33, seconds: 57));
      expect(await app.deletedRecordings(), isEmpty);
    });

    test(
      'timestamp names order the list even when file dates were reset',
      () async {
        await build();
        // As after a phone transfer: every file dated the day of the copy.
        final copied = DateTime(2026, 9, 24, 8);
        store.files
          ..clear()
          ..addAll([
            for (final n in [
              '2026_09_16_15_48_15.mp3',
              'lunch w kris team convo .mp3',
              '2026_09_20_17_26_27.mp3',
              '2026_09_18_21_23_04.mp3',
            ])
              RecordingFile(id: 'mem://$n', name: n, size: 1, modified: copied),
          ]);
        await app.refreshFiles();
        expect(app.files.map((f) => f.name), [
          'lunch w kris team convo .mp3', // no date in the name: copy date
          '2026_09_20_17_26_27.mp3',
          '2026_09_18_21_23_04.mp3',
          '2026_09_16_15_48_15.mp3',
        ]);
      },
    );

    test('a library of 2,500 recordings lists quickly and in order', () async {
      await build();
      final start = DateTime(2016, 3, 1, 9);
      store.files
        ..clear()
        ..addAll(
          [
            for (var i = 0; i < 2500; i++)
              () {
                final t = start.add(Duration(hours: 29 * i, seconds: i));
                final name = '${timestampName(t)}.mp3';
                return RecordingFile(
                  id: 'mem://$name',
                  name: name,
                  size: 25000000,
                  modified: t,
                );
              }(),
          ]..shuffle(),
        );
      final watch = Stopwatch()..start();
      await app.refreshFiles();
      watch.stop();
      expect(app.files, hasLength(2500));
      for (var i = 1; i < app.files.length; i++) {
        expect(app.files[i - 1].date.isAfter(app.files[i].date), isTrue);
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('a file that fails to open can be retried', () async {
      await (await build()).init();
      playback.broken.add(_last);
      expect(await app.togglePlayCurrent(), PlayOutcome.notPlayable);
      expect(playback.fileId, isNull);
      playback.broken.clear();
      expect(await app.togglePlayCurrent(), PlayOutcome.ok);
      expect(app.isPlayingCurrent, isTrue);
    });

    test(
      'playback refused by the system (a call) is reported as such',
      () async {
        await (await build()).init();
        playback.audioBusy = true;
        expect(await app.togglePlayCurrent(), PlayOutcome.audioBusy);
        expect(app.isPlayingCurrent, isFalse);
        playback.audioBusy = false;
        expect(await app.togglePlayCurrent(), PlayOutcome.ok);
        expect(app.isPlayingCurrent, isTrue);
      },
    );

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
      await build();
      AppController open(FakeStore s) {
        final c = AppController(
          settings: settings,
          store: s,
          engine: engine,
          playback: playback,
          native: NativeBridge(),
          workDir: () async => work,
        );
        addTearDown(c.dispose);
        return c;
      }

      // Storage unreachable at start: the last recording isn't forgotten.
      final throwing = _ThrowingFind(store);
      final first = open(throwing);
      await first.init();
      expect(first.currentFile, isNull);
      expect(settings.lastFile, _last);

      // Next start with storage back: it is shown again.
      throwing.fail = false;
      final second = open(throwing);
      await second.init();
      expect(second.currentFile?.id, _last);

      // Unreachable again on resume: still shown.
      throwing.fail = true;
      await second.onResume();
      expect(second.currentFile?.id, _last);
    });

    test('share goes to the store', () async {
      await (await build()).init();
      await app.shareAll([app.currentFile!]);
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
