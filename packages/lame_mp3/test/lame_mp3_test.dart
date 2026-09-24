// Host tests: run against a build of src/ for the development machine.
//
//   tool/build_host_lib.sh && flutter test
//
// or point LAME_MP3_LIBRARY at any host build of the library. Without one,
// the tests are skipped.

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lame_mp3/lame_mp3.dart';
import 'package:lame_mp3/lame_mp3_bindings_generated.dart';
import 'package:lame_mp3/src/native_library.dart';

import 'support/mp3_frames.dart';

/// LAME's fixed encoder delay (lame_get_encoder_delay()): the stream starts
/// with this many samples of silence before the first input sample.
const int lameEncoderDelay = 576;

/// The host build of the native library, or why the tests are skipped.
final ({String? path, String? skipReason}) hostLibrary = _findHostLibrary();
String? get libraryPath => hostLibrary.path;
String? get skipReason => hostLibrary.skipReason;

({String? path, String? skipReason}) _findHostLibrary() {
  const String variable = lameMp3LibraryEnvironmentVariable;
  final String? fromEnvironment = Platform.environment[variable];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    final File file = File(fromEnvironment);
    return file.existsSync()
        ? (path: file.absolute.path, skipReason: null)
        : (path: null, skipReason: '$variable=$fromEnvironment does not exist');
  }
  for (final String candidate in <String>[
    'build/host/liblame_mp3.so',
    'build/host/liblame_mp3.dylib',
  ]) {
    final File file = File(candidate);
    if (file.existsSync()) {
      return (path: file.absolute.path, skipReason: null);
    }
  }
  return (
    path: null,
    skipReason:
        'Native library not found: run tool/build_host_lib.sh first, or set '
        '$variable to a host build of liblame_mp3',
  );
}

/// [seconds] of a sine at [amplitude] of full scale; channel c uses
/// [frequencies][c]. Stereo output is interleaved.
Int16List sine({
  required int sampleRate,
  required double seconds,
  int channels = 1,
  List<double> frequencies = const <double>[440, 660],
  double amplitude = 0.5,
}) {
  final int length = (sampleRate * seconds).round();
  final Int16List pcm = Int16List(length * channels);
  for (int i = 0; i < length; i++) {
    for (int c = 0; c < channels; c++) {
      pcm[i * channels + c] =
          (amplitude *
                  32767 *
                  math.sin(2 * math.pi * frequencies[c] * i / sampleRate))
              .round();
    }
  }
  return pcm;
}

/// Feeds [pcm] to [encoder] in chunks of the given sizes (samples per
/// channel, used cyclically), then flushes it.
Uint8List encodeChunked(
  LameMp3Encoder encoder,
  Int16List pcm,
  List<int> chunkSizes,
) {
  final BytesBuilder mp3 = BytesBuilder();
  int start = 0;
  for (int i = 0; start < pcm.length; i++) {
    final int size = chunkSizes[i % chunkSizes.length] * encoder.channels;
    final int end = math.min(start + size, pcm.length);
    mp3.add(encoder.encode(Int16List.sublistView(pcm, start, end)));
    start = end;
  }
  mp3.add(encoder.flush());
  return mp3.takeBytes();
}

