import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/audio/audio_info.dart';
import 'package:voice_recorder/src/audio/wav_writer.dart';

import '../support/fakes.dart';

/// 100 MPEG-1 Layer III frames: 160 kbit/s, 44.1 kHz, mono (522 bytes each),
/// which play for 2.61 s.
List<int> _frames([int count = 100]) => [
  for (var i = 0; i < count; i++) ...[
    0xFF,
    0xFB,
    0xA0,
    0xC0,
    ...List.filled(518, 0),
  ],
];

/// An ID3v2.3 tag with the given text frames.
List<int> _id3v23(Map<String, String> frames) {
  final body = <int>[];
  frames.forEach((id, text) {
    final data = [0, ...text.codeUnits]; // ISO-8859-1
    body
      ..addAll(id.codeUnits)
      ..addAll([
        (data.length >> 24) & 0xFF,
        (data.length >> 16) & 0xFF,
        (data.length >> 8) & 0xFF,
        data.length & 0xFF,
      ])
      ..addAll([0, 0])
      ..addAll(data);
  });
  body.addAll(List.filled(20, 0)); // padding
  final size = body.length;
  return [
    ...'ID3'.codeUnits,
    3,
    0,
    0,
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...body,
  ];
}

/// An ID3v1 tag (always the last 128 bytes).
List<int> _id3v1() => [...'TAG'.codeUnits, ...List.filled(125, 0x20)];

/// An MP4 box.
List<int> _box(String type, List<int> body) {
  final size = 8 + body.length;
  return [
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...body,
  ];
}

/// A movie header: version 0 (32-bit times) or 1 (64-bit).
List<int> _mvhd({
  required int version,
  required int created,
  required int timescale,
  required int duration,
}) {
  final b = ByteData(version == 1 ? 32 : 20);
  b.setUint8(0, version);
  if (version == 1) {
    b
      ..setUint64(4, created)
      ..setUint64(12, created)
      ..setUint32(20, timescale)
      ..setUint64(24, duration);
  } else {
    b
      ..setUint32(4, created)
      ..setUint32(8, created)
      ..setUint32(12, timescale)
      ..setUint32(16, duration);
  }
  return _box('mvhd', [...b.buffer.asUint8List(), ...List.filled(80, 0)]);
}

/// Seconds since 1904 (the MP4 epoch) for [t].
int _mp4Time(DateTime t) => t.millisecondsSinceEpoch ~/ 1000 + 2082844800;

Future<AudioInfo> _info(List<int> bytes, String name) =>
    readAudioInfo(MemoryBytes(bytes), name);

