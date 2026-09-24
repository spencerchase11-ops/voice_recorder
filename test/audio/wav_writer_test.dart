import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/wav_writer.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('wav_test'));
  tearDown(() => dir.delete(recursive: true));

  int u32(Uint8List b, int o) =>
      ByteData.sublistView(b).getUint32(o, Endian.little);
  int u16(Uint8List b, int o) =>
      ByteData.sublistView(b).getUint16(o, Endian.little);

  test('writes a valid RIFF/WAVE header on close', () async {
    final path = '${dir.path}/a.wav';
    final w = await WavWriter.open(path, sampleRate: 16000);
    await w.add(Uint8List.fromList(List.generate(1000, (i) => i & 0xff)));
    await w.add(Uint8List(234));
    await w.close();
    final b = await File(path).readAsBytes();
    expect(b.length, 44 + 1234);
    expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
    expect(u32(b, 4), 36 + 1234);
    expect(String.fromCharCodes(b.sublist(8, 16)), 'WAVEfmt ');
    expect(u16(b, 20), 1); // PCM
    expect(u16(b, 22), 1); // mono
    expect(u32(b, 24), 16000);
    expect(u32(b, 28), 32000); // byte rate
    expect(u16(b, 34), 16);
    expect(String.fromCharCodes(b.sublist(36, 40)), 'data');
    expect(u32(b, 40), 1234);
  });

  test('repair fixes the sizes of an interrupted recording', () async {
    // A crash leaves the placeholder header (sizes 0) and an odd byte count.
    final file = File('${dir.path}/b.wav');
    await file.writeAsBytes([
      ...WavWriter.header(sampleRate: 44100, channels: 1, dataBytes: 0),
      ...Uint8List(5001),
    ]);
    await WavWriter.repair(file, sampleRate: 44100);
    final b = await file.readAsBytes();
    expect(b.length, 44 + 5001);
    expect(u32(b, 40), 5000);
    expect(u32(b, 4), 36 + 5000);
    expect(u32(b, 24), 44100);
  });

  test('repair ignores files too short to hold a header', () async {
    final file = File('${dir.path}/c.wav');
    await file.writeAsBytes([1, 2, 3]);
    await WavWriter.repair(file, sampleRate: 44100);
    expect(await file.readAsBytes(), [1, 2, 3]);
  });
}
