// Thin wrapper around LAME's encoder API; see lame_mp3.h for the contract.

#include "lame_mp3.h"

#include <stddef.h>

#include "lame.h"

// LAME takes `short` samples and `unsigned char` output; the Dart bindings use
// the fixed-width types, so make sure they are the same thing.
_Static_assert(sizeof(short) == sizeof(int16_t), "short must be 16 bits");
_Static_assert(sizeof(unsigned char) == sizeof(uint8_t), "char must be 8 bits");

static int is_supported_quality(int32_t quality) {
  return quality >= 0 && quality <= 9;
}

void* lame_mp3_create(int32_t sample_rate, int32_t channels,
                      int32_t bitrate_kbps, int32_t quality) {
  if (sample_rate <= 0 || (channels != 1 && channels != 2) ||
      bitrate_kbps <= 0 || !is_supported_quality(quality)) {
    return NULL;
  }

  lame_t lame = lame_init();
  if (lame == NULL) {
    return NULL;
  }

  int status = 0;
  // A library must not print to stderr: drop LAME's diagnostics.
  status |= lame_set_errorf(lame, NULL);
  status |= lame_set_debugf(lame, NULL);
  status |= lame_set_msgf(lame, NULL);

  status |= lame_set_num_channels(lame, channels);
  status |= lame_set_in_samplerate(lame, sample_rate);
  status |= lame_set_out_samplerate(lame, sample_rate);  // never resample
  status |= lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO);
  status |= lame_set_VBR(lame, vbr_off);                  // CBR
  status |= lame_set_brate(lame, bitrate_kbps);
  status |= lame_set_quality(lame, quality);
  // No Xing/Info/LAME frame: it is a placeholder that would have to be
  // rewritten at the start of the file once encoding is finished.
  status |= lame_set_bWriteVbrTag(lame, 0);
  lame_set_write_id3tag_automatic(lame, 0);

  if (status != 0 || lame_init_params(lame) < 0 ||
      // LAME maps an illegal bitrate to the nearest legal one; refuse instead
      // so that the caller gets exactly what it asked for.
      lame_get_brate(lame) != bitrate_kbps ||
      lame_get_out_samplerate(lame) != sample_rate) {
    lame_close(lame);
    return NULL;
  }
  return lame;
}

int32_t lame_mp3_encode(void* handle, const int16_t* pcm,
                        int32_t samples_per_channel, uint8_t* out,
                        int32_t out_capacity) {
  if (handle == NULL || samples_per_channel < 0) {
    return LAME_MP3_ERROR_INVALID_ARGUMENT;
  }
  if (samples_per_channel == 0) {
    return 0;
  }
  if (pcm == NULL || out == NULL) {
    return LAME_MP3_ERROR_INVALID_ARGUMENT;
  }
  // LAME treats a capacity of 0 as "unlimited"; never let that happen.
  if (out_capacity <= 0) {
    return LAME_MP3_ERROR_BUFFER_TOO_SMALL;
  }

  lame_t lame = (lame_t)handle;
  if (lame_get_num_channels(lame) == 2) {
    // LAME's prototype is not const-correct; the samples are only read.
    return lame_encode_buffer_interleaved(lame, (short*)pcm,
                                          samples_per_channel, out,
                                          out_capacity);
  }
  return lame_encode_buffer(lame, pcm, pcm, samples_per_channel, out,
                            out_capacity);
}

int32_t lame_mp3_flush(void* handle, uint8_t* out, int32_t out_capacity) {
  if (handle == NULL || out == NULL) {
    return LAME_MP3_ERROR_INVALID_ARGUMENT;
  }
  if (out_capacity <= 0) {  // 0 would mean "unlimited" to LAME
    return LAME_MP3_ERROR_BUFFER_TOO_SMALL;
  }
  return lame_encode_flush((lame_t)handle, out, out_capacity);
}

void lame_mp3_close(void* handle) {
  if (handle != NULL) {
    lame_close((lame_t)handle);
  }
}

const char* lame_mp3_version(void) { return get_lame_version(); }
