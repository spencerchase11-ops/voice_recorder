import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/storage/info_cache.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('info_cache');
    file = File('${dir.path}/recording_info.json');
  });
  tearDown(() => dir.delete(recursive: true));

  RecordingInfoCache cache() => RecordingInfoCache(file: () async => file);

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
    expect((json.values.single as List).first, '2016-05-23T18:14:00.000');
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
}
