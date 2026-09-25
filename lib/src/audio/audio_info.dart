/// What a recording says about itself: when it was recorded and how long it
/// plays, read from its own headers and tags rather than from its name.
///
/// The recording date is stored inside every new recording (MP3: an ID3v2.4
/// "TDRC" frame, WAV: a LIST/INFO "ICRD" chunk, M4A: the movie header's
/// creation time), so recordings stay in date order whatever they are named.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/format.dart' show splitExtension;

/// Random access to a file's bytes: a local file, or (Android) a document in
/// the recordings folder.
abstract class ByteAccess {
  Future<int> length();

  /// Up to [count] bytes from [offset]; fewer at the end of the file.
  Future<Uint8List> read(int offset, int count);

  /// Writes [bytes] at [offset], growing the file if needed. Only for an
  /// access opened for writing.
  Future<void> write(int offset, List<int> bytes);

  Future<void> close();
}

/// [ByteAccess] to a local file.
class FileByteAccess implements ByteAccess {
  FileByteAccess._(this._raf);

  static Future<FileByteAccess> open(File file, {bool write = false}) async {
    // Append mode would create a missing file (e.g. one deleted in the
    // Files app meanwhile); it must stay missing.
    if (write && !await file.exists()) {
      throw FileSystemException('The file no longer exists', file.path);
    }
    return FileByteAccess._(
      // Dart's append mode reads and writes anywhere (it doesn't truncate).
      await file.open(mode: write ? FileMode.append : FileMode.read),
    );
  }

  final RandomAccessFile _raf;

  @override
  Future<int> length() => _raf.length();

  @override
  Future<Uint8List> read(int offset, int count) async {
    await _raf.setPosition(offset);
    return _raf.read(count);
  }

  @override
  Future<void> write(int offset, List<int> bytes) async {
    await _raf.setPosition(offset);
    await _raf.writeFrom(bytes);
  }

  @override
  Future<void> close() => _raf.close();
}

/// When a recording was made and how long it plays; null where the file
/// doesn't tell.
class AudioInfo {
  const AudioInfo({this.recorded, this.duration});

  static const empty = AudioInfo();

  final DateTime? recorded;
  final Duration? duration;

  AudioInfo copyWith({DateTime? recorded, Duration? duration}) => AudioInfo(
    recorded: recorded ?? this.recorded,
    duration: duration ?? this.duration,
  );

  @override
  bool operator ==(Object other) =>
      other is AudioInfo &&
      other.recorded == recorded &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(recorded, duration);

  @override
  String toString() => 'AudioInfo($recorded, $duration)';
}

/// Formats whose files can carry a recording date ([writeRecordedDate]).
bool canStoreRecordedDate(String fileName) => switch (_ext(fileName)) {
  'mp3' || 'wav' || 'm4a' || 'mp4' || '3gp' => true,
  _ => false,
};

String _ext(String fileName) => splitExtension(fileName).$2.toLowerCase();

/// Reads the recording date and playing time of [fileName]'s content.
/// Damaged or unknown files give [AudioInfo.empty]; I/O errors are thrown.
Future<AudioInfo> readAudioInfo(ByteAccess a, String fileName) async {
  try {
    return switch (_ext(fileName)) {
      'mp3' => await _mp3Info(a),
      'wav' => await _wavInfo(a),
      'm4a' || 'mp4' || '3gp' => await _mp4Info(a),
      _ => AudioInfo.empty,
    };
  } on RangeError {
    return AudioInfo.empty; // a field pointing outside a short read
  } on FormatException {
    return AudioInfo.empty;
  }
}

/// Stores [recorded] inside the file, for a file that doesn't have a date
/// yet (its name is about to change, and with it the date in the name).
/// Appends a small tag (MP3, WAV) or sets the creation time (M4A). Returns
/// false when the format or the file doesn't allow it.
Future<bool> writeRecordedDate(
  ByteAccess a,
  String fileName,
  DateTime recorded,
) async {
  try {
    return switch (_ext(fileName)) {
      'mp3' => await _appendId3(a, recorded),
      'wav' => await _appendWavInfo(a, recorded),
      'm4a' || 'mp4' || '3gp' => await _setMp4Created(a, recorded),
      _ => false,
    };
  } on RangeError {
    return false;
  } on FormatException {
    return false;
  }
}

