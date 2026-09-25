import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/format.dart';

void main() {
  test('timer shows mm:ss and switches to h:mm:ss after an hour', () {
    expect(formatTimer(Duration.zero), '00:00');
    expect(formatTimer(const Duration(minutes: 33, seconds: 57)), '33:57');
    expect(
      formatTimer(const Duration(minutes: 59, seconds: 59, milliseconds: 999)),
      '59:59',
    );
    expect(
      formatTimer(const Duration(hours: 1, minutes: 5, seconds: 3)),
      '1:05:03',
    );
  });

  test('remaining time never wraps hours', () {
    expect(
      formatRemaining(const Duration(hours: 9665, minutes: 13, seconds: 10)),
      '9665:13:10',
    );
    expect(formatRemaining(const Duration(seconds: 59)), '0:00:59');
  });

  test('list date and size match the original', () {
    expect(formatListDate(DateTime(2026, 9, 3, 23, 59)), '2026-09-03');
    expect(formatListSize(39819 * 1024 + 1023), '39819KB');
    expect(formatListSize(0), '0KB');
    expect(formatCount(2464), '2,464');
    expect(formatCount(1234567), '1,234,567');
    expect(formatCount(999), '999');
    expect(formatCount(0), '0');
  });

  test('new recordings are named after the start time', () {
    expect(
      timestampName(DateTime(2026, 9, 20, 17, 26, 27)),
      '2026_09_20_17_26_27',
    );
    expect(timestampName(DateTime(2026, 1, 2, 3, 4, 5)), '2026_01_02_03_04_05');
  });

  test('timestamp names give the recording time', () {
    expect(
      parseTimestampName('2026_09_16_16_37_26'),
      DateTime(2026, 9, 16, 16, 37, 26),
    );
    expect(
      parseTimestampName('2026_09_16_16_37_26 (1)'),
      DateTime(2026, 9, 16, 16, 37, 26),
    );
    expect(parseTimestampName('kris n evan got back then zach'), isNull);
    expect(parseTimestampName('2026_13_16_16_37_26'), isNull);
    expect(parseTimestampName('2026_02_30_10_00_00'), isNull);
    expect(parseTimestampName('2026_09_16_16_37_261'), isNull);
    expect(parseTimestampName('2026_09_16'), isNull);
  });

  test('splitExtension', () {
    expect(splitExtension('kris n evan got back then zach.mp3'), (
      'kris n evan got back then zach',
      'mp3',
    ));
    expect(splitExtension('lunch w kris team convo .mp3'), (
      'lunch w kris team convo ',
      'mp3',
    ));
    expect(splitExtension('noext'), ('noext', ''));
    expect(splitExtension('.hidden'), ('.hidden', ''));
    expect(splitExtension('trailing.'), ('trailing.', ''));
  });

  test('sanitizeFileName removes characters file systems reject', () {
    expect(sanitizeFileName('  a/b\\c:d*e?f"g<h>i|j  '), 'a_b_c_d_e_f_g_h_i_j');
    expect(sanitizeFileName('name...'), 'name');
    expect(sanitizeFileName('kris n evan'), 'kris n evan');
    expect(sanitizeFileName('   '), '');
    // A leading dot would hide the file.
    expect(sanitizeFileName('.meeting'), 'meeting');
    expect(sanitizeFileName(' . .notes'), 'notes');
  });
}