/// Checks that [mp3] consists of complete CBR frames with the given format
/// and that it holds [inputSamples] samples per channel: LAME adds its
/// encoder delay in front and pads the end to whole frames, i.e. less than
/// two extra frames once the delay is accounted for.
List<Mp3FrameHeader> expectCbrStream(
  Uint8List mp3, {
  required int version,
  required int sampleRate,
  required int bitrateKbps,
  required int channelMode,
  required int inputSamples,
}) {
  final List<Mp3FrameHeader> frames = parseLayer3Stream(mp3);
  expect(frames, isNotEmpty);
  for (final Mp3FrameHeader frame in frames) {
    final String reason = 'frame at byte ${frame.offset}: $frame';
    expect(frame.version, version, reason: reason);
    expect(frame.layer, 3, reason: reason);
    expect(frame.bitrateKbps, bitrateKbps, reason: reason);
    expect(frame.sampleRate, sampleRate, reason: reason);
    expect(frame.channelMode, channelMode, reason: reason);
    expect(frame.hasCrc, isFalse, reason: reason);
  }
  // No Xing/Info header frame (lame_set_bWriteVbrTag(0)); a stray ID3 tag
  // would already have failed the frame sync check.
  final String firstFrame = String.fromCharCodes(
    mp3.sublist(0, frames.first.frameLength),
  );
  expect(firstFrame, isNot(contains('Xing')));
  expect(firstFrame, isNot(contains('Info')));

  final int samplesPerFrame = frames.first.samplesPerFrame;
  final double inputSeconds = inputSamples / sampleRate;
  final double streamSeconds = frames.length * samplesPerFrame / sampleRate;
  expect(
    streamSeconds - lameEncoderDelay / sampleRate,
    closeTo(inputSeconds, 2 * samplesPerFrame / sampleRate),
    reason: '${frames.length} frames of $samplesPerFrame samples',
  );
  expect(
    frames.length * samplesPerFrame,
    greaterThanOrEqualTo(inputSamples + lameEncoderDelay),
  );
  return frames;
}