void main() {
  final recorded = DateTime(2026, 9, 25, 3, 30, 5);

  group('dates in text', () {
    test('full dates in the usual forms', () {
      expect(parseDateText('2026-09-25T03:30:05'), recorded);
      expect(parseDateText('2026-09-25 03:30:05'), recorded);
      expect(parseDateText('2026:09:25 03:30:05'), recorded);
      expect(parseDateText('2026-09-25'), DateTime(2026, 9, 25));
      expect(parseDateText('2026-9-5 3:07'), DateTime(2026, 9, 5, 3, 7));
      expect(
        parseDateText('2026-09-25T01:30:05Z'),
        DateTime.utc(2026, 9, 25, 1, 30, 5).toLocal(),
      );
    });

    test('partial, impossible and placeholder dates are ignored', () {
      expect(parseDateText('2026'), isNull);
      expect(parseDateText('2026-09'), isNull);
      expect(parseDateText('2026-13-01'), isNull);
      expect(parseDateText('2026-02-30'), isNull);
      expect(parseDateText('1970-01-01 00:00:00'), isNull);
      expect(parseDateText('2999-01-01'), isNull); // in the future
      expect(parseDateText('lunch'), isNull);
    });
  });

  group('MP3', () {
    test('the tag written at the start of a recording', () async {
      final info = await _info([
        ...id3DateTag(recorded),
        ..._frames(),
      ], 'a.mp3');
      expect(info.recorded, recorded);
      expect(info.duration!.inMilliseconds, 52200 * 8 ~/ 160);
    });

    test('ID3v2.3: year, day and month, time in separate frames', () async {
      final info = await _info([
        ..._id3v23({
          'TIT2': 'Lunch',
          'TYER': '2016',
          'TDAT': '2305',
          'TIME': '1814',
        }),
        ..._frames(),
      ], 'b.mp3');
      expect(info.recorded, DateTime(2016, 5, 23, 18, 14));
    });

    test('a bare year is not a recording date', () async {
      final info = await _info([
        ..._id3v23({'TYER': '2016'}),
        ..._frames(),
      ], 'c.mp3');
      expect(info.recorded, isNull);
      expect(info.duration, isNotNull);
    });

    test('a date added to an old file goes at the end, before ID3v1', () async {
      final bytes = [..._frames(), ..._id3v1()];
      final a = MemoryBytes(bytes);
      expect(await readAudioInfo(a, 'd.mp3'), isA<AudioInfo>());
      final before = (await readAudioInfo(a, 'd.mp3')).duration;
      expect(await writeRecordedDate(a, 'd.mp3', recorded), isTrue);
      // ID3v1 is still the last 128 bytes; the frames are untouched.
      expect(
        String.fromCharCodes(
          bytes.sublist(bytes.length - 128, bytes.length - 125),
        ),
        'TAG',
      );
      expect(bytes.sublist(0, 52200), _frames());
      final info = await readAudioInfo(a, 'd.mp3');
      expect(info.recorded, recorded);
      expect(info.duration, before);
      // Only once.
      final length = bytes.length;
      expect(await writeRecordedDate(a, 'd.mp3', DateTime(2020)), isTrue);
      expect(bytes.length, length);
      expect((await readAudioInfo(a, 'd.mp3')).recorded, recorded);
    });

    test('files that are not MP3s are left alone', () async {
      final bytes = List.filled(5000, 7);
      expect(
        await writeRecordedDate(MemoryBytes(bytes), 'e.mp3', recorded),
        isFalse,
      );
      expect(bytes, List.filled(5000, 7));
    });
  });

  group('WAV', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('info_wav'));
    tearDown(() => dir.delete(recursive: true));

    List<int> plain(int dataBytes) => [
      ...WavWriter.header(sampleRate: 16000, channels: 1, dataBytes: dataBytes),
      ...Uint8List(dataBytes),
    ];

    test('a date added to an old file: a LIST chunk after the data', () async {
      final bytes = plain(32000);
      final a = MemoryBytes(bytes);
      expect((await readAudioInfo(a, 'a.wav')).recorded, isNull);
      expect(await writeRecordedDate(a, 'a.wav', recorded), isTrue);
      final info = await readAudioInfo(a, 'a.wav');
      expect(info.recorded, recorded);
      expect(info.duration, const Duration(seconds: 1));
      final riff = ByteData.sublistView(Uint8List.fromList(bytes));
      expect(riff.getUint32(4, Endian.little), bytes.length - 8);
    });

    test('a file with damaged chunks is left alone', () async {
      final cutOff = plain(32000).sublist(0, 20000); // data claims more
      final withJunk = [...plain(3200), 1, 2, 3];
      for (final bytes in [cutOff, withJunk]) {
        final copy = [...bytes];
        expect(
          await writeRecordedDate(MemoryBytes(copy), 'b.wav', recorded),
          isFalse,
        );
        expect(copy, bytes);
      }
    });

    test('Broadcast WAV origination date', () async {
      final bext = List.filled(602, 0x20);
      bext.setRange(320, 338, '2016-05-2318:14:00'.codeUnits);
      final body = [
        ...'WAVE'.codeUnits,
        ...'bext'.codeUnits,
        ...[bext.length & 0xFF, bext.length >> 8, 0, 0],
        ...bext,
        ...WavWriter.header(
          sampleRate: 8000,
          channels: 1,
          dataBytes: 16000,
        ).sublist(12),
        ...Uint8List(16000),
      ];
      final bytes = [
        ...'RIFF'.codeUnits,
        ...[
          body.length & 0xFF,
          (body.length >> 8) & 0xFF,
          body.length >> 16,
          0,
        ],
        ...body,
      ];
      final info = await _info(bytes, 'c.wav');
      expect(info.recorded, DateTime(2016, 5, 23, 18, 14));
      expect(info.duration, const Duration(seconds: 1));
    });
  });

  group('M4A', () {
    List<int> m4a({int version = 0, int? created}) => [
      ..._box('ftyp', 'M4A isom'.codeUnits),
      ..._box('mdat', List.filled(1000, 1)),
      ..._box('moov', [
        ..._mvhd(
          version: version,
          created: created ?? _mp4Time(DateTime(2026, 9, 25, 4)),
          timescale: 44100,
          duration: 44100 * 90,
        ),
        ..._box('trak', List.filled(40, 0)),
      ]),
    ];

    test('length and creation time from the movie header', () async {
      for (final version in [0, 1]) {
        final info = await _info(m4a(version: version), 'a.m4a');
        expect(info.duration, const Duration(seconds: 90));
        expect(info.recorded, DateTime(2026, 9, 25, 4));
      }
    });

    test('an unset creation time is no date', () async {
      expect((await _info(m4a(created: 0), 'b.m4a')).recorded, isNull);
    });

    test('the recording date replaces the creation time', () async {
      for (final version in [0, 1]) {
        final bytes = m4a(version: version, created: 0);
        final length = bytes.length;
        final a = MemoryBytes(bytes);
        expect(await writeRecordedDate(a, 'c.m4a', recorded), isTrue);
        expect(bytes.length, length); // changed in place
        final info = await readAudioInfo(a, 'c.m4a');
        expect(info.recorded, recorded);
        expect(info.duration, const Duration(seconds: 90));
      }
    });

    test('without an index there is nothing to read or write', () async {
      final bytes = [
        ..._box('ftyp', 'M4A isom'.codeUnits),
        ..._box('mdat', List.filled(100, 1)),
      ];
      expect(await _info(bytes, 'd.m4a'), AudioInfo.empty);
      expect(
        await writeRecordedDate(MemoryBytes([...bytes]), 'd.m4a', recorded),
        isFalse,
      );
    });
  });

  test('other formats: nothing to read or write', () async {
    expect(await _info([1, 2, 3], 'a.ogg'), AudioInfo.empty);
    expect(canStoreRecordedDate('a.ogg'), isFalse);
    expect(canStoreRecordedDate('a.MP3'), isTrue);
    expect(
      await writeRecordedDate(MemoryBytes([1, 2, 3]), 'a.flac', recorded),
      isFalse,
    );
  });

  test('damaged files read as empty instead of failing', () async {
    for (final name in ['a.mp3', 'a.wav', 'a.m4a']) {
      for (final bytes in [
        <int>[],
        [0x49, 0x44, 0x33, 4, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F],
        List.filled(64, 0xFF),
        'RIFF\x00\x00\x00\x00WAVEfmt '.codeUnits,
        _box('moov', _box('mvhd', [1, 0, 0])),
      ]) {
        final info = await _info(bytes, name);
        expect(info.recorded, isNull, reason: '$name $bytes');
      }
    }
  });
}
