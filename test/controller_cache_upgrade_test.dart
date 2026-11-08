// Phones that update from 1.0.0 or 1.0.1 keep the dates that release left
// in its cache, and lose the copy times it cached on iPhone.
import 'dart:convert';
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

/// An M4A whose movie header was created at [created].
List<int> _m4a(DateTime created) {
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
    ..setUint32(16, 1000);
  return [
    ...box('ftyp', 'M4A isom'.codeUnits),
    ...box('mdat', List.filled(2000, 1)),
    ...box(
      'moov',
      box('mvhd', [...mvhd.buffer.asUint8List(), ...List.filled(80, 0)]),
    ),
  ];
}

/// Like the real stores: writing to a file (or cutting it back) changes its
/// time, even when the write fails, and a rename keeps the file as it is.
class _TouchingStore extends FakeStore {
  _TouchingStore({super.files, super.free});

  var _tick = 0;

  void _touch(String id) {
    final i = files.indexWhere((f) => f.id == id);
    if (i < 0) return;
    files[i] = files[i].copyWith(
      modified: DateTime(2026, 11, 8, 12, 0, ++_tick),
      size: contents[id]?.length ?? files[i].size,
    );
  }

  @override
  Future<ByteAccess> openBytes(RecordingFile file, {bool write = false}) async {
    final a = await super.openBytes(file, write: write);
    return write ? _Touching(a, () => _touch(file.id)) : a;
  }

  @override
  Future<RecordingFile?> renameTo(RecordingFile file, String fileName) =>
      super.renameTo(
        files.firstWhere((f) => f.id == file.id, orElse: () => file),
        fileName,
      );
}

class _Touching implements ByteAccess {
  _Touching(this._a, this._touch);

  final ByteAccess _a;
  final void Function() _touch;

  @override
  Future<int> length() => _a.length();

  @override
  Future<Uint8List> read(int offset, int count) => _a.read(offset, count);

  @override
  Future<void> write(int offset, List<int> bytes) async {
    try {
      await _a.write(offset, bytes);
    } finally {
      _touch();
    }
  }

  @override
  Future<void> truncate(int length) async {
    await _a.truncate(length);
    _touch();
  }

  @override
  Future<void> close() => _a.close();
}

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
  late RecordingInfoCache info;

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
      info: info = RecordingInfoCache(
        file: () async => cacheFile,
        fileTimesAreDates: store.fileTimesAreDates,
      ),
    );
    addTearDown(controller.dispose);
    await controller.init();
  }

  RecordingFile row(String name) =>
      app.files.singleWhere((f) => f.name == name);

  /// The date inside [f] (what is left once the cache is gone).
  Future<DateTime?> inside(RecordingFile f) async => (await readAudioInfo(
    MemoryBytes(store.contents[f.id]!),
    f.name,
  )).recorded;

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

  test('so does one renamed again in this build', () async {
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
    // 1.0.x's date may be its only copy: the rename writes it into the
    // file.
    final renamed = await app.rename(row('lunch.mp3'), 'team lunch');
    expect(renamed!.date, recorded);
    expect(await inside(renamed), recorded);
    await app.delete([row('team lunch.mp3')]);
    await app.refreshFiles();
    await app.restoreDeleted((await app.deletedRecordings())!.single);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // read again
    expect(row('team lunch.mp3').date, recorded);
  });

  test("renamed, a date 1.0.x cached for a dated name is written into the "
      'file (the old name was its only other copy)', () async {
    // 1.0.x renamed 2016_05_23_18_14_00.mp3, keeping the time in the name,
    // and couldn't write the date into the file.
    final f = _file(
      '2016_05_23_18_14_00 lunch.mp3',
      DateTime(2016, 5, 23, 18, 44),
    );
    final recorded = DateTime(2016, 5, 23, 18, 14);
    await cachedBy10(
      f,
      AudioInfo(recorded: recorded, duration: const Duration(seconds: 1)),
    );
    store = FakeStore(files: [f], free: 1 << 30);
    store.contents[f.id] = _mp3();
    await start();
    await app.refreshFiles();
    final renamed = await app.rename(row(f.name), 'team lunch');
    expect(renamed!.date, recorded);
    expect(await inside(renamed), recorded);
    expect(app.datesToStore, isEmpty);
  });

  test('if writing it fails, Store dates offers it again', () async {
    final f = _file(
      '2016_05_23_18_14_00 lunch.mp3',
      DateTime(2016, 5, 23, 18, 44),
    );
    final recorded = DateTime(2016, 5, 23, 18, 14);
    await cachedBy10(
      f,
      AudioInfo(recorded: recorded, duration: const Duration(seconds: 1)),
    );
    store = FakeStore(files: [f], free: 1 << 30);
    store.contents[f.id] = _mp3();
    store.roomFor[f.id] = 0; // the storage is full
    await start();
    await app.refreshFiles();
    final renamed = await app.rename(row(f.name), 'team lunch');
    expect(renamed!.date, recorded);
    expect(await inside(renamed), isNull);
    expect(app.datesToStore!.map((f) => f.name), ['team lunch.mp3']);
  });

  test("renamed, an M4A's own moment stays as it is, though 1.0.x cached its "
      'clock time somewhere else (another time zone)', () async {
    final moment = DateTime.utc(2026, 6, 1, 14);
    final f = _file('lunch.m4a', DateTime(2026, 6, 1, 15));
    // What 1.0.x showed, cached where the clock read otherwise.
    final cached = moment.toLocal().add(const Duration(hours: 5));
    await cachedBy10(
      f,
      AudioInfo(recorded: cached, duration: const Duration(seconds: 1)),
    );
    store = FakeStore(files: [f], free: 1 << 30);
    store.contents[f.id] = _m4a(moment);
    await start();
    await app.refreshFiles();
    final renamed = await app.rename(row(f.name), 'team lunch');
    expect(renamed!.date, cached);
    expect(await inside(renamed), moment.toLocal());
  });

  test('a rename that fails after writing the date failed keeps the date '
      'shown', () async {
    final f = _file('lunch.mp3', DateTime(2016, 5, 23, 18, 44));
    final recorded = DateTime(2016, 5, 23, 18, 14);
    await cachedBy10(
      f,
      AudioInfo(recorded: recorded, duration: const Duration(seconds: 1)),
    );
    store = _TouchingStore(files: [f], free: 1 << 30);
    store.contents[f.id] = _mp3();
    store.roomFor[f.id] = 0; // the storage is full
    await start();
    await app.refreshFiles();
    store.failRenames = true;
    expect(await app.rename(row('lunch.mp3'), 'team lunch'), isNull);
    expect(row('lunch.mp3').date, recorded);
    await app.refreshFiles();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(row('lunch.mp3').date, recorded);
    // Tried again, with room now: the date goes into the file.
    store
      ..failRenames = false
      ..roomFor.clear();
    final renamed = await app.rename(row('lunch.mp3'), 'team lunch');
    expect(renamed!.date, recorded);
    expect(await inside(renamed), recorded);
  });

  test('renamed again and again, the cache keeps it under its current name '
      'only', () async {
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
    await app.rename(row('lunch.mp3'), 'one');
    await app.refreshFiles();
    await app.rename(row('one.mp3'), 'two');
    await app.refreshFiles();
    expect(row('two.mp3').date, recorded);
    await info.save();
    final json = jsonDecode(await cacheFile.readAsString()) as Map;
    final names = {
      for (final k in json.keys)
        if (k != 'format') (k as String).split('|').first,
    }..remove('b.mp3');
    expect(names, {'two.mp3'});
  });
}