// ======================================================================
// Shared helpers
// ======================================================================

String _ascii(Uint8List b, int start, int end) =>
    String.fromCharCodes(b, start, math.min(end, b.length));

int _u32le(Uint8List b, int o) =>
    ByteData.sublistView(b).getUint32(o, Endian.little);
int _u32be(Uint8List b, int o) => ByteData.sublistView(b).getUint32(o);
int _u64be(Uint8List b, int o) => ByteData.sublistView(b).getUint64(o);

int _synchsafe(Uint8List b, int o) =>
    ((b[o] & 0x7F) << 21) |
    ((b[o + 1] & 0x7F) << 14) |
    ((b[o + 2] & 0x7F) << 7) |
    (b[o + 3] & 0x7F);

List<int> _synchsafeBytes(int v) => [
  (v >> 21) & 0x7F,
  (v >> 14) & 0x7F,
  (v >> 7) & 0x7F,
  v & 0x7F,
];

String _two(int v) => v.toString().padLeft(2, '0');

/// `2026-09-25T03:30:00`, local time (the recording's name uses local time
/// too).
String _isoLocal(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}'
    'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

final _dateText = RegExp(
  r'^\s*(\d{4})[-:/.](\d{1,2})[-:/.](\d{1,2})'
  r'(?:[ T_](\d{1,2})[-:._](\d{2})(?:[-:._](\d{2}))?)?\s*(Z)?',
);

/// A full date (at least year, month and day) written in a tag, e.g.
/// `2026-09-25T03:30:00`, `2026-09-25 03:30`, `2026:09:25`. Local time unless
/// it ends in `Z`. Null for partial dates such as a bare year.
DateTime? parseDateText(String s) {
  final m = _dateText.firstMatch(s);
  if (m == null) return null;
  int part(int i) => m.group(i) == null ? 0 : int.parse(m.group(i)!);
  final y = part(1), mo = part(2), d = part(3);
  final h = part(4), mi = part(5), sec = part(6);
  final t = m.group(7) == null
      ? DateTime(y, mo, d, h, mi, sec)
      : DateTime.utc(y, mo, d, h, mi, sec).toLocal();
  final check = m.group(7) == null ? t : t.toUtc();
  // DateTime rolls impossible values over (month 13): reject those.
  if (check.year != y ||
      check.month != mo ||
      check.day != d ||
      check.hour != h ||
      check.minute != mi ||
      check.second != sec) {
    return null;
  }
  return _plausible(t) ? t : null;
}

/// Rejects placeholder dates (zero, 1904, 1970) and dates in the future.
bool _plausible(DateTime t) =>
    t.year >= 1990 && t.isBefore(DateTime.now().add(const Duration(days: 2)));

// ======================================================================
// MP3: ID3v2 tags, MPEG frame headers
// ======================================================================

bool _isId3(Uint8List h, int o, String magic) =>
    h.length >= o + 10 &&
    _ascii(h, o, o + 3) == magic &&
    h[o + 3] >= 2 &&
    h[o + 3] <= 4 &&
    h[o + 3] != 0xFF &&
    h[o + 6] < 0x80 &&
    h[o + 7] < 0x80 &&
    h[o + 8] < 0x80 &&
    h[o + 9] < 0x80;

/// Largest tag read in full; the date frame of a tag with big pictures in
/// front of it is missed (nothing this app writes looks like that).
const _maxTagRead = 256 * 1024;

/// The ID3v2.4 tag this app writes: one "TDRC" (recording time) frame.
/// With [footer] it can be appended to the end of a file.
Uint8List id3DateTag(DateTime recorded, {bool footer = false}) {
  final text = utf8.encode(_isoLocal(recorded));
  final body = [3, ...text]; // 3: UTF-8
  final frame = [
    ...'TDRC'.codeUnits,
    ..._synchsafeBytes(body.length),
    0,
    0,
    ...body,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    4,
    0,
    footer ? 0x10 : 0,
    ..._synchsafeBytes(frame.length),
    ...frame,
    if (footer) ...[
      ...'3DI'.codeUnits,
      4,
      0,
      0x10,
      ..._synchsafeBytes(frame.length),
    ],
  ]);
}

