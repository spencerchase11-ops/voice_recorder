import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';

void main() {
  RecordingFile file(
    String name, {
    DateTime? recorded,
    Duration? duration,
    DateTime? modified,
  }) => RecordingFile(
    id: 'mem://$name',
    name: name,
    size: 1,
    modified: modified ?? DateTime(2026, 9, 25),
    recorded: recorded,
    duration: duration,
  );

  group('recording date', () {
    test('stored date, else the name, else the file time', () {
      expect(
        file('a.mp3', recorded: DateTime(2016, 5, 23)).date,
        DateTime(2016, 5, 23),
      );
      expect(
        file('2016_05_23_18_14_00.mp3').date,
        DateTime(2016, 5, 23, 18, 14),
      );
      expect(file('lunch.mp3').date, DateTime(2026, 9, 25));
    });

    test("an M4A that stores when it ended sorts by the name's start", () {
      // The original app's M4A: 30 minutes, stamped when it stopped.
      final f = file(
        '2016_09_18_23_40_00.m4a',
        recorded: DateTime(2016, 9, 19, 0, 10, 2),
        duration: const Duration(minutes: 30),
      );
      expect(f.date, DateTime(2016, 9, 18, 23, 40));
    });

    test('a stored date far from the name wins (the name was typed)', () {
      final f = file(
        '2020_01_01_00_00_00.mp3',
        recorded: DateTime(2016, 9, 18, 23, 40),
        duration: const Duration(minutes: 30),
      );
      expect(f.date, DateTime(2016, 9, 18, 23, 40));
    });

    test('read in another time zone, the name keeps its time', () {
      // An M4A stores a moment, read back in the phone's current zone; the
      // name holds the clock time where it was recorded.
      final named = DateTime(2026, 7, 14, 1, 30);
      for (final shift in const [
        Duration(hours: -6), // recorded in Paris, read in New York
        Duration(hours: 9, minutes: 30), // Darwin
        Duration(hours: 5, minutes: 45), // Kathmandu
        Duration(hours: -23), // Auckland to Honolulu
      ]) {
        final f = file(
          '2026_07_14_01_30_00.m4a',
          recorded: named.add(shift),
          duration: const Duration(minutes: 5),
        );
        expect(f.date, named, reason: '$shift');
      }
    });

    test('a stored date off by more than a time zone still wins', () {
      final named = DateTime(2026, 7, 14, 1, 30);
      for (final off in const [
        Duration(hours: -6, seconds: 3), // not a whole quarter of an hour
        Duration(hours: 6, minutes: 10),
        Duration(days: 2), // further than any two zones are apart
      ]) {
        final f = file('2026_07_14_01_30_00.m4a', recorded: named.add(off));
        expect(f.date, named.add(off), reason: '$off');
      }
    });
  });

  group('Recently deleted names', () {
    final at = DateTime(2026, 9, 25, 10);

    test("any time is this app's (a phone's clock can be far off)", () {
      for (final when in [DateTime(2024, 12, 31), DateTime(1999), at]) {
        final hidden = TrashedRecording.hiddenName('a.mp3', when);
        final t = TrashedRecording.parse(file(hidden))!;
        expect(t.originalName, 'a.mp3');
        expect(t.deletedAt, when);
      }
    });

    test('days left: never more than 30 (deleted with the clock ahead)', () {
      final hidden = TrashedRecording.hiddenName(
        'a.mp3',
        at.add(const Duration(days: 400)),
      );
      expect(TrashedRecording.parse(file(hidden))!.daysLeft(at), 30);
    });
  });

  group('file names', () {
    test('a long name is shortened to fit, with its extension', () {
      final fitted = fitFileName('é' * 300, 'mp3'); // 2 bytes each
      expect(utf8.encode('$fitted.mp3').length, lessThanOrEqualTo(240));
      expect(fitted, startsWith('éééé'));
      expect(fitFileName('lunch', 'mp3'), 'lunch');
    });
  });
}
