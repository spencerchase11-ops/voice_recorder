/// Streaming MP3 encoding for Flutter on Android and iOS, backed by the LAME
/// 4.0 encoder (vendored in `src/lame`) through `dart:ffi`.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'lame_mp3_bindings_generated.dart';
import 'src/native_library.dart';

/// Encodes 16-bit PCM audio into a constant-bitrate MP3 stream.
///
/// ```dart
/// final encoder = LameMp3Encoder(sampleRate: 44100, bitrateKbps: 128);
/// try {
///   await for (final Int16List chunk in pcmChunks) {
///     sink.add(encoder.encode(chunk));
///   }
///   sink.add(encoder.flush());
/// } finally {
///   encoder.close();
/// }
/// ```
///
/// The concatenation of everything returned by [encode] and [flush] is a
/// complete MP3 file: MPEG Layer III frames only, without ID3 tags or a
/// Xing/Info header frame, so it can be written out while it is produced.
/// The stream starts with LAME's fixed encoder delay of 576 samples of
/// silence, and the last frame is padded with silence.
///
/// Encoding runs synchronously on the calling isolate. Each encoder owns
/// about 400 KB of native memory; call [close] when done (a finalizer frees
/// it otherwise, but only once the encoder has been garbage collected).
class LameMp3Encoder implements Finalizable {
  /// Creates an encoder for PCM at [sampleRate] Hz with [channels] channels
  /// (1 = mono, 2 = joint stereo with interleaved input), producing a CBR
  /// stream of [bitrateKbps] kbit/s. [quality] is LAME's algorithm quality,
  /// from 0 (best, slowest) to 9 (fastest); 5 is a good default for speech.
  ///
  /// The encoder never resamples: [sampleRate] must be one of
  /// [supportedSampleRates], and [bitrateKbps] one of
  /// [supportedBitrates] for that rate. Throws an [ArgumentError] for invalid
  /// arguments and a [StateError] if LAME cannot be initialised.
  LameMp3Encoder({
    required this.sampleRate,
    this.channels = 1,
    required this.bitrateKbps,
    this.quality = 5,
  }) : _handle = _createHandle(sampleRate, channels, bitrateKbps, quality) {
    _handleFinalizer.attach(
      this,
      _handle,
      detach: this,
      externalSize: _nativeEncoderSize,
    );
  }

  /// The sample rates that MPEG Layer III supports, in Hz.
  static const List<int> supportedSampleRates = <int>[
    8000, 11025, 12000, // MPEG-2.5
    16000, 22050, 24000, // MPEG-2
    32000, 44100, 48000, // MPEG-1
  ];