/// Undoes ID3 unsynchronisation (0xFF 0x00 -> 0xFF).
Uint8List _deunsync(Uint8List b) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < b.length; i++) {
    out.addByte(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0) i++;
  }
  return out.takeBytes();
}

String _decodeText(Uint8List data) {
  if (data.isEmpty) return '';
  final enc = data[0];
  final raw = Uint8List.sublistView(data, 1);
  String s;
  switch (enc) {
    case 1: // UTF-16 with a byte order mark
    case 2: // UTF-16BE
      var little = false;
      var start = 0;
      if (enc == 1 && raw.length >= 2) {
        if (raw[0] == 0xFF && raw[1] == 0xFE) {
          little = true;
          start = 2;
        } else if (raw[0] == 0xFE && raw[1] == 0xFF) {
          start = 2;
        }
      }
      final units = <int>[];
      for (var i = start; i + 1 < raw.length; i += 2) {
        units.add(
          little ? raw[i] | (raw[i + 1] << 8) : (raw[i] << 8) | raw[i + 1],
        );
      }
      s = String.fromCharCodes(units);
    case 3:
      s = utf8.decode(raw, allowMalformed: true);
    default:
      s = latin1.decode(raw);
  }
  final nul = s.indexOf('\u0000');
  return nul < 0 ? s : s.substring(0, nul);
}

/// The recording date in an ID3v2.2/2.3/2.4 [tag] (starting at its header).
DateTime? parseId3Date(Uint8List tag) {
  if (!_isId3(tag, 0, 'ID3')) return null;
  final major = tag[3];
  final flags = tag[5];
  final size = _synchsafe(tag, 6);
  var body = Uint8List.sublistView(tag, 10, math.min(tag.length, 10 + size));
  if (major < 4 && (flags & 0x80) != 0) body = _deunsync(body);
  var pos = 0;
  if ((flags & 0x40) != 0 && major >= 3 && body.length >= 4) {
    // Extended header: v2.3 gives its size without itself, v2.4 with.
    pos = major == 3 ? 4 + _u32be(body, 0) : _synchsafe(body, 0);
  }
  final idLen = major == 2 ? 3 : 4;
  final headLen = major == 2 ? 6 : 10;
  final text = <String, String>{};
  while (pos + headLen <= body.length) {
    final id = _ascii(body, pos, pos + idLen);
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id) || id.length != idLen) break;
    final frameSize = switch (major) {
      2 => (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5],
      3 => _u32be(body, pos + 4),
      _ => _synchsafe(body, pos + 4),
    };
    var start = pos + headLen;
    final end = start + frameSize;
    if (frameSize <= 0 || end > body.length) break;
    if (id.startsWith('T')) {
      var skip = false;
      Uint8List? data;
      if (major == 3) {
        final format = body[pos + 9];
        skip = (format & 0xC0) != 0; // compressed or encrypted
        if ((format & 0x20) != 0) start += 1; // group id
      } else if (major == 4) {
        final format = body[pos + 9];
        skip = (format & 0x0C) != 0; // compressed or encrypted
        if ((format & 0x40) != 0) start += 1; // group id
        if ((format & 0x01) != 0) start += 4; // data length indicator
        if (!skip && start <= end) {
          data = Uint8List.sublistView(body, start, end);
          if ((format & 0x02) != 0) data = _deunsync(data);
        }
      }
      if (!skip && start <= end) {
        data ??= Uint8List.sublistView(body, start, end);
        text[id] = _decodeText(data);
      }
    }
    pos = end;
  }
  final full = text['TDRC'];
  if (full != null) {
    final d = parseDateText(full);
    if (d != null) return d;
  }
  // ID3v2.3: year, "DDMM" and "HHMM" in separate frames (v2.2: TYE/TDA/TIM).
  final year = int.tryParse((text['TYER'] ?? text['TYE'] ?? '').trim());
  final ddmm = (text['TDAT'] ?? text['TDA'] ?? '').trim();
  final hhmm = (text['TIME'] ?? text['TIM'] ?? '').trim();
  if (year == null || !RegExp(r'^\d{4}$').hasMatch(ddmm)) return null;
  final hasTime = RegExp(r'^\d{4}$').hasMatch(hhmm);
  return parseDateText(
    '${year.toString().padLeft(4, '0')}-${ddmm.substring(2)}-${ddmm.substring(0, 2)}'
    '${hasTime ? ' ${hhmm.substring(0, 2)}:${hhmm.substring(2)}' : ''}',
  );
}

