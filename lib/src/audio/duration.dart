import 'dart:io';

import 'audio_info.dart';

/// The playing time of an MP3, WAV or M4A file, read from its headers, or
/// null when it can't be told (other formats, damaged files).
Future<Duration?> audioDuration(File file) async {
  try {
    final a = await FileByteAccess.open(file);
    try {
      return (await readAudioInfo(a, file.path)).duration;
    } finally {
      await a.close();
    }
  } on FileSystemException {
    return null;
  }
}