  /// The constant bitrates (kbit/s) that LAME can encode at [sampleRate]:
  /// 32 to 320 for MPEG-1 (32, 44.1 and 48 kHz), 8 to 160 for MPEG-2
  /// (16, 22.05 and 24 kHz) and 8 to 64 for MPEG-2.5 (8, 11.025 and 12 kHz).
  ///
  /// Throws an [ArgumentError] if [sampleRate] is not supported.
  static List<int> supportedBitrates(int sampleRate) {
    if (!supportedSampleRates.contains(sampleRate)) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Unsupported sample rate; use one of '
            '${supportedSampleRates.join(', ')} Hz',
      );
    }
    if (sampleRate >= 32000) {
      return _mpeg1Bitrates;
    }
    return sampleRate >= 16000 ? _mpeg2Bitrates : _mpeg25Bitrates;
  }

  /// The version of the LAME library, e.g. `4.0`.
  static String get lameVersion =>
      _bindings.lame_mp3_version().cast<Utf8>().toDartString();

  /// Sample rate of the PCM input and of the MP3 stream, in Hz.
  final int sampleRate;

  /// Number of input channels: 1 (mono) or 2 (stereo, interleaved).
  final int channels;

  /// Bitrate of the MP3 stream, in kbit/s.
  final int bitrateKbps;

  /// LAME's algorithm quality: 0 (best, slowest) to 9 (fastest).
  final int quality;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Encodes [samples] and returns the MP3 data that became available.
  ///
  /// For stereo encoders [samples] must hold interleaved left/right pairs.
  /// LAME buffers about one and a half MP3 frames internally, so the result
  /// may be empty; the remaining data is returned by [flush].
  ///
  /// Throws a [StateError] after [flush] or [close], and an [ArgumentError]
  /// if a stereo input does not have an even length.
  Uint8List encode(Int16List samples) {
    _checkOpen('encode');
    if (_flushed) {
      throw StateError(
        'encode() called after flush(); use a new LameMp3Encoder for a new '
        'stream.',
      );
    }
    if (samples.length % channels != 0) {
      throw ArgumentError.value(
        samples.length,
        'samples.length',
        'Stereo input must contain interleaved left/right pairs',
      );
    }
    final int samplesPerChannel = samples.length ~/ channels;
    if (samplesPerChannel == 0) {
      return Uint8List(0);
    }

    _ensureScratch(math.min(samplesPerChannel, _maxSamplesPerCall));
    final Pointer<Int16> pcm = _scratch.cast<Int16>();
    final Int16List pcmView = pcm.asTypedList(_scratchSamples * channels);
    final List<Uint8List> chunks = <Uint8List>[];
    // At most _maxSamplesPerCall samples per channel per native call.
    int start = 0;
    while (start < samplesPerChannel) {
      final int count = math.min(samplesPerChannel - start, _maxSamplesPerCall);
      pcmView.setRange(0, count * channels, samples, start * channels);
      final int written = _bindings.lame_mp3_encode(
        _handle,
        pcm,
        count,
        _output,
        _outputCapacity,
      );
      _checkResult(written, 'lame_mp3_encode');
      if (written > 0) {
        chunks.add(_copyOutput(written));
      }
      start += count;
    }
    return _concatenate(chunks);
  }

  /// Encodes the buffered samples and returns the last MP3 frames.
  ///
  /// Call it once, after the last [encode]. Throws a [StateError] if it was
  /// already called or the encoder is closed.
  Uint8List flush() {
    _checkOpen('flush');
    if (_flushed) {
      throw StateError('flush() was already called on this encoder.');
    }
    _flushed = true;
    _ensureScratch(0);
    final int written = _bindings.lame_mp3_flush(
      _handle,
      _output,
      _outputCapacity,
    );
    _checkResult(written, 'lame_mp3_flush');
    return _copyOutput(written);
  }

  /// Releases the native encoder and buffers. Calling it again has no effect.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _handleFinalizer.detach(this);
    _bindings.lame_mp3_close(_handle);
    _freeScratch();
  }

  static const List<int> _mpeg1Bitrates = <int>[
    32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, // MPEG-1
  ];
  static const List<int> _mpeg2Bitrates = <int>[
    8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, // MPEG-2
  ];
  // MPEG-2.5 shares MPEG-2's bitrate table, but LAME stops at 64 kbit/s.
  static const List<int> _mpeg25Bitrates = <int>[
    8, 16, 24, 32, 40, 48, 56, 64, // MPEG-2.5
  ];

  /// Upper bound of samples per channel handed to LAME in one native call,
  /// which bounds the native buffers (~350 KB for stereo) for any input size.
  static const int _maxSamplesPerCall = 1 << 16;
  static const int _minScratchSamples = 1024;

  /// Approximate native memory of one LAME encoder, reported to the GC.
  static const int _nativeEncoderSize = 400 * 1024;

  static final NativeFinalizer _handleFinalizer = NativeFinalizer(
    _bindings.addresses.lame_mp3_close,
  );
  static final NativeFinalizer _scratchFinalizer = NativeFinalizer(
    malloc.nativeFree,
  );

  final Pointer<Void> _handle;
  bool _flushed = false;
  bool _closed = false;

  /// One native block: PCM input for [_scratchSamples] samples per channel,
  /// followed by the MP3 output buffer of [_outputCapacity] bytes.
  Pointer<Uint8> _scratch = nullptr;
  int _scratchSamples = 0;

  int get _pcmBytes => _scratchSamples * channels * sizeOf<Int16>();

  Pointer<Uint8> get _output => _scratch + _pcmBytes;

  /// LAME's worst case for n samples per channel: 1.25 * n + 7200 bytes
  /// (7200 bytes also covers lame_encode_flush).
  int get _outputCapacity =>
      _scratchSamples + (_scratchSamples + 3) ~/ 4 + LAME_MP3_FLUSH_BUFFER_SIZE;

  static Pointer<Void> _createHandle(
    int sampleRate,
    int channels,
    int bitrateKbps,
    int quality,
  ) {
    final List<int> bitrates = supportedBitrates(sampleRate);
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(
        channels,
        'channels',
        'Must be 1 (mono) or 2 (stereo)',
      );
    }
    if (!bitrates.contains(bitrateKbps)) {
      throw ArgumentError.value(
        bitrateKbps,
        'bitrateKbps',
        'Not an MP3 bitrate at $sampleRate Hz; use one of '
            '${bitrates.join(', ')} kbit/s',
      );
    }
    RangeError.checkValueInInterval(quality, 0, 9, 'quality');

    final Pointer<Void> handle = _bindings.lame_mp3_create(
      sampleRate,
      channels,
      bitrateKbps,
      quality,
    );
    if (handle == nullptr) {
      throw StateError(
        'LAME could not create an encoder for $sampleRate Hz, $channels '
        'channel(s), $bitrateKbps kbit/s, quality $quality.',
      );
    }
    return handle;
  }

  void _checkOpen(String method) {
    if (_closed) {
      throw StateError('$method() called on a closed LameMp3Encoder.');
    }
  }

  static void _checkResult(int result, String function) {
    if (result >= 0) {
      return;
    }
    final String reason = switch (result) {
      LAME_MP3_ERROR_BUFFER_TOO_SMALL => 'output buffer too small',
      LAME_MP3_ERROR_OUT_OF_MEMORY => 'out of memory',
      LAME_MP3_ERROR_NOT_INITIALIZED => 'encoder not initialised',
      LAME_MP3_ERROR_PSYCHOACOUSTIC => 'psychoacoustic model error',
      LAME_MP3_ERROR_INVALID_ARGUMENT => 'invalid argument',
      _ => 'unknown error',
    };
    throw StateError('$function failed with code $result ($reason).');
  }

  /// Makes room for [samplesPerChannel] input samples per channel (and the
  /// matching output buffer), growing the native block in powers of two.
  void _ensureScratch(int samplesPerChannel) {
    if (_scratch != nullptr && samplesPerChannel <= _scratchSamples) {
      return;
    }
    int capacity = math.max(_scratchSamples, _minScratchSamples);
    while (capacity < samplesPerChannel) {
      capacity *= 2;
    }
    _freeScratch();
    _scratchSamples = capacity;
    final int bytes = _pcmBytes + _outputCapacity;
    _scratch = malloc<Uint8>(bytes);
    _scratchFinalizer.attach(
      this,
      _scratch.cast(),
      detach: this,
      externalSize: bytes,
    );
  }

  void _freeScratch() {
    if (_scratch == nullptr) {
      return;
    }
    _scratchFinalizer.detach(this);
    malloc.free(_scratch);
    _scratch = nullptr;
  }

  Uint8List _copyOutput(int length) =>
      Uint8List(length)..setRange(0, length, _output.asTypedList(length));

  static Uint8List _concatenate(List<Uint8List> chunks) {
    if (chunks.isEmpty) {
      return Uint8List(0);
    }
    if (chunks.length == 1) {
      return chunks.single;
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    chunks.forEach(builder.add);
    return builder.takeBytes();
  }
}

final LameMp3Bindings _bindings = LameMp3Bindings(openLameMp3Library());
