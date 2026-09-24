import 'dart:io';
import 'dart:typed_data';

import 'package:lame_mp3/lame_mp3.dart';

/// Encodes 16-bit little-endian PCM to a constant-bitrate MP3 file with LAME.
class Mp3Writer {
  Mp3Writer._(this._file, this._encoder);

  static Future<Mp3Writer> open(
    String path, {
    required int sampleRate,
    required int bitRateKbps,
    int channels = 1,
  }) async {
    final encoder = LameMp3Encoder(
      sampleRate: sampleRate,
      channels: channels,
      bitrateKbps: bitRateKbps,
      // LAME's recommended speed/quality trade-off for real-time encoding.
      quality: 5,
    );
    final raf = await File(path).open(mode: FileMode.write);
    return Mp3Writer._(raf, encoder);
  }

  final RandomAccessFile _file;
  final LameMp3Encoder _encoder;
  int _pending = -1; // odd trailing byte carried over between chunks
  int _bytesWritten = 0;

  int get bytesWritten => _bytesWritten;

  Future<void> add(Uint8List pcm) async {
    final samples = _toSamples(pcm);
    if (samples.isEmpty) return;
    final mp3 = _encoder.encode(samples);
    if (mp3.isNotEmpty) {
      await _file.writeFrom(mp3);
      _bytesWritten += mp3.length;
    }
  }

  Future<void> close() async {
    try {
      final tail = _encoder.flush();
      if (tail.isNotEmpty) {
        await _file.writeFrom(tail);
        _bytesWritten += tail.length;
      }
    } finally {
      _encoder.close();
      await _file.close();
    }
  }

  Int16List _toSamples(Uint8List pcm) {
    var bytes = pcm;
    if (_pending >= 0) {
      bytes = Uint8List(pcm.length + 1)
        ..[0] = _pending
        ..setRange(1, pcm.length + 1, pcm);
      _pending = -1;
    }
    final even = bytes.length & ~1;
    if (even != bytes.length) _pending = bytes[bytes.length - 1];
    final data = ByteData.sublistView(bytes, 0, even);
    final out = Int16List(even ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = data.getInt16(i * 2, Endian.little);
    }
    return out;
  }
}
