/// Text formats used by the original app.
library;

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
/// volumes, and trims whitespace and trailing dots.
String sanitizeFileName(String input) {
  var s = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '_').trim();
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}
