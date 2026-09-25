import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// The playing time of an MP3 or WAV file, read from its headers, or null
/// when it can't be told (other formats, damaged files).
Future<Duration?> audioDuration(File file) async {
  final name = file.path.toLowerCase();
  try {
    if (name.endsWith('.mp3')) return await _mp3Duration(file);
    if (name.endsWith('.wav')) return await _wavDuration(file);
  } on FileSystemException {
    return null;
  }
  return null;
}

Future<Uint8List> _head(RandomAccessFile raf, int start, int length) async {
  await raf.setPosition(start);
  return raf.read(length);
}

// Layer III bitrates (kbit/s) by MPEG-1 / MPEG-2 and 2.5 and bitrate index.
const _bitratesV1 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
];
const _bitratesV2 = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
];
const _sampleRates = {
  3: [44100, 48000, 32000], // MPEG-1
  2: [22050, 24000, 16000], // MPEG-2
  0: [11025, 12000, 8000], // MPEG-2.5
};

Future<Duration?> _mp3Duration(File file) async {
  final raf = await file.open();
  try {
    final length = await raf.length();
    var start = 0;
    var h = await _head(raf, 0, 10);
    // Skip an ID3v2 tag.
    if (h.length == 10 && h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33) {
      final size = (h[6] << 21) | (h[7] << 14) | (h[8] << 7) | h[9];
      start = 10 + size + ((h[5] & 0x10) != 0 ? 10 : 0);
    }
    // Find the first Layer III frame header in the next 64 KB.
    final buf = await _head(raf, start, math.min(65536, length - start));
    for (var i = 0; i + 4 <= buf.length; i++) {
      if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;
      final version = (buf[i + 1] >> 3) & 3; // 3 = 1, 2 = 2, 0 = 2.5
      final layer = (buf[i + 1] >> 1) & 3; // 1 = Layer III
      final bitrateIndex = buf[i + 2] >> 4;
      final rateIndex = (buf[i + 2] >> 2) & 3;
      if (version == 1 || layer != 1) continue;
      if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) continue;
      final sampleRate = _sampleRates[version]![rateIndex];
      final kbps = (version == 3 ? _bitratesV1 : _bitratesV2)[bitrateIndex];
      final samplesPerFrame = version == 3 ? 1152 : 576;
      final mono = (buf[i + 3] >> 6) == 3;
      // A Xing/Info header (VBR, or CBR from some encoders) counts frames.
      final side = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);
      final x = i + 4 + side;
      if (x + 12 <= buf.length) {
        final tag = String.fromCharCodes(buf.sublist(x, x + 4));
        if (tag == 'Xing' || tag == 'Info') {
          final b = ByteData.sublistView(buf, x);
          if ((b.getUint32(4) & 1) != 0) {
            final frames = b.getUint32(8);
            return Duration(
              microseconds: frames * samplesPerFrame * 1000000 ~/ sampleRate,
            );
          }
        }
      }
      // Constant bitrate: the size tells the time.
      final audioBytes = length - start - i;
      return Duration(microseconds: audioBytes * 8000 ~/ kbps);
    }
    return null;
  } finally {
    await raf.close();
  }
}

Future<Duration?> _wavDuration(File file) async {
  final raf = await file.open();
  try {
    final length = await raf.length();
    final riff = await _head(raf, 0, 12);
    if (riff.length < 12 ||
        String.fromCharCodes(riff.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(riff.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    int? byteRate;
    var pos = 12;
    while (pos + 8 <= length) {
      // Chunk id, size, then for "fmt ": format, channels, rate, byte rate.
      final c = await _head(raf, pos, 20);
      if (c.length < 8) return null;
      final id = String.fromCharCodes(c.sublist(0, 4));
      final size = ByteData.sublistView(c).getUint32(4, Endian.little);
      if (id == 'fmt ' && c.length >= 20) {
        byteRate = ByteData.sublistView(c).getUint32(16, Endian.little);
      } else if (id == 'data') {
        if (byteRate == null || byteRate == 0) return null;
        // A cut-off file may claim more data than it has.
        final data = math.min(size, length - pos - 8);
        return Duration(microseconds: data * 1000000 ~/ byteRate);
      }
      pos += 8 + size + (size & 1);
    }
    return null;
  } finally {
    await raf.close();
  }
}
