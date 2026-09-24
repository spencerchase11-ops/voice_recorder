import 'dart:io';
import 'dart:typed_data';

/// Streams 16-bit little-endian PCM into a RIFF/WAVE file.
///
/// The header is written up front with placeholder sizes and patched on
/// [close]; [repair] fixes the header of a file whose recording was cut short.
class WavWriter {
  WavWriter._(this._file, this.sampleRate, this.channels);

  static Future<WavWriter> open(
    String path, {
    required int sampleRate,
    int channels = 1,
  }) async {
    final raf = await File(path).open(mode: FileMode.write);
    final w = WavWriter._(raf, sampleRate, channels);
    await raf.writeFrom(
      header(sampleRate: sampleRate, channels: channels, dataBytes: 0),
    );
    return w;
  }

  final RandomAccessFile _file;
  final int sampleRate;
  final int channels;
  int _dataBytes = 0;

  int get dataBytes => _dataBytes;

  Future<void> add(Uint8List pcm) async {
    await _file.writeFrom(pcm);
    _dataBytes += pcm.length;
  }

  Future<void> close() async {
    await _file.setPosition(0);
    await _file.writeFrom(
      header(sampleRate: sampleRate, channels: channels, dataBytes: _dataBytes),
    );
    await _file.close();
  }

  static Uint8List header({
    required int sampleRate,
    required int channels,
    required int dataBytes,
  }) {
    const bits = 16;
    final blockAlign = channels * bits ~/ 8;
    final b = ByteData(44);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * blockAlign, Endian.little);
    b.setUint16(32, blockAlign, Endian.little);
    b.setUint16(34, bits, Endian.little);
    ascii(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }

  /// Rewrites the size fields of an interrupted recording made by [WavWriter].
  static Future<void> repair(
    File file, {
    required int sampleRate,
    int channels = 1,
  }) async {
    final length = await file.length();
    if (length < 44) return;
    final raf = await file.open(mode: FileMode.append);
    try {
      var data = length - 44;
      data -= data % (channels * 2);
      await raf.setPosition(0);
      await raf.writeFrom(
        header(sampleRate: sampleRate, channels: channels, dataBytes: data),
      );
    } finally {
      await raf.close();
    }
  }
}
