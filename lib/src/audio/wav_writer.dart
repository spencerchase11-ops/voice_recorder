import 'dart:io';
import 'dart:typed_data';

import 'audio_info.dart';

/// Streams 16-bit little-endian PCM into a RIFF/WAVE file.
///
/// The header is written up front with placeholder sizes and patched on
/// [close], which also appends the recording date (a LIST/INFO chunk);
/// [repair] fixes the header of a file whose recording was cut short.
class WavWriter {
  WavWriter._(this._file, this.sampleRate, this.channels, this.recorded);

  static Future<WavWriter> open(
    String path, {
    required int sampleRate,
    int channels = 1,
    DateTime? recorded,
  }) async {
    final raf = await File(path).open(mode: FileMode.write);
    final w = WavWriter._(raf, sampleRate, channels, recorded);
    await raf.writeFrom(
      header(sampleRate: sampleRate, channels: channels, dataBytes: 0),
    );
    return w;
  }

  final RandomAccessFile _file;
  final int sampleRate;
  final int channels;

  /// Stored in the file on [close].
  final DateTime? recorded;
  int _dataBytes = 0;

  int get dataBytes => _dataBytes;

  Future<void> add(Uint8List pcm) async {
    await _file.writeFrom(pcm);
    _dataBytes += pcm.length;
  }

  Future<void> close() async {
    try {
      final info = recorded == null ? null : wavInfoChunk(recorded!);
      // The data chunk is padded to an even size (mono 16-bit always is).
      final pad = _dataBytes.isOdd ? 1 : 0;
      // Sizes first: if appending the date fails (storage full), the audio is
      // still described correctly.
      await _file.setPosition(0);
      await _file.writeFrom(
        header(
          sampleRate: sampleRate,
          channels: channels,
          dataBytes: _dataBytes,
          trailingBytes: info == null ? 0 : pad + info.length,
        ),
      );
      if (info != null) {
        await _file.setPosition(44 + _dataBytes);
        await _file.writeFrom([if (pad == 1) 0, ...info]);
      }
    } finally {
      await _file.close();
    }
  }

  /// The 44-byte header; [trailingBytes] are chunks after the data.
  static Uint8List header({
    required int sampleRate,
    required int channels,
    required int dataBytes,
    int trailingBytes = 0,
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
    b.setUint32(4, 36 + dataBytes + trailingBytes, Endian.little);
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
  ///
  /// A header still holding the placeholder (no data size) gets the size of
  /// everything after it, less a partly written sample at the end; a valid
  /// data size is kept (the recording was finished, and the date chunk may
  /// follow the data), also a size of 0 in a header that [close] finished
  /// (a recording with no sound, followed by its date).
  static Future<void> repair(
    File file, {
    required int sampleRate,
    int channels = 1,
  }) async {
    var length = await file.length();
    if (length < 44) return;
    final raf = await file.open(mode: FileMode.append);
    try {
      await raf.setPosition(0);
      final h = await raf.read(44);
      final sizes = ByteData.sublistView(h);
      final riff = h.length < 8 ? 0 : sizes.getUint32(4, Endian.little);
      final declared = h.length < 44 ? 0 : sizes.getUint32(40, Endian.little);
      final available = length - 44;
      final finished = declared == 0
          ? length > 44 && riff + 8 == length
          : declared <= available;
      var data = declared;
      if (!finished) {
        data = available - available % (channels * 2);
        if (44 + data < length) {
          await raf.truncate(44 + data);
          length = 44 + data;
        }
      }
      await raf.setPosition(0);
      await raf.writeFrom(
        header(
          sampleRate: sampleRate,
          channels: channels,
          dataBytes: data,
          trailingBytes: length - 44 - data,
        ),
      );
    } finally {
      await raf.close();
    }
  }
}
