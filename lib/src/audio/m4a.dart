import 'dart:io';
import 'dart:typed_data';

/// Whether an MP4/M4A file has its index (the `moov` box). Without it the
/// file can't be played; a recording cut off before it was finalized has none.
Future<bool> hasMp4Index(File file) async {
  final raf = await file.open();
  try {
    final length = await raf.length();
    var pos = 0;
    while (pos + 8 <= length) {
      await raf.setPosition(pos);
      final h = await raf.read(16);
      if (h.length < 8) return false;
      final b = ByteData.sublistView(h);
      var size = b.getUint32(0);
      if (String.fromCharCodes(h.sublist(4, 8)) == 'moov') return true;
      var header = 8;
      if (size == 1) {
        // 64-bit size follows the type.
        if (h.length < 16) return false;
        size = b.getUint64(8);
        header = 16;
      } else if (size == 0) {
        return false; // this box runs to the end of the file
      }
      if (size < header) return false; // corrupt
      pos += size;
    }
    return false;
  } finally {
    await raf.close();
  }
}