void main() {
  if (libraryPath != null) {
    lameMp3LibraryPathOverride = libraryPath;
  }

  group('LameMp3Encoder', skip: skipReason, () {
    test('reports LAME 4.x', () {
      expect(LameMp3Encoder.lameVersion, startsWith('4.'));
    });

    for (final (int sampleRate, int bitrate, int version, int frameSize)
        in <(int, int, int, int)>[
          (44100, 128, 1, 1152),
          (22050, 64, 2, 576),
          (16000, 32, 2, 576),
        ]) {
      test('3 s of 440 Hz mono at $sampleRate Hz, $bitrate kbps, '
          'in 1024-sample chunks', () {
        final LameMp3Encoder encoder = LameMp3Encoder(
          sampleRate: sampleRate,
          bitrateKbps: bitrate,
        );
        addTearDown(encoder.close);
        final Int16List pcm = sine(sampleRate: sampleRate, seconds: 3);

        final Uint8List mp3 = encodeChunked(encoder, pcm, <int>[1024]);

        final List<Mp3FrameHeader> frames = expectCbrStream(
          mp3,
          version: version,
          sampleRate: sampleRate,
          bitrateKbps: bitrate,
          channelMode: Mp3FrameHeader.mono,
          inputSamples: pcm.length,
        );
        expect(frames.first.samplesPerFrame, frameSize);
      });
    }

    test('encodes interleaved stereo as joint stereo', () {
      final LameMp3Encoder encoder = LameMp3Encoder(
        sampleRate: 44100,
        channels: 2,
        bitrateKbps: 128,
      );
      addTearDown(encoder.close);
      final Int16List pcm = sine(sampleRate: 44100, seconds: 3, channels: 2);

      final Uint8List mp3 = encodeChunked(encoder, pcm, <int>[1024]);

      expectCbrStream(
        mp3,
        version: 1,
        sampleRate: 44100,
        bitrateKbps: 128,
        channelMode: Mp3FrameHeader.jointStereo,
        inputSamples: pcm.length ~/ 2,
      );
    });

    test('output does not depend on how the input is chunked', () {
      // 5 s of stereo: more than one native call's worth (65536 samples).
      final Int16List pcm = sine(sampleRate: 48000, seconds: 5, channels: 2);
      Uint8List encodeWith(List<int> chunkSizes) {
        final LameMp3Encoder encoder = LameMp3Encoder(
          sampleRate: 48000,
          channels: 2,
          bitrateKbps: 192,
        );
        try {
          return encodeChunked(encoder, pcm, chunkSizes);
        } finally {
          encoder.close();
        }
      }

      final Uint8List oneCall = encodeWith(<int>[pcm.length]);
      expect(encodeWith(<int>[1024]), equals(oneCall));
      expect(encodeWith(<int>[1, 7, 333, 4096, 70000, 1152]), equals(oneCall));
      expectCbrStream(
        oneCall,
        version: 1,
        sampleRate: 48000,
        bitrateKbps: 192,
        channelMode: Mp3FrameHeader.jointStereo,
        inputSamples: pcm.length ~/ 2,
      );
    });

    test('encode() may return nothing until a frame is complete', () {
      final LameMp3Encoder encoder = LameMp3Encoder(
        sampleRate: 44100,
        bitrateKbps: 128,
      );
      addTearDown(encoder.close);
      expect(encoder.encode(Int16List(0)), isEmpty);
      expect(encoder.encode(Int16List(1024)), isEmpty);
      // Without further input, flush() still yields a valid stream.
      expectCbrStream(
        encoder.flush(),
        version: 1,
        sampleRate: 44100,
        bitrateKbps: 128,
        channelMode: Mp3FrameHeader.mono,
        inputSamples: 1024,
      );
    });

    test('accepts every legal sample rate / bitrate / channel combination', () {
      for (final int sampleRate in LameMp3Encoder.supportedSampleRates) {
        final int version = sampleRate >= 32000
            ? 1
            : sampleRate >= 16000
            ? 2
            : 25;
        for (final int bitrate in LameMp3Encoder.supportedBitrates(
          sampleRate,
        )) {
          for (final int channels in <int>[1, 2]) {
            final LameMp3Encoder encoder = LameMp3Encoder(
              sampleRate: sampleRate,
              channels: channels,
              bitrateKbps: bitrate,
            );
            try {
              final Int16List pcm = sine(
                sampleRate: sampleRate,
                seconds: 0.25,
                channels: channels,
              );
              expectCbrStream(
                encodeChunked(encoder, pcm, <int>[4096]),
                version: version,
                sampleRate: sampleRate,
                bitrateKbps: bitrate,
                channelMode: channels == 1
                    ? Mp3FrameHeader.mono
                    : Mp3FrameHeader.jointStereo,
                inputSamples: pcm.length ~/ channels,
              );
            } finally {
              encoder.close();
            }
          }
        }
      }
    });

    test('rejects invalid configurations with ArgumentError', () {
      void expectInvalid(
        int sampleRate,
        int bitrateKbps, {
        int channels = 1,
        int quality = 5,
      }) {
        expect(
          () => LameMp3Encoder(
            sampleRate: sampleRate,
            channels: channels,
            bitrateKbps: bitrateKbps,
            quality: quality,
          ),
          throwsArgumentError,
          reason: '$sampleRate Hz, $bitrateKbps kbps, $channels ch, q$quality',
        );
      }

      expectInvalid(44000, 128); // not an MPEG sample rate
      expectInvalid(96000, 128);
      expectInvalid(0, 128);
      expectInvalid(44100, 8); // MPEG-2 only
      expectInvalid(22050, 192); // MPEG-1 only
      expectInvalid(8000, 80); // LAME's MPEG-2.5 maximum is 64 kbps
      expectInvalid(44100, 100); // LAME would silently round it
      expectInvalid(44100, 0);
      expectInvalid(44100, 128, channels: 0);
      expectInvalid(44100, 128, channels: 3);
      expectInvalid(44100, 128, quality: -1);
      expectInvalid(44100, 128, quality: 10);
      expect(
        () => LameMp3Encoder.supportedBitrates(44000),
        throwsArgumentError,
      );
    });

    test('rejects stereo input with an odd number of samples', () {
      final LameMp3Encoder encoder = LameMp3Encoder(
        sampleRate: 44100,
        channels: 2,
        bitrateKbps: 128,
      );
      addTearDown(encoder.close);
      expect(() => encoder.encode(Int16List(1025)), throwsArgumentError);
      // The encoder is still usable afterwards.
      encoder.encode(Int16List(2048));
      expect(parseLayer3Stream(encoder.flush()), isNotEmpty);
    });

    test('throws StateError when used after flush() or close()', () {
      final LameMp3Encoder encoder = LameMp3Encoder(
        sampleRate: 16000,
        bitrateKbps: 32,
      );
      encoder.encode(Int16List(1600));
      encoder.flush();
      expect(() => encoder.encode(Int16List(1600)), throwsStateError);
      expect(encoder.flush, throwsStateError);

      expect(encoder.isClosed, isFalse);
      encoder.close();
      expect(encoder.isClosed, isTrue);
      encoder.close(); // idempotent
      expect(() => encoder.encode(Int16List(1600)), throwsStateError);
      expect(encoder.flush, throwsStateError);
    });
  });

  group('C API', skip: skipReason, () {
    late LameMp3Bindings lame;
    setUpAll(() {
      lame = LameMp3Bindings(DynamicLibrary.open(libraryPath!));
    });

    test('lame_mp3_create returns NULL instead of adjusting the request', () {
      expect(lame.lame_mp3_create(44100, 1, 100, 5), nullptr); // -> 96/112
      expect(lame.lame_mp3_create(22050, 1, 320, 5), nullptr); // -> 160
      expect(lame.lame_mp3_create(11025, 1, 80, 5), nullptr); // -> 64
      expect(lame.lame_mp3_create(44000, 1, 128, 5), nullptr);
      expect(lame.lame_mp3_create(44100, 3, 128, 5), nullptr);
      expect(lame.lame_mp3_create(44100, 1, 128, 10), nullptr);
      final Pointer<Void> handle = lame.lame_mp3_create(44100, 1, 128, 5);
      expect(handle, isNot(nullptr));
      lame.lame_mp3_close(handle);
      lame.lame_mp3_close(nullptr); // ignored
    });

    test('encode/flush validate their arguments', () {
      final Pointer<Void> handle = lame.lame_mp3_create(44100, 1, 128, 5);
      final Pointer<Int16> pcm = calloc<Int16>(4096);
      final Pointer<Uint8> out = malloc<Uint8>(16384);
      try {
        expect(
          lame.lame_mp3_encode(nullptr, pcm, 1152, out, 16384),
          LAME_MP3_ERROR_INVALID_ARGUMENT,
        );
        expect(
          lame.lame_mp3_encode(handle, nullptr, 1152, out, 16384),
          LAME_MP3_ERROR_INVALID_ARGUMENT,
        );
        expect(
          lame.lame_mp3_encode(handle, pcm, -1, out, 16384),
          LAME_MP3_ERROR_INVALID_ARGUMENT,
        );
        expect(lame.lame_mp3_encode(handle, pcm, 0, nullptr, 0), 0);
        // A capacity of 0 means "unchecked" to LAME itself.
        expect(
          lame.lame_mp3_encode(handle, pcm, 4096, out, 0),
          LAME_MP3_ERROR_BUFFER_TOO_SMALL,
        );
        expect(
          lame.lame_mp3_flush(handle, out, 0),
          LAME_MP3_ERROR_BUFFER_TOO_SMALL,
        );
        expect(
          lame.lame_mp3_flush(nullptr, out, 16384),
          LAME_MP3_ERROR_INVALID_ARGUMENT,
        );
        expect(lame.lame_mp3_version().cast<Utf8>().toDartString(), '4.0');
      } finally {
        lame.lame_mp3_close(handle);
        calloc.free(pcm);
        malloc.free(out);
      }
    });

    test('reports a too small output buffer without overrunning it', () {
      final Pointer<Void> handle = lame.lame_mp3_create(44100, 1, 320, 5);
      const int samples = 44100;
      const int capacity = 64;
      final Pointer<Int16> pcm = calloc<Int16>(samples);
      final Pointer<Uint8> out = malloc<Uint8>(capacity + 64);
      try {
        final Int16List input = pcm.asTypedList(samples);
        input.setAll(0, sine(sampleRate: 44100, seconds: 1));
        final Uint8List guard = out.asTypedList(capacity + 64);
        guard.fillRange(capacity, capacity + 64, 0xA5);

        expect(
          lame.lame_mp3_encode(handle, pcm, samples, out, capacity),
          LAME_MP3_ERROR_BUFFER_TOO_SMALL,
        );
        expect(guard.sublist(capacity), everyElement(0xA5));
      } finally {
        lame.lame_mp3_close(handle);
        calloc.free(pcm);
        malloc.free(out);
      }
    });
  });
}
