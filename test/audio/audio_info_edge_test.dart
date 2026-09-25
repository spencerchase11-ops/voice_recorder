// Edge cases of reading and storing recording dates: files from other
// programs, and writes that must never damage a recording.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/m4a.dart';
import 'package:voice_recorder/src/audio/wav_writer.dart';

import '../support/fakes.dart';

/// [count] MPEG-1 Layer III frames: 160 kbit/s, 44.1 kHz, mono, 522 bytes.
List<int> _frames([int count = 100]) => [
  for (var i = 0; i < count; i++) ...[
    0xFF,
    0xFB,
    0xA0,
    0xC0,
    ...List.filled(518, 0),
  ],
];

List<int> _id3v1() => [...'TAG'.codeUnits, ...List.filled(125, 0x20)];

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// An ID3v2 tag of [version] 2, 3 or 4 holding [frames] (id, text; a null
/// text makes a frame of size 0). With [plainSizes], v2.4 frame sizes are
/// written as plain numbers (older iTunes).
List<int> _tag(
  int version,
  List<(String, String?)> frames, {
  bool plainSizes = false,
}) {
  final body = <int>[];
  for (final (id, text) in frames) {
    final data = text == null ? <int>[] : [0, ...text.codeUnits];
    final n = data.length;
    body.addAll(id.codeUnits);
    if (version == 2) {
      body.addAll([(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]);
    } else if (version == 4 && !plainSizes) {
      body.addAll([
        (n >> 21) & 0x7F,
        (n >> 14) & 0x7F,
        (n >> 7) & 0x7F,
        n & 0x7F,
      ]);
      body.addAll([0, 0]);
    } else {
      body
        ..addAll(_be32(n))
        ..addAll([0, 0]);
    }
    body.addAll(data);
  }
  body.addAll(List.filled(16, 0)); // padding
  final size = body.length;
  return [
    ...'ID3'.codeUnits,
    version,
    0,
    0,
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...body,
  ];
}

List<int> _box(String type, List<int> body) => [
  ..._be32(8 + body.length),
  ...type.codeUnits,
  ...body,
];

Future<AudioInfo> _info(List<int> bytes, String name) =>
    readAudioInfo(MemoryBytes(bytes), name);

void main() {
  final recorded = DateTime(2026, 9, 25, 3, 30, 5);

  group('MP3 frames', () {
    test('bytes that only look like a frame header are not an MP3', () async {
      // Another format's data with a stray "header" (as in an M4A named
      // .mp3): nothing that looks like a frame follows it.
      final bytes = [
        ...List.filled(300, 0x11),
        0xFF, 0xFB, 0xA0, 0xC0, //
        ...List.filled(3000, 0x22),
      ];
      expect((await _info(bytes, 'a.mp3')).duration, isNull);
      final copy = [...bytes];
      expect(
        await writeRecordedDate(MemoryBytes(copy), 'a.mp3', recorded),
        isFalse,
      );
      expect(copy, bytes);
    });

    test('a single frame, the whole file, is one', () async {
      expect((await _info(_frames(1), 'b.mp3')).duration, isNotNull);
    });
  });

  group('MP3 tags from other programs', () {
    test('ID3v2.2: year, day and month, time', () async {
      final info = await _info([
        ..._tag(2, [
          ('TT2', 'Lunch'),
          ('TYE', '2016'),
          ('TDA', '2305'),
          ('TIM', '1814'),
        ]),
        ..._frames(),
      ], 'a.mp3');
      expect(info.recorded, DateTime(2016, 5, 23, 18, 14));
    });

    test('ID3v2.4 with plain (not syncsafe) frame sizes', () async {
      // A title of 200 bytes: its size isn't a valid syncsafe number.
      final info = await _info([
        ..._tag(4, [
          ('TIT2', 'x' * 200),
          ('TDRC', '2016-05-23T18:14:00'),
        ], plainSizes: true),
        ..._frames(),
      ], 'b.mp3');
      expect(info.recorded, DateTime(2016, 5, 23, 18, 14));
    });

    test('an empty frame before the date', () async {
      final info = await _info([
        ..._tag(3, [('TIT2', null), ('TYER', '2016'), ('TDAT', '2305')]),
        ..._frames(),
      ], 'c.mp3');
      expect(info.recorded, DateTime(2016, 5, 23));
    });
  });

  group('storing a date in an MP3', () {
    test('a placeholder or future date is not written', () async {
      for (final date in [DateTime(1970), DateTime(2999)]) {
        final bytes = _frames();
        expect(
          await writeRecordedDate(MemoryBytes(bytes), 'a.mp3', date),
          isFalse,
        );
        expect(bytes, _frames());
      }
    });

    test('never a second tag at the end', () async {
      // An appended tag without a date (another program's): none is added.
      final foreign = [
        ..._tag(4, [('TIT2', 'Lunch')]),
      ];
      // Turn it into an appended tag: flags with a footer, and the footer.
      foreign[5] = 0x10;
      final withFooter = [
        ...foreign,
        ...'3DI'.codeUnits,
        ...foreign.sublist(3, 10),
      ];
      final bytes = [..._frames(), ...withFooter];
      final copy = [...bytes];
      expect(
        await writeRecordedDate(MemoryBytes(copy), 'b.mp3', recorded),
        isFalse,
      );
      expect(copy, bytes);
    });

    test('APE and Lyrics3 tags before ID3v1 are left alone', () async {
      final ape = [
        ...'APETAGEX'.codeUnits,
        ...[0xD0, 0x07, 0, 0], // version 2000
        ...[32, 0, 0, 0], // size: the footer alone
        ...[0, 0, 0, 0], // no items
        ...[0, 0, 0, 0], // flags: no header
        ...List.filled(8, 0),
      ];
      final lyrics = [
        ...'LYRICSBEGIN'.codeUnits,
        ...'000011'.codeUnits,
        ...'LYRICS200'.codeUnits,
      ];
      for (final other in [ape, lyrics]) {
        final bytes = [..._frames(), ...other, ..._id3v1()];
        final copy = [...bytes];
        expect(
          await writeRecordedDate(MemoryBytes(copy), 'c.mp3', recorded),
          isFalse,
        );
        expect(copy, bytes);
        // The length leaves the tags out.
        expect(
          (await _info(bytes, 'c.mp3')).duration,
          (await _info(_frames(), 'c.mp3')).duration,
        );
      }
    });

    test('storage full halfway: the file is put back as it was', () async {
      for (final withV1 in [true, false]) {
        final bytes = [..._frames(), if (withV1) ..._id3v1()];
        final original = [...bytes];
        // Room for part of the tag only.
        final a = MemoryBytes(bytes, room: 20);
        await expectLater(
          writeRecordedDate(a, 'd.mp3', recorded),
          throwsA(isA<FileSystemException>()),
        );
        expect(bytes, original, reason: 'ID3v1: $withV1');
      }
    });
  });

  test('WAV: storage full halfway: the file is put back as it was', () async {
    final bytes = [
      ...WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: 3200),
      ...Uint8List(3200),
    ];
    final original = [...bytes];
    await expectLater(
      writeRecordedDate(MemoryBytes(bytes, room: 10), 'a.wav', recorded),
      throwsA(isA<FileSystemException>()),
    );
    expect(bytes, original);
  });

  group('M4A', () {
    test('a movie header too short to hold the date is left alone', () async {
      final bytes = [
        ..._box('ftyp', 'M4A '.codeUnits),
        ..._box('moov', [
          ..._box('mvhd', [0, 0, 0]),
          ..._box('trak', List.filled(40, 9)),
        ]),
      ];
      final copy = [...bytes];
      expect(
        await writeRecordedDate(MemoryBytes(copy), 'a.m4a', recorded),
        isFalse,
      );
      expect(copy, bytes);
    });

    test('an index cut off while it was written is no index', () async {
      final dir = await Directory.systemTemp.createTemp('m4a_cut');
      addTearDown(() => dir.delete(recursive: true));
      final full = _box('moov', List.filled(400, 1));
      final f = File('${dir.path}/a.m4a')
        ..writeAsBytesSync([
          ..._box('ftyp', 'M4A '.codeUnits),
          ..._box('mdat', List.filled(1000, 7)),
          ...full.sublist(0, 200), // the rest never made it to disk
        ]);
      expect(await hasMp4Index(f), isFalse);
    });
  });

  group('dates in text', () {
    test('offsets, fractions of a second and an hour alone', () {
      expect(
        parseDateText('2026-09-25T03:30:05+02:00'),
        DateTime.utc(2026, 9, 25, 1, 30, 5).toLocal(),
      );
      expect(
        parseDateText('2026-09-25T03:30:05-0130'),
        DateTime.utc(2026, 9, 25, 5, 0, 5).toLocal(),
      );
      expect(
        parseDateText('2026-09-25T03:30:05.5Z'),
        DateTime.utc(2026, 9, 25, 3, 30, 5).toLocal(),
      );
      expect(parseDateText('2016-09-18T21'), DateTime(2016, 9, 18, 21));
      expect(parseDateText('2016-09-18T24:00'), isNull);
    });
  });

  test('WAV repair keeps a finished recording with no sound', () async {
    final dir = await Directory.systemTemp.createTemp('wav_empty');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/a.wav';
    final w = await WavWriter.open(path, sampleRate: 16000, recorded: recorded);
    await w.close(); // no audio, then the date
    final before = File(path).readAsBytesSync();
    await WavWriter.repair(File(path), sampleRate: 16000);
    expect(File(path).readAsBytesSync(), before);
    final a = await FileByteAccess.open(File(path));
    addTearDown(a.close);
    expect((await readAudioInfo(a, 'a.wav')).recorded, recorded);
  });
}
