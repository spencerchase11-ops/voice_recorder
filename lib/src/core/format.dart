/// Text formats used by the original app.
library;

import 'dart:convert';

String _two(int v) => v.toString().padLeft(2, '0');

/// Recorder timer: `33:57`, or `1:05:30` once a recording passes an hour.
String formatTimer(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

/// Seek-bar position in the recording list: `00:00`, `1:05:30`.
String formatPosition(Duration d) => formatTimer(d);

/// "Remaining time: 9665:13:10" - hours are not wrapped at 24.
String formatRemaining(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '$h:${_two(m)}:${_two(s)}';
}

/// Recording list date: `2026-09-23`.
String formatListDate(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}';

/// Recording list size: whole kibibytes, `39819KB`.
String formatListSize(int bytes) => '${bytes ~/ 1024}KB';

final _timestampName = RegExp(
  r'^(\d{4})_(\d{2})_(\d{2})_(\d{2})_(\d{2})_(\d{2})(?!\d)',
);

/// The time in a recording name made by [timestampName] (also with a
/// " (1)"-style suffix or text after it), or null for other names.
DateTime? parseTimestampName(String baseName) {
  final m = _timestampName.firstMatch(baseName);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  final t = DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  // Reject impossible dates such as month 13 (DateTime would roll them over).
  final valid =
      t.year == v[0] &&
      t.month == v[1] &&
      t.day == v[2] &&
      t.hour == v[3] &&
      t.minute == v[4] &&
      t.second == v[5];
  return valid ? t : null;
}

/// File name for a new recording: `2026_09_23_19_14_00`.
String timestampName(DateTime t) =>
    '${t.year}_${_two(t.month)}_${_two(t.day)}_${_two(t.hour)}_${_two(t.minute)}_${_two(t.second)}';

/// Splits `name.ext` into (`name`, `ext`); `ext` is empty when there is none.
(String, String) splitExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return (fileName, '');
  return (fileName.substring(0, dot), fileName.substring(dot + 1));
}

/// Makes a user-typed name safe for every file system we write to.
///
/// Mirrors the characters Android's external storage provider rejects on FAT
/// volumes, and trims whitespace and leading/trailing dots.
/// Most characters a typed name may have (file systems allow 255 bytes).
const maxNameLength = 120;

/// [base] shortened so that `base.ext` stays within the 255-byte limit of
/// file names, with room left for a " (1)"-style suffix.
String fitFileName(String base, String ext) {
  final tail = ext.isEmpty ? 0 : utf8.encode('.$ext').length;
  var b = base;
  while (b.isNotEmpty && utf8.encode(b).length + tail > 240) {
    b = String.fromCharCodes(b.runes.take(b.runes.length - 1)).trimRight();
  }
  return b;
}

String sanitizeFileName(String input) {
  var s = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '_').trim();
  // A leading dot would hide the file (in the list and in file managers).
  s = s.replaceFirst(RegExp(r'^[.\s]+'), '');
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}
