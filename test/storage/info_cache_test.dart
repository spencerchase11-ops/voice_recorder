import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/storage/info_cache.dart';

import '../support/info_cache_1_0.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('info_cache');
    file = File('${dir.path}/recording_info.json');
  });
  tearDown(() => dir.delete(recursive: true));

  RecordingInfoCache cache() {
    final c = RecordingInfoCache(file: () async => file);
    // Its save timer would write into the folder after it is gone.
    addTearDown(c.dispose);
    return c;
  }

  final rec = RecordingFile(
    id: 'x',
    name: 'lunch.mp3',
    size: 1234,
    modified: DateTime(2026, 9, 20, 10),
  );
  final info = AudioInfo(
    recorded: DateTime(2016, 5, 23, 18, 14),
    duration: const Duration(minutes: 3, seconds: 7),
  );

  test('kept between launches', () async {
    final a = cache();
    await a.load();
    a.put(rec, info);
    await a.save();
    final b = cache();
    await b.load();
    expect(b[rec], info);
  });

  test('dates are stored as clock time, without a zone', () async {
    final a = cache();
    a.put(rec, info);
    await a.save();
    final json = jsonDecode(file.readAsStringSync()) as Map;
    expect(
      (json[RecordingInfoCache.keyOf(rec)] as List).first,
      '2016-05-23T18:14:00.000',
    );
  });

  test(
    'entries from the first test builds (points in time) still load',
    () async {
      file.writeAsStringSync(
        jsonEncode({
          RecordingInfoCache.keyOf(rec): [
            info.recorded!.millisecondsSinceEpoch,
            info.duration!.inMilliseconds,
          ],
        }),
      );
      final a = cache();
      await a.load();
      expect(a[rec], info);
    },
  );

  test('a damaged file is survived, and replaced by the next save', () async {
    file.writeAsStringSync('{"lunch.mp3|1234|0": [1, 2'); // cut off
    final a = cache();
    await a.load();
    expect(a[rec], isNull);
    a.put(rec, info);
    await a.save();
    expect(jsonDecode(file.readAsStringSync()), isA<Map<String, Object?>>());
  });

  test('saves one after another, never at the same time', () async {
    final a = cache();
    for (var i = 0; i < 20; i++) {
      a.put(
        RecordingFile(
          id: '$i',
          name: '$i.mp3',
          size: i,
          modified: DateTime(2026),
        ),
        info,
      );
    }
    // Several saves at once (the timer, leaving the app): all complete, and
    // the file is whole.
    await Future.wait([a.save(), a.save(), a.save()]);
    final b = cache();
    await b.load();
    expect(
      b[RecordingFile(
        id: '7',
        name: '7.mp3',
        size: 7,
        modified: DateTime(2026),
      )],
      info,
    );
  });

  test('a date kept here only (its write failed) is remembered', () async {
    final a = cache();
    a.put(rec, info, onlyHere: true);
    await a.save();
    final b = cache();
    await b.load();
    expect(b[rec], info);
    expect(b.dateOnlyHere(rec), isTrue);
    b.put(rec, info); // written into the file after all
    expect(b.dateOnlyHere(rec), isFalse);
  });

  test('a changed file is read again', () async {
    final a = cache();
    a.put(rec, info);
    expect(a.contains(rec), isTrue);
    expect(a.contains(rec.copyWith(size: 1284)), isFalse);
  });

  group('a cache 1.0.0 or 1.0.1 wrote', () {
    // On iPhone 1.0.x cached a renamed file's time, when it was copied
    // there (to the microsecond), as its date; the rename kept that time.
    final copied = DateTime(2026, 9, 24, 9, 30, 0, 123, 456);
    final renamed = RecordingFile(
      id: 'r',
      name: 'team lunch.aac',
      size: 999,
      modified: copied,
    );
    final copyTime = AudioInfo(
      recorded: copied,
      duration: const Duration(seconds: 42),
    );
    final other = RecordingFile(
      id: 'o',
      name: 'other.mp3',
      size: 1,
      modified: DateTime(2026),
    );
    final undated = RecordingFile(
      id: 'u',
      name: 'memo.mp3',
      size: 2,
      modified: DateTime(2026),
    );

    /// Writes the cache as 1.0.x does, with what [put] puts in it.
    Future<void> seed(void Function(RecordingInfoCache10 c) put) async {
      final c = RecordingInfoCache10(file: () async => file);
      put(c);
      await c.save();
      c.dispose();
    }

    Future<RecordingInfoCache> loaded({bool fileTimesAreDates = true}) async {
      final c = RecordingInfoCache(
        file: () async => file,
        fileTimesAreDates: fileTimesAreDates,
      );
      addTearDown(c.dispose);
      await c.load();
      return c;
    }

    test('on iPhone, a file time it cached as a date is read again', () async {
      await seed(
        (c) => c
          ..put(renamed, copyTime)
          ..put(rec, info),
      );
      final a = await loaded(fileTimesAreDates: false);
      expect(a.contains(renamed), isFalse);
      expect(a[rec], info); // a date of its own
    });

    test('elsewhere, where file times are dates, it stays', () async {
      await seed((c) => c.put(renamed, copyTime));
      final a = await loaded();
      expect(a[renamed], copyTime);
    });

    test('its dates are kept while their files are away', () async {
      // 1.0.x didn't mark a date whose write was refused or failed: the
      // cache may be its only copy.
      await seed(
        (c) => c
          ..put(rec, info)
          ..put(undated, const AudioInfo(duration: Duration(seconds: 3))),
      );
      final a = await loaded();
      final away = rec.copyWith(name: '.vr-deleted-1-lunch.mp3');
      a
        ..move(rec, away) // to Recently deleted
        ..retainOnly([other]);
      expect(a[away], info);
      expect(a.contains(undated), isFalse); // nothing to lose
      // Also after the next launch, and once it is back.
      await a.save();
      final b = await loaded();
      b.retainOnly([other]);
      expect(b[away], info);
      b
        ..move(away, rec)
        ..retainOnly([other]);
      expect(b[rec], info);
      // Read again and put (its date found in the file): forgotten once
      // gone, like any other.
      b
        ..put(rec, info)
        ..retainOnly([other]);
      expect(b.contains(rec), isFalse);
    });

    test("this build's own cache isn't taken for one", () async {
      final a = cache()
        ..put(rec, info)
        ..put(renamed, copyTime)
        ..put(other, info, onlyHere: true)
        ..put(undated, info, refused: true);
      await a.save();
      final b = await loaded(fileTimesAreDates: false);
      expect(b[renamed], copyTime);
      expect(b[other], info);
      expect(b.dateOnlyHere(other), isTrue);
      expect(b.dateRefused(undated), isTrue);
      b.retainOnly([other]);
      expect(b.contains(rec), isFalse); // its date is in its file
      expect(b[undated], info);
    });

    test("1.0.x still reads this build's file", () async {
      await seed((c) => c.put(rec, info));
      final a = await loaded();
      a
        ..put(other, info, onlyHere: true)
        ..put(undated, info, refused: true);
      await a.save();
      final old = RecordingInfoCache10(file: () async => file);
      addTearDown(old.dispose);
      await old.load();
      expect(old[rec], info);
      expect(old[other], info);
      expect(old.dateOnlyHere(other), isTrue);
      expect(old[undated], info);
      // What it writes back holds recordings only: the format wasn't
      // taken for one.
      old.put(renamed, copyTime);
      await old.save();
      final json = jsonDecode(file.readAsStringSync()) as Map;
      expect(
        json.keys,
        unorderedEquals([
          for (final f in [rec, other, undated, renamed])
            RecordingInfoCache.keyOf(f),
        ]),
      );
      // Back on this build: its marks are gone, so its dates are kept.
      final b = await loaded();
      b.retainOnly([other]);
      expect(b[rec], info);
      expect(b[undated], info);
    });
  });
}
