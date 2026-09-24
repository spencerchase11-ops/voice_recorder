import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/m4a.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';

Uint8List _box(String type, List<int> body, {int? size}) {
  final b = BytesBuilder();
  final s = ByteData(4)..setUint32(0, size ?? 8 + body.length);
  b
    ..add(s.buffer.asUint8List())
    ..add(type.codeUnits)
    ..add(body);
  return b.toBytes();
}

void main() {
  test('stereo PCM is averaged down to mono', () {
    final stereo = ByteData(12)
      ..setInt16(0, 1000, Endian.little)
      ..setInt16(2, 3000, Endian.little)
      ..setInt16(4, -32768, Endian.little)
      ..setInt16(6, -32768, Endian.little)
      ..setInt16(8, 32767, Endian.little)
      ..setInt16(10, -32768, Endian.little);
    final mono = ByteData.sublistView(
      downmixToMono(stereo.buffer.asUint8List()),
    );
    expect(mono.lengthInBytes, 6);
    expect(mono.getInt16(0, Endian.little), 2000);
    expect(mono.getInt16(2, Endian.little), -32768);
    expect(mono.getInt16(4, Endian.little), -1);
  });

  test('level meter mapping', () {
    expect(levelFromDb(0), 1);
    expect(levelFromDb(-25), 0.5);
    expect(levelFromDb(-160), 0);
    expect(peakDb(Uint8List(8)), -160);
  });

  group('hasMp4Index', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('m4a'));
    tearDown(() => dir.delete(recursive: true));

    Future<File> file(List<int> bytes) async =>
        File('${dir.path}/a.m4a')..writeAsBytesSync(bytes);

    test('a finalized file (index at the end) is playable', () async {
      final f = await file([
        ..._box('ftyp', List.filled(16, 0)),
        ..._box('mdat', List.filled(5000, 7)),
        ..._box('moov', List.filled(100, 1)),
      ]);
      expect(await hasMp4Index(f), isTrue);
    });

    test('an index at the start is found too', () async {
      final f = await file([
        ..._box('ftyp', List.filled(16, 0)),
        ..._box('moov', List.filled(100, 1)),
        ..._box('mdat', List.filled(5000, 7)),
      ]);
      expect(await hasMp4Index(f), isTrue);
    });

    test('a file cut off while recording is not', () async {
      // mdat still has the placeholder size 0 ("to the end of the file")
      expect(
        await hasMp4Index(
          await file([
            ..._box('ftyp', List.filled(16, 0)),
            ..._box('mdat', List.filled(5000, 7), size: 0),
          ]),
        ),
        isFalse,
      );
      // or a size that runs past the end of what was written
      expect(
        await hasMp4Index(
          await file([
            ..._box('ftyp', List.filled(16, 0)),
            ..._box('mdat', List.filled(100, 7), size: 900000),
          ]),
        ),
        isFalse,
      );
    });

    test('64-bit box sizes are followed', () async {
      final big = ByteData(16)
        ..setUint32(0, 1)
        ..setUint8(4, 'm'.codeUnitAt(0))
        ..setUint8(5, 'd'.codeUnitAt(0))
        ..setUint8(6, 'a'.codeUnitAt(0))
        ..setUint8(7, 't'.codeUnitAt(0))
        ..setUint64(8, 16 + 40);
      final f = await file([
        ..._box('ftyp', List.filled(16, 0)),
        ...big.buffer.asUint8List(),
        ...List.filled(40, 3),
        ..._box('moov', List.filled(10, 1)),
      ]);
      expect(await hasMp4Index(f), isTrue);
    });

    test('garbage is not an index', () async {
      expect(await hasMp4Index(await file([1, 2, 3])), isFalse);
      expect(await hasMp4Index(await file(List.filled(64, 0))), isFalse);
    });
  });
}
