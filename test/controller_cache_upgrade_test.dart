// Phones that update from 1.0.0 or 1.0.1 keep the dates that release left
// in its cache, and lose the copy times it cached on iPhone.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/storage/info_cache.dart';

import 'support/fakes.dart';
import 'support/info_cache_1_0.dart';

/// [count] MPEG-1 Layer III frames, no tags: no date inside.
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
  late File cacheFile;
  late FakeStore store;
  late AppController app;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('vr_cache_upgrade');
    cacheFile = File('${work.path}/recording_info.json');
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });
  tearDown(() => work.delete(recursive: true));

  /// Leaves the cache 1.0.x would have left, with [info] for [f].
  Future<void> cachedBy10(RecordingFile f, AudioInfo info) async {
    final old = RecordingInfoCache10(file: () async => cacheFile)..put(f, info);
    await old.save();
    old.dispose();
  }

  /// The updated app on [store], started (the cache as main.dart makes it).
  Future<void> start() async {
    SharedPreferences.setMockInitialValues({});
    final controller = app = AppController(
      settings: await Settings.load(),
      store: store,
      engine: FakeEngine(),
      playback: FakePlayback(),
      native: FakeNative(),
      workDir: () async => work,
      clock: () => DateTime(2026, 11, 8, 12),
      info: RecordingInfoCache(
        file: () async => cacheFile,
        fileTimesAreDates: store.fileTimesAreDates,
      ),
    );
    addTearDown(controller.dispose);
    await controller.init();
  }

  RecordingFile row(String name) =>
      app.files.singleWhere((f) => f.name == name);

  test("iPhone: a copy time 1.0.1 cached doesn't hide a date typed into the "
      'name', () async {
    // lunch.aac came from Files with no date (its time is when it was
    // copied), and 1.0.1 renamed it: it cached that time as its date.
    final copied = DateTime(2026, 9, 24, 9, 30, 0, 123, 456);
    final f = _file('team lunch.aac', copied);
    await cachedBy10(
      f,
      AudioInfo(recorded: copied, duration: const Duration(seconds: 42)),
    );
    store = FakeStore(files: [f], free: 1 << 30)..timesAreDates = false;
    await start();
    await app.refreshFiles();
    final renamed = await app.rename(row(f.name), '2016_05_23_18_14_00 lunch');
    expect(renamed!.date, DateTime(2016, 5, 23, 18, 14));
    expect(app.files.single.date, DateTime(2016, 5, 23, 18, 14));
  });

  test(
    'a date 1.0.x kept only in its cache survives Recently deleted',
    () async {
      // 1.0.x renamed 2016_05_23_18_14_00.mp3 to lunch, and couldn't write
      // the date into the file (refused, or the storage was full): only its
      // cache has it, unmarked.
      final f = _file('lunch.mp3', DateTime(2016, 5, 23, 18, 44));
      final recorded = DateTime(2016, 5, 23, 18, 14);
      await cachedBy10(
        f,
        AudioInfo(recorded: recorded, duration: const Duration(seconds: 1)),
      );
      store = FakeStore(
        files: [f, _file('b.mp3', DateTime(2026))],
        free: 1 << 30,
      );
      store.contents[f.id] = _mp3();
      await start();
      await app.refreshFiles();
      expect(row('lunch.mp3').date, recorded);
      await app.delete([row('lunch.mp3')]);
      await app.refreshFiles(); // e.g. Settings opened on Android
      await app.restoreDeleted((await app.deletedRecordings())!.single);
      expect(row('lunch.mp3').date, recorded);
    },
  );
}
