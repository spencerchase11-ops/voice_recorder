// Encodes through the real LAME library when a host build exists:
//   packages/lame_mp3/tool/build_host_lib.sh && flutter test
// ignore_for_file: implementation_imports
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lame_mp3/src/native_library.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/mp3_writer.dart';

void main() {
  final lib = File('packages/lame_mp3/build/host/liblame_mp3.so');
  final skip = lib.existsSync()
      ? null
      : 'run packages/lame_mp3/tool/build_host_lib.sh first';
  if (skip == null) lameMp3LibraryPathOverride = lib.absolute.path;

  test('streams PCM chunks of any size into a 160 kbps MP3', () async {
    final dir = await Directory.systemTemp.createTemp('mp3_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/tone.mp3';
    final w = await Mp3Writer.open(path, sampleRate: 44100, bitRateKbps: 160);
    // 2 s of 440 Hz, fed in odd-sized byte chunks to exercise sample carry-over
    const n = 88200;
    final pcm = ByteData(n * 2);
    for (var i = 0; i < n; i++) {
      pcm.setInt16(
        i * 2,
        (math.sin(2 * math.pi * 440 * i / 44100) * 12000).round(),
        Endian.little,
      );
    }
    final bytes = pcm.buffer.asUint8List();
    const sizes = [1, 4095, 3, 8192, 7777];
    for (var o = 0, i = 0; o < bytes.length; i++) {
      final end = math.min(bytes.length, o + sizes[i % sizes.length]);
      await w.add(Uint8List.sublistView(bytes, o, end));
      o = end;
    }
    await w.close();

    final out = await File(path).readAsBytes();
    expect(out.length, w.bytesWritten);
    // MPEG-1 Layer III, no CRC; 160 kbps (index 10), 44.1 kHz (index 0).
    expect(out[0], 0xFF);
    expect(out[1] & 0xFE, 0xFA);
    expect(out[2] >> 4, 10);
    expect((out[2] >> 2) & 3, 0);
    // ~2 s at 160 kbps = ~40 kB (plus encoder delay/padding)
    expect(out.length, inInclusiveRange(40000, 42500));
  }, skip: skip);

  test('starts with the recording date, and still plays for 1 s', () async {
    final dir = await Directory.systemTemp.createTemp('mp3_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/dated.mp3';
    final recorded = DateTime(2026, 9, 25, 3, 30, 5);
    final w = await Mp3Writer.open(
      path,
      sampleRate: 44100,
      bitRateKbps: 160,
      recorded: recorded,
    );
    await w.add(Uint8List(88200)); // 1 s of silence
    await w.close();

    final out = await File(path).readAsBytes();
    expect(out.length, w.bytesWritten);
    expect(String.fromCharCodes(out.sublist(0, 3)), 'ID3');
    final a = await FileByteAccess.open(File(path));
    final info = await readAudioInfo(a, path);
    await a.close();
    expect(info.recorded, recorded);
    // LAME adds its encoder delay and padding.
    expect(info.duration!.inMilliseconds, inInclusiveRange(1000, 1100));
  }, skip: skip);
}