/// Where the MPEG frames of an MP3 are, between its tags.
class _Mp3Layout {
  const _Mp3Layout(
    this.start,
    this.end,
    this.recorded,
    this.appendedAt,
    this.v1,
  );

  /// First byte after a leading ID3v2 tag.
  final int start;

  /// First byte of the trailing tags (an appended ID3v2 tag, ID3v1).
  final int end;
  final DateTime? recorded;

  /// Where a new appended tag goes (before an ID3v1 tag).
  final int appendedAt;

  /// The ID3v1 tag at the very end, if any.
  final Uint8List? v1;
}

Future<_Mp3Layout> _mp3Layout(ByteAccess a) async {
  final length = await a.length();
  DateTime? recorded;
  var start = 0;
  final head = await a.read(0, 10);
  if (_isId3(head, 0, 'ID3')) {
    final size = _synchsafe(head, 6);
    start = math.min(length, 10 + size + ((head[5] & 0x10) != 0 ? 10 : 0));
    recorded = parseId3Date(await a.read(0, math.min(10 + size, _maxTagRead)));
  }
  var end = length;
  Uint8List? v1;
  if (length - start >= 128) {
    final t = await a.read(length - 128, 128);
    if (_ascii(t, 0, 3) == 'TAG') {
      v1 = t;
      end -= 128;
    }
  }
  final appendedAt = end;
  if (end - start >= 20) {
    final foot = await a.read(end - 10, 10);
    if (_isId3(foot, 0, '3DI')) {
      final size = _synchsafe(foot, 6);
      final tagStart = end - 20 - size;
      if (tagStart >= start) {
        final tag = await a.read(tagStart, math.min(10 + size, _maxTagRead));
        recorded ??= parseId3Date(tag);
        end = tagStart;
      }
    }
  }
  return _Mp3Layout(start, end, recorded, appendedAt, v1);
}

// Layer III bitrates (kbit/s) by MPEG-1 / MPEG-2 and 2.5 and bitrate index.
const _bitratesV1 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
];
const _bitratesV2 = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
];
const _sampleRates = {
  3: [44100, 48000, 32000], // MPEG-1
  2: [22050, 24000, 16000], // MPEG-2
  0: [11025, 12000, 8000], // MPEG-2.5
};

/// Playing time of the MPEG frames between [start] and [end].
Future<Duration?> _mp3Duration(ByteAccess a, int start, int end) async {
  if (end - start < 4) return null;
  // The first frame usually follows the tag directly; look further if not.
  for (final window in const [4096, 65536]) {
    final buf = await a.read(start, math.min(window, end - start));
    for (var i = 0; i + 4 <= buf.length; i++) {
      if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;
      final version = (buf[i + 1] >> 3) & 3; // 3 = 1, 2 = 2, 0 = 2.5
      final layer = (buf[i + 1] >> 1) & 3; // 1 = Layer III
      final bitrateIndex = buf[i + 2] >> 4;
      final rateIndex = (buf[i + 2] >> 2) & 3;
      if (version == 1 || layer != 1) continue;
      if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) continue;
      final sampleRate = _sampleRates[version]![rateIndex];
      final kbps = (version == 3 ? _bitratesV1 : _bitratesV2)[bitrateIndex];
      final samplesPerFrame = version == 3 ? 1152 : 576;
      final mono = (buf[i + 3] >> 6) == 3;
      // A Xing/Info header (VBR, or CBR from some encoders) counts frames.
      final side = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17);
      final x = i + 4 + side;
      if (x + 12 <= buf.length) {
        final tag = _ascii(buf, x, x + 4);
        if (tag == 'Xing' || tag == 'Info') {
          if ((_u32be(buf, x + 4) & 1) != 0) {
            final frames = _u32be(buf, x + 8);
            return Duration(
              microseconds: frames * samplesPerFrame * 1000000 ~/ sampleRate,
            );
          }
        }
      }
      // Constant bitrate: the size tells the time.
      final audioBytes = end - start - i;
      return Duration(microseconds: audioBytes * 8000 ~/ kbps);
    }
    if (buf.length < window) break; // searched everything there is
  }
  return null;
}

