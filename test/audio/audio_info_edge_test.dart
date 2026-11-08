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

/// Layer III streams for VBR headers: MPEG-1 at 44.1 kHz, stereo, and
/// MPEG-2 at 22.05 kHz, mono. [b1] and [b3] are header bytes 1 and 3, [side]
/// the size of the side information, [lengths] frame lengths by bitrate
/// index.
typedef _Stream = ({int b1, int b3, int side, Map<int, int> lengths});

const _Stream _mpeg1 = (
  b1: 0xFB,
  b3: 0x00,
  side: 32,
  lengths: {9: 417, 10: 522, 11: 626}, // 128, 160, 192 kbit/s
);

const _Stream _mpeg2 = (
  b1: 0xF3,
  b3: 0xC0,
  side: 9,
  lengths: {4: 104, 8: 208, 10: 313}, // 32, 64, 96 kbit/s
);

/// What the 1000 frames a VBR header below counts play for: 1152 samples
/// each at 44.1 kHz (MPEG-1), or 576 at 22.05 kHz (MPEG-2).
const _thousandFrames = Duration(microseconds: 1000 * 1152 * 1000000 ~/ 44100);

List<int> _frame(_Stream s, int index) => [
  0xFF,
  s.b1,
  index << 4,
  s.b3,
  ...List.filled(s.lengths[index]! - 4, 0),
];

/// The first frame of a VBR stream, with a [tag] header ('Xing' or 'VBRI')
/// saying the stream has 1000 frames. Xing comes after the side
/// information, VBRI always 32 bytes after the frame header.
List<int> _vbrFrame(_Stream s, String tag) {
  final f = _frame(s, s.lengths.keys.elementAt(1));
  final at = tag == 'VBRI' ? 36 : 4 + s.side;
  f.setAll(at, tag.codeUnits);
  if (tag == 'VBRI') {
    f.setAll(at + 4, [0, 1]); // version 1
    f.setAll(at + 14, _be32(1000));
  } else {
    f.setAll(at + 4, _be32(1)); // flags: frame count present
    f.setAll(at + 8, _be32(1000));
  }
  return f;
}

/// The frames after the first, of mixed bitrates.
List<int> _mixed(_Stream s) => [
  for (var i = 0; i < 30; i++) ..._frame(s, s.lengths.keys.elementAt(i % 3)),
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

    test('a Xing header just past the first 4 KB read', () async {
      // Junk before the audio: the first frame's header is in the first
      // 4096 bytes read, its Xing header (36 bytes in) runs past them.
      final bytes = [
        ...List.filled(4060, 0),
        ..._vbrFrame(_mpeg1, 'Xing'),
        ..._mixed(_mpeg1),
      ];
      expect((await _info(bytes, 'c.mp3')).duration, _thousandFrames);
    });

    test('a VBRI header (Fraunhofer encoders) counts the frames', () async {
      // 32 bytes after the frame header whatever the MPEG version, where a
      // Xing header would be after the side information.
      for (final (header, name) in [(_mpeg1, 'd.mp3'), (_mpeg2, 'e.mp3')]) {
        final bytes = [..._vbrFrame(header, 'VBRI'), ..._mixed(header)];
        expect((await _info(bytes, name)).duration, _thousandFrames);
      }
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

    test('a negative offset after the minutes is not the seconds', () {
      final utc = DateTime.utc(2026, 9, 25, 10, 30).toLocal();
      expect(parseDateText('2026-09-25T03:30-07:00'), utc);
      expect(parseDateText('2026-09-25T03:30-0700'), utc);
      expect(
        parseDateText('2026-09-25T03-07:00'),
        DateTime.utc(2026, 9, 25, 10).toLocal(),
      );
      // A time written with dashes keeps its minutes and seconds.
      expect(
        parseDateText('2026-09-25 03-30-07'),
        DateTime(2026, 9, 25, 3, 30, 7),
      );
      expect(
        parseDateText('2026-09-25_03-30-07-07:00'),
        DateTime.utc(2026, 9, 25, 10, 30, 7).toLocal(),
      );
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
