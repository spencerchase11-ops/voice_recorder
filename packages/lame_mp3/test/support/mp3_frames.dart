import 'dart:typed_data';

/// The fields of an MPEG audio frame header that the tests look at.
class Mp3FrameHeader {
  const Mp3FrameHeader({
    required this.offset,
    required this.version,
    required this.layer,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.channelMode,
    required this.hasCrc,
    required this.frameLength,
  });

  /// Byte offset of the frame in the stream.
  final int offset;

  /// 1 for MPEG-1, 2 for MPEG-2, 25 for MPEG-2.5.
  final int version;

  /// 1, 2 or 3.
  final int layer;
  final int bitrateKbps;
  final int sampleRate;

  /// Channel mode bits: 0 stereo, 1 joint stereo, 2 dual channel, 3 mono.
  final int channelMode;
  final bool hasCrc;

  /// Length of the whole frame in bytes, header included.
  final int frameLength;

  static const int stereo = 0;
  static const int jointStereo = 1;
  static const int mono = 3;

  /// PCM samples per channel that one Layer III frame decodes to.
  int get samplesPerFrame => version == 1 ? 1152 : 576;

  @override
  String toString() =>
      'MPEG-${version == 25 ? '2.5' : version} Layer $layer, '
      '$bitrateKbps kbps, $sampleRate Hz, mode $channelMode, '
      '$frameLength bytes @ $offset';
}

// Layer III bitrates by header index; null = free format (0) or invalid (15).
const List<int?> _layer3BitratesV1 = <int?>[
  // MPEG-1
  null, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, null,
];
const List<int?> _layer3BitratesV2 = <int?>[
  // MPEG-2 and MPEG-2.5
  null, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, null,
];
const Map<int, List<int>> _sampleRates = <int, List<int>>{
  1: <int>[44100, 48000, 32000],
  2: <int>[22050, 24000, 16000],
  25: <int>[11025, 12000, 8000],
};

/// Parses the Layer III frame header at [offset] of [data].
///
/// Throws a [FormatException] if there is no valid Layer III header there
/// (free-format and reserved values are rejected as well).
Mp3FrameHeader parseLayer3Header(Uint8List data, int offset) {
  if (offset + 4 > data.length) {
    throw FormatException('Truncated frame header', data, offset);
  }
  final int b1 = data[offset + 1];
  final int b2 = data[offset + 2];
  final int b3 = data[offset + 3];
  if (data[offset] != 0xFF || (b1 & 0xE0) != 0xE0) {
    throw FormatException('No frame sync', data, offset);
  }
  final int? version = switch ((b1 >> 3) & 3) {
    0 => 25,
    2 => 2,
    3 => 1,
    _ => null,
  };
  if (version == null) {
    throw FormatException('Reserved MPEG version', data, offset);
  }
  final int layer = 4 - ((b1 >> 1) & 3);
  if (layer != 3) {
    throw FormatException('Not Layer III (layer bits: ${(b1 >> 1) & 3})');
  }
  final int? bitrate = (version == 1
      ? _layer3BitratesV1
      : _layer3BitratesV2)[b2 >> 4];
  if (bitrate == null) {
    throw FormatException('Free-format or invalid bitrate', data, offset);
  }
  final int sampleRateIndex = (b2 >> 2) & 3;
  if (sampleRateIndex == 3) {
    throw FormatException('Reserved sample rate', data, offset);
  }
  final int sampleRate = _sampleRates[version]![sampleRateIndex];
  final int padding = (b2 >> 1) & 1;
  final int frameLength = version == 1
      ? 144000 * bitrate ~/ sampleRate + padding
      : 72000 * bitrate ~/ sampleRate + padding;
  if ((b3 & 3) == 2) {
    throw FormatException('Reserved emphasis', data, offset);
  }
  return Mp3FrameHeader(
    offset: offset,
    version: version,
    layer: layer,
    bitrateKbps: bitrate,
    sampleRate: sampleRate,
    channelMode: b3 >> 6,
    hasCrc: (b1 & 1) == 0,
    frameLength: frameLength,
  );
}

/// Splits a raw MP3 stream (no tags) into frames; every byte must belong to a
/// valid Layer III frame and the last frame must be complete.
List<Mp3FrameHeader> parseLayer3Stream(Uint8List data) {
  final List<Mp3FrameHeader> frames = <Mp3FrameHeader>[];
  int offset = 0;
  while (offset < data.length) {
    final Mp3FrameHeader header = parseLayer3Header(data, offset);
    if (offset + header.frameLength > data.length) {
      throw FormatException('Truncated frame: $header', data, offset);
    }
    frames.add(header);
    offset += header.frameLength;
  }
  return frames;
}
