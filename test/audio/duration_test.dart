import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/duration.dart';
import 'package:voice_recorder/src/audio/wav_writer.dart';

/// An MPEG-1 Layer III frame header: 160 kbit/s, 44.1 kHz, [mono].
List<int> _frameHeader({bool mono = true}) => [
  0xFF,
  0xFB,
  0xA0,
  mono ? 0xC0 : 0x00,
];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('duration'));
  tearDown(() => dir.delete(recursive: true));

  File file(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  test('WAV: data size over byte rate', () async {
    final f = file('a.wav', [
      ...WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: 64000),
      ...Uint8List(64000),
    ]);
    expect(await audioDuration(f), const Duration(seconds: 2));
  });

  test('WAV cut off: only the data that is there counts', () async {
    final f = file('b.wav', [
      ...WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: 999999),
      ...Uint8List(32000),
    ]);
    expect(await audioDuration(f), const Duration(seconds: 1));
  });

  test('MP3 constant bitrate: size over bitrate, after an ID3 tag', () async {
    // 160 kbit/s = 20000 bytes per second; 522-byte frames.
    final frame = [..._frameHeader(), ...List.filled(518, 0)];
    final id3 = [0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 20, ...List.filled(20, 0)];
    final f = file('c.mp3', [...id3, for (var i = 0; i < 100; i++) ...frame]);
    final d = await audioDuration(f);
    expect(d!.inMilliseconds, 52200 * 8 ~/ 160);
  });

  test('MP3 with a Xing header: frame count', () async {
    final first = [
      ..._frameHeader(),
      ...List.filled(17, 0), // side info (mono)
      ...'Xing'.codeUnits,
      0, 0, 0, 1, // flags: frame count present
      0, 0, 0, 100, // 100 frames
      ...List.filled(470, 0),
    ];
    final f = file('d.mp3', first);
    // 100 frames x 1152 samples / 44100 Hz
    expect((await audioDuration(f))!.inMilliseconds, 2612);
  });

  test('anything else: unknown', () async {
    expect(await audioDuration(file('e.m4a', [1, 2, 3])), isNull);
    expect(await audioDuration(file('f.mp3', List.filled(100, 0))), isNull);
    expect(await audioDuration(file('g.wav', [1, 2, 3])), isNull);
  });
}