Future<AudioInfo> _mp3Info(ByteAccess a) async {
  final layout = await _mp3Layout(a);
  return AudioInfo(
    recorded: layout.recorded,
    duration: await _mp3Duration(a, layout.start, layout.end),
  );
}

Future<bool> _appendId3(ByteAccess a, DateTime recorded) async {
  final layout = await _mp3Layout(a);
  // Only real MP3s, and only once.
  if (layout.recorded != null) return true;
  if (await _mp3Duration(a, layout.start, layout.end) == null) return false;
  final v1 = layout.v1;
  // An appended tag goes before an ID3v1 tag, which stays last.
  await a.write(layout.appendedAt, [
    ...id3DateTag(recorded, footer: true),
    ...?v1,
  ]);
  return true;
}

// ======================================================================
// WAV: RIFF chunks
// ======================================================================

/// A LIST/INFO chunk holding the recording date ("ICRD").
Uint8List wavInfoChunk(DateTime recorded) {
  final t = recorded;
  final text = [
    ...'${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)} '
            '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
        .codeUnits,
    0,
  ];
  if (text.length.isOdd) text.add(0);
  final sub = [...'ICRD'.codeUnits, ..._le32(text.length), ...text];
  final list = [...'INFO'.codeUnits, ...sub];
  return Uint8List.fromList([
    ...'LIST'.codeUnits,
    ..._le32(list.length),
    ...list,
  ]);
}

List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

DateTime? _infoDate(Uint8List list) {
  if (_ascii(list, 0, 4) != 'INFO') return null;
  var pos = 4;
  while (pos + 8 <= list.length) {
    final id = _ascii(list, pos, pos + 4);
    final size = _u32le(list, pos + 4);
    final end = math.min(pos + 8 + size, list.length);
    if (id == 'ICRD') {
      return parseDateText(latin1.decode(list.sublist(pos + 8, end)));
    }
    pos += 8 + size + (size & 1);
  }
  return null;
}

class _WavLayout {
  const _WavLayout(this.recorded, this.duration, this.end);

  final DateTime? recorded;
  final Duration? duration;

  /// End of the last complete chunk (the file length for a sound file).
  final int? end;
}

Future<_WavLayout?> _wavLayout(ByteAccess a) async {
  final length = await a.length();
  final riff = await a.read(0, 12);
  if (riff.length < 12 ||
      _ascii(riff, 0, 4) != 'RIFF' ||
      _ascii(riff, 8, 12) != 'WAVE') {
    return null;
  }
  int? byteRate;
  Duration? duration;
  DateTime? recorded;
  int? end = 12;
  var pos = 12;
  for (var n = 0; n < 64 && pos + 8 <= length; n++) {
    final h = await a.read(pos, 8);
    if (h.length < 8) break;
    final id = _ascii(h, 0, 4);
    final size = _u32le(h, 4);
    final body = pos + 8;
    if (id == 'fmt ') {
      final f = await a.read(body, 16);
      if (f.length >= 12) byteRate = _u32le(f, 8);
    } else if (id == 'data') {
      if (byteRate != null && byteRate > 0) {
        // A cut-off file may claim more data than it has.
        final data = math.min(size, length - body);
        duration = Duration(microseconds: data * 1000000 ~/ byteRate);
      }
    } else if (id == 'LIST' && size >= 4 && size <= 65536) {
      recorded ??= _infoDate(await a.read(body, size));
    } else if (id == 'bext' && size >= 338) {
      // Broadcast WAV: OriginationDate and OriginationTime.
      final b = await a.read(body + 320, 18);
      recorded ??= parseDateText('${_ascii(b, 0, 10)} ${_ascii(b, 10, 18)}');
    }
    final next = body + size + (size & 1);
    if (body + size > length) {
      end = null; // runs past the end of the file
      break;
    }
    end = math.min(next, length);
    pos = next;
  }
  if (end != null && end < length) end = null; // unreadable bytes at the end
  return _WavLayout(recorded, duration, end);
}

