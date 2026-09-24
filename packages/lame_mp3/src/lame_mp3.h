// Minimal C API over the vendored LAME MP3 encoder (src/lame), bound from
// Dart with dart:ffi (lib/lame_mp3_bindings_generated.dart). Dart never binds
// lame.h directly; only the functions declared here are exported from the
// shared library (everything from LAME is compiled with hidden visibility).
//
// Typical use:
//   void* h = lame_mp3_create(44100, 1, 128, 5);
//   while (more input) n = lame_mp3_encode(h, pcm, samples, out, cap);
//   n = lame_mp3_flush(h, out, cap);
//   lame_mp3_close(h);
//
// The concatenated output of all encode/flush calls is a plain CBR MPEG
// Layer III stream (no ID3 tags, no Xing/Info/LAME header frame), so it can be
// streamed to a file or socket without seeking back.
//
// A handle must not be used by more than one thread at a time; different
// handles are independent.

#ifndef LAME_MP3_H_
#define LAME_MP3_H_

#include <stdint.h>

#if defined(_WIN32)
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Output buffer sizing (bytes). These are LAME's documented worst cases.
//
// lame_mp3_encode: out_capacity >= 1.25 * samples_per_channel + 7200,
//   i.e. LAME_MP3_ENCODE_BUFFER_SIZE(samples_per_channel).
// lame_mp3_flush:  out_capacity >= LAME_MP3_FLUSH_BUFFER_SIZE.
#define LAME_MP3_FLUSH_BUFFER_SIZE 7200
#define LAME_MP3_ENCODE_BUFFER_SIZE(samples_per_channel) \
  ((samples_per_channel) + ((samples_per_channel) + 3) / 4 + LAME_MP3_FLUSH_BUFFER_SIZE)

// Negative return values of lame_mp3_encode / lame_mp3_flush. -1 .. -4 are
// passed through unchanged from LAME's lame_encode_buffer*/lame_encode_flush.
#define LAME_MP3_ERROR_BUFFER_TOO_SMALL (-1)   // out_capacity too small
#define LAME_MP3_ERROR_OUT_OF_MEMORY (-2)      // malloc() failed inside LAME
#define LAME_MP3_ERROR_NOT_INITIALIZED (-3)    // handle is not a live encoder
#define LAME_MP3_ERROR_PSYCHOACOUSTIC (-4)     // psycho-acoustic model failure
#define LAME_MP3_ERROR_INVALID_ARGUMENT (-100) // NULL pointer / negative count

// Creates a constant-bitrate encoder. Input and output sample rates are both
// `sample_rate` (LAME never resamples), which must be one of the MPEG rates:
//   MPEG-1:   32000, 44100, 48000 Hz  (1152 samples per frame)
//   MPEG-2:   16000, 22050, 24000 Hz  (576 samples per frame)
//   MPEG-2.5:  8000, 11025, 12000 Hz  (576 samples per frame)
// `channels` is 1 (mono) or 2 (joint stereo, interleaved input).
// `bitrate_kbps` must be a Layer III bitrate that LAME supports at that rate:
//   MPEG-1:   32 40 48 56 64 80 96 112 128 160 192 224 256 320
//   MPEG-2:    8 16 24 32 40 48 56 64 80 96 112 128 144 160
//   MPEG-2.5:  8 16 24 32 40 48 56 64
// (LAME would silently pick the nearest supported bitrate; this wrapper
// fails instead.) `quality` is LAME's algorithm quality, 0 (best, slowest) to 9
// (worst, fastest); 5 is a good default for speech.
// Returns an opaque handle, or NULL if any argument is invalid, allocation
// fails or LAME rejects the configuration. Release it with lame_mp3_close().
FFI_PLUGIN_EXPORT void* lame_mp3_create(int32_t sample_rate, int32_t channels,
                                        int32_t bitrate_kbps, int32_t quality);

// Encodes `samples_per_channel` 16-bit PCM samples per channel. For stereo
// encoders `pcm` holds 2 * samples_per_channel interleaved samples (L R L R
// ...); for mono encoders it holds samples_per_channel samples.
// Writes the MP3 bytes that became available to `out` (LAME buffers about
// one and a half frames internally, so this may be 0) and returns their
// count, or a negative LAME_MP3_ERROR_* code.
// `out_capacity` must be at least LAME_MP3_ENCODE_BUFFER_SIZE(samples).
// With samples_per_channel == 0 nothing is read or written and 0 is returned.
FFI_PLUGIN_EXPORT int32_t lame_mp3_encode(void* handle, const int16_t* pcm,
                                          int32_t samples_per_channel,
                                          uint8_t* out, int32_t out_capacity);

// Encodes the buffered samples (zero-padding the last frame) and writes the
// final frames to `out`; call it once, after the last lame_mp3_encode().
// Returns the number of bytes written or a negative LAME_MP3_ERROR_* code.
// `out_capacity` must be at least LAME_MP3_FLUSH_BUFFER_SIZE.
FFI_PLUGIN_EXPORT int32_t lame_mp3_flush(void* handle, uint8_t* out,
                                         int32_t out_capacity);

// Frees the encoder. NULL is ignored; the handle must not be used afterwards.
FFI_PLUGIN_EXPORT void lame_mp3_close(void* handle);

// LAME's version string, e.g. "4.0" (static storage, never NULL).
FFI_PLUGIN_EXPORT const char* lame_mp3_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // LAME_MP3_H_
