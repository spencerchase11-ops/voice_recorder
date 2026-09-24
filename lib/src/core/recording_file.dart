import 'format.dart';

/// A recording in the recordings folder.
class RecordingFile {
  const RecordingFile({
    required this.id,
    required this.name,
    required this.size,
    required this.modified,
  });

  /// Android: the document URI inside the chosen folder.
  /// iOS: the absolute file path.
  final String id;

  /// File name including the extension, e.g. `2026_09_23_19_14_00.mp3`.
  final String name;

  final int size;
  final DateTime modified;

  String get baseName => splitExtension(name).$1;
  String get extension => splitExtension(name).$2;

  /// When it was recorded: the time in a timestamp name
  /// (`2026_09_16_16_37_26.mp3`), which survives copies and phone transfers
  /// that reset file dates; otherwise the file's modification time.
  DateTime get date => parseTimestampName(baseName) ?? modified;

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
  );

  @override
  bool operator ==(Object other) =>
      other is RecordingFile &&
      other.id == id &&
      other.name == name &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(id, name, size, modified);

  @override
  String toString() => 'RecordingFile($name, $size bytes, $modified)';
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
