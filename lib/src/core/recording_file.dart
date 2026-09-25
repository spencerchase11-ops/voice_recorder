import 'dart:convert';
import 'dart:math' as math;

import '../audio/audio_info.dart';
import 'format.dart';

/// A recording in the recordings folder.
class RecordingFile {
  RecordingFile({
    required this.id,
    required this.name,
    required this.size,
    required this.modified,
    this.recorded,
    this.duration,
  });

  /// Android: the document URI inside the chosen folder.
  /// iOS: the absolute file path.
  final String id;

  /// File name including the extension, e.g. `2026_09_23_19_14_00.mp3`.
  final String name;

  final int size;
  final DateTime modified;

  /// The recording date stored inside the file (see audio_info.dart), once
  /// it has been read; null until then or if the file has none.
  final DateTime? recorded;

  /// Playing time read from the file's headers, once known.
  final Duration? duration;

  String get baseName => splitExtension(name).$1;
  String get extension => splitExtension(name).$2;

  /// The time in a timestamp name (`2026_09_16_16_37_26.mp3`), if it is one.
  late final DateTime? nameDate = parseTimestampName(baseName);

  /// When it was recorded: the date stored in the file, which survives
  /// renames; else the time in a timestamp name, which survives copies and
  /// phone transfers that reset file dates; else the file's modification
  /// time (see [recordingDate]). Worked out once: lists sort by it.
  late final DateTime date =
      recordingDate(stored: recorded, named: nameDate, length: duration) ??
      modified;

  /// This file with what [info] says about it (unchanged for null).
  RecordingFile withInfo(AudioInfo? info) => info == null
      ? this
      : RecordingFile(
          id: id,
          name: name,
          size: size,
          modified: modified,
          recorded: info.recorded ?? recorded,
          duration: info.duration ?? duration,
        );

  RecordingFile copyWith({
    String? id,
    String? name,
    int? size,
    DateTime? modified,
  }) => RecordingFile(
    id: id ?? this.id,
    name: name ?? this.name,
    size: size ?? this.size,
    modified: modified ?? this.modified,
    recorded: recorded,
    duration: duration,
  );

  @override
  bool operator ==(Object other) =>
      other is RecordingFile &&
      other.id == id &&
      other.name == name &&
      other.size == size &&
      other.modified == modified &&
      other.recorded == recorded &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(id, name, size, modified, recorded, duration);

  @override
  String toString() => 'RecordingFile($name, $size bytes, $modified)';
}

/// When a recording was made, from the date stored in the file and the time
/// in a timestamp name. They agree for this app's recordings; where they
/// don't, the stored date wins (the name may have been typed), except that
/// some recorders (Android's M4A encoder, used by the original app) store
/// when the recording ended: a name up to the recording's [length] earlier
/// holds its start.
DateTime? recordingDate({DateTime? stored, DateTime? named, Duration? length}) {
  if (stored == null || named == null) return stored ?? named;
  final end = named.add((length ?? Duration.zero) + const Duration(minutes: 1));
  return stored.isBefore(named) || stored.isAfter(end) ? stored : named;
}

/// How long Recently deleted keeps a recording.
const trashRetention = Duration(days: 30);

/// A recording in Recently deleted: the file under a hidden name
/// (`.vr-deleted-<ms>-<original name>`) in the recordings folder, so it is out
/// of the list (and out of file managers and music apps) but can come back.
///
/// Not `.trashed-`: Android's own trash (MediaStore) uses that prefix, with
/// an expiry time, for files other apps put in their trash.
class TrashedRecording {
  const TrashedRecording({
    required this.file,
    required this.originalName,
    required this.deletedAt,
  });

  static const prefix = '.vr-deleted-';

  /// The file under its hidden name.
  final RecordingFile file;

  /// The name it gets back when restored.
  final String originalName;
  final DateTime deletedAt;

  /// The hidden name for [name], deleted at [at]. Long names are shortened
  /// to keep within the file system's 255-byte limit.
  static String hiddenName(String name, DateTime at) {
    final head = '$prefix${at.millisecondsSinceEpoch}-';
    var fitted = name;
    if (utf8.encode(head + fitted).length > 250) {
      final (base, ext) = splitExtension(name);
      final tail = ext.isEmpty ? '' : '.$ext';
      var b = base;
      while (b.isNotEmpty && utf8.encode('$head$b$tail').length > 250) {
        b = String.fromCharCodes(b.runes.take(b.runes.length - 1));
      }
      fitted = '$b$tail';
    }
    return head + fitted;
  }

  /// Any time is taken (a phone's clock can be far off), so whatever this
  /// app hides can be found again.
  static final _pattern = RegExp(r'^\.vr-deleted-(\d{1,15})-(.+)$');

  /// Test builds before the release used Android's trash prefix, with the
  /// time in milliseconds (13 digits; Android's own entries have 10-digit
  /// seconds, and are never taken for ours).
  static final _early = RegExp(r'^\.trashed-(\d{13})-(.+)$');

  /// For the early prefix: the earliest deletion time taken as real (older
  /// values are someone else's naming, not a deletion by this app).
  static final _earliest = DateTime(2025);

  /// The deleted recording [file] stands for, or null for other files.
  static TrashedRecording? parse(RecordingFile file) {
    final ours = _pattern.firstMatch(file.name);
    final m = ours ?? _early.firstMatch(file.name);
    if (m == null) return null;
    final original = m.group(2)!;
    if (!isAudioFileName(original)) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(int.parse(m.group(1)!));
    if (ours == null && at.isBefore(_earliest)) return null;
    return TrashedRecording(file: file, originalName: original, deletedAt: at);
  }

  /// Days until it is deleted for good, counting a started day: 30 right
  /// after deleting, 1 on the last day, 0 once it is due. Never more than
  /// 30 (deleted while the clock was ahead).
  int daysLeft(DateTime now) {
    final left = deletedAt.add(trashRetention).difference(now);
    if (left <= Duration.zero) return 0;
    final days = (left.inSeconds / Duration.secondsPerDay).ceil();
    return math.min(days, trashRetention.inDays);
  }

  bool expired(DateTime now) => !deletedAt.add(trashRetention).isAfter(now);
}

/// Extensions the recording list shows (files the original app could create
/// plus other common audio formats that may live in the same folder).
const audioExtensions = {
  'mp3',
  'wav',
  'm4a',
  'aac',
  'amr',
  '3gp',
  'ogg',
  'opus',
  'flac',
};

bool isAudioFileName(String name) =>
    !name.startsWith('.') &&
    audioExtensions.contains(splitExtension(name).$2.toLowerCase());
