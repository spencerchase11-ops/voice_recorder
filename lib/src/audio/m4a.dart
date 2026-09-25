import 'dart:io';

import 'audio_info.dart';

/// Whether an MP4/M4A file has its index (a complete `moov` box). Without it
/// the file can't be played; a recording cut off before (or while) it was
/// finalized has none.
Future<bool> hasMp4Index(File file) async {
  final a = await FileByteAccess.open(file);
  try {
    return await mp4HasIndex(a);
  } finally {
    await a.close();
  }
}