Future<AudioInfo> _wavInfo(ByteAccess a) async {
  final l = await _wavLayout(a);
  return l == null
      ? AudioInfo.empty
      : AudioInfo(recorded: l.recorded, duration: l.duration);
}

Future<bool> _appendWavInfo(ByteAccess a, DateTime recorded) async {
  final l = await _wavLayout(a);
  if (l == null) return false;
  if (l.recorded != null) return true;
  // Appending is only safe when the chunks are intact up to the end.
  final end = l.end;
  if (end == null || l.duration == null) return false;
  final length = await a.length();
  final pad = length.isOdd ? const [0] : const <int>[];
  final chunk = wavInfoChunk(recorded);
  final total = length + pad.length + chunk.length;
  if (total - 8 > 0xFFFFFFFF) return false;
  await a.write(length, [...pad, ...chunk]);
  await a.write(4, _le32(total - 8));
  return true;
}

// ======================================================================
// M4A / MP4: boxes
// ======================================================================

/// Seconds between 1904-01-01 (the MP4 epoch) and 1970-01-01.
const _mp4EpochOffset = 2082844800;

typedef _Box = ({int body, int end});

Future<_Box?> _findBox(ByteAccess a, int from, int to, String type) async {
  var pos = from;
  for (var n = 0; n < 4096 && pos + 8 <= to; n++) {
    final h = await a.read(pos, 16);
    if (h.length < 8) return null;
    var size = _u32be(h, 0);
    final t = _ascii(h, 4, 8);
    var header = 8;
    if (size == 1) {
      if (h.length < 16) return null;
      size = _u64be(h, 8);
      header = 16;
    } else if (size == 0) {
      size = to - pos; // runs to the end
    }
    if (size < header || pos + size > to) return null; // damaged
    if (t == type) return (body: pos + header, end: pos + size);
    pos += size;
  }
  return null;
}

/// The movie header ("mvhd") inside the index ("moov").
Future<_Box?> _mvhd(ByteAccess a) async {
  final length = await a.length();
  final moov = await _findBox(a, 0, length, 'moov');
  if (moov == null) return null;
  return _findBox(a, moov.body, moov.end, 'mvhd');
}

Future<AudioInfo> _mp4Info(ByteAccess a) async {
  final mvhd = await _mvhd(a);
  if (mvhd == null) return AudioInfo.empty;
  final b = await a.read(mvhd.body, 32);
  final v1 = b[0] == 1;
  if (b.length < (v1 ? 32 : 20)) return AudioInfo.empty;
  final created = v1 ? _u64be(b, 4) : _u32be(b, 4);
  final timescale = v1 ? _u32be(b, 20) : _u32be(b, 12);
  final length = v1 ? _u64be(b, 24) : _u32be(b, 16);
  DateTime? recorded;
  if (created > _mp4EpochOffset) {
    final t = DateTime.fromMillisecondsSinceEpoch(
      (created - _mp4EpochOffset) * 1000,
    );
    if (_plausible(t)) recorded = t;
  }
  final unknown = v1 ? length == -1 : length == 0xFFFFFFFF;
  return AudioInfo(
    recorded: recorded,
    duration: timescale == 0 || unknown || length <= 0
        ? null
        : Duration(microseconds: length * 1000000 ~/ timescale),
  );
}

Future<bool> _setMp4Created(ByteAccess a, DateTime recorded) async {
  final mvhd = await _mvhd(a);
  if (mvhd == null) return false;
  final b = await a.read(mvhd.body, 12);
  if (b.length < 12) return false;
  final seconds = recorded.millisecondsSinceEpoch ~/ 1000 + _mp4EpochOffset;
  if (b[0] == 1) {
    final v = ByteData(8)..setUint64(0, seconds);
    await a.write(mvhd.body + 4, v.buffer.asUint8List());
  } else {
    if (seconds > 0xFFFFFFFF) return false;
    final v = ByteData(4)..setUint32(0, seconds);
    await a.write(mvhd.body + 4, v.buffer.asUint8List());
  }
  return true;
}
