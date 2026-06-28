/* study_audio.c — Native helpers for audio analysis via raylib's Wave API.
 *
 * Two functions:
 *   1. load_wave_samples(path) → [sample_rate, FloatArray]   (small files only)
 *   2. scan_silence(path, threshold, min_duration) → [[start,end],...]  (normalized)
 *
 * scan_silence is the "imperative shell" for the pure-Ruby Core — it runs the
 * peak-scanning loop in C (avoids building a Ruby array of millions of floats)
 * and returns only the silence region pairs.
 */

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include "raylib.h"

/* ------------------------------------------------------------------ */
/* load_wave_samples — for testing / small files only                  */
/* ------------------------------------------------------------------ */

static mrb_value
sa_load_wave_samples(mrb_state *mrb, mrb_value self)
{
  const char *path;
  mrb_get_args(mrb, "z", &path);

  Wave wave = LoadWave(path);
  if (wave.data == NULL || wave.frameCount == 0) {
    return mrb_nil_value();
  }

  WaveFormat(&wave, wave.sampleRate, 32, 1);

  float *samples = (float *)wave.data;
  unsigned int frameCount = wave.frameCount;
  int sampleRate = (int)wave.sampleRate;

  mrb_value ary = mrb_ary_new_capa(mrb, frameCount);
  for (unsigned int i = 0; i < frameCount; i++) {
    mrb_ary_push(mrb, ary, mrb_float_value(mrb, (double)samples[i]));
  }

  UnloadWave(wave);

  mrb_value result = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, result, mrb_fixnum_value(sampleRate));
  mrb_ary_push(mrb, result, ary);
  return result;
}

/* ------------------------------------------------------------------ */
/* scan_silence — C-level peak scan, returns normalized region pairs   */
/* ------------------------------------------------------------------ */

#define MAX_REGIONS 4096

static mrb_value
sa_scan_silence(mrb_state *mrb, mrb_value self)
{
  const char *path;
  mrb_float threshold, min_duration;
  mrb_get_args(mrb, "zff", &path, &threshold, &min_duration);

  Wave wave = LoadWave(path);
  if (wave.data == NULL || wave.frameCount == 0) {
    return mrb_ary_new(mrb);
  }

  WaveFormat(&wave, wave.sampleRate, 32, 1);

  float *samples   = (float *)wave.data;
  unsigned int totalFrames = wave.frameCount;
  float sampleRate = (float)wave.sampleRate;

  /* Chunk size: ~10ms */
  int chunkSize = (int)(sampleRate * 0.01f);
  if (chunkSize < 1) chunkSize = 1;
  float minFrames = min_duration * sampleRate;

  mrb_value regions = mrb_ary_new_capa(mrb, 64);

  int inSilence = 0;
  unsigned int silenceStart = 0;
  int regionCount = 0;

  unsigned int i;
  for (i = 0; i < totalFrames; i += chunkSize)
  {
    unsigned int end = i + chunkSize;
    if (end > totalFrames) end = totalFrames;

    /* Find peak amplitude in this chunk */
    float peak = 0.0f;
    unsigned int j;
    for (j = i; j < end; j++) {
      float v = samples[j];
      if (v < 0.0f) v = -v;
      if (v > peak) peak = v;
    }

    if (peak < threshold) {
      if (!inSilence) { silenceStart = i; inSilence = 1; }
    } else {
      if (inSilence) {
        unsigned int len = i - silenceStart;
        if ((float)len >= minFrames && regionCount < MAX_REGIONS) {
          mrb_value pair = mrb_ary_new_capa(mrb, 2);
          mrb_ary_push(mrb, pair,
            mrb_float_value(mrb, (double)silenceStart / (double)totalFrames));
          mrb_ary_push(mrb, pair,
            mrb_float_value(mrb, (double)i / (double)totalFrames));
          mrb_ary_push(mrb, regions, pair);
          regionCount++;
        }
        inSilence = 0;
      }
    }
  }

  /* Close trailing silence */
  if (inSilence) {
    unsigned int len = totalFrames - silenceStart;
    if ((float)len >= minFrames && regionCount < MAX_REGIONS) {
      mrb_value pair = mrb_ary_new_capa(mrb, 2);
      mrb_ary_push(mrb, pair,
        mrb_float_value(mrb, (double)silenceStart / (double)totalFrames));
      mrb_ary_push(mrb, pair, mrb_float_value(mrb, 1.0));
      mrb_ary_push(mrb, regions, pair);
    }
  }

  UnloadWave(wave);
  return regions;
}

/* ------------------------------------------------------------------ */
/* gem init                                                            */
/* ------------------------------------------------------------------ */

void
mrb_study_audio_gem_init(mrb_state *mrb)
{
  struct RClass *mod = mrb_define_module(mrb, "StudyAudio");
  mrb_define_module_function(mrb, mod, "load_wave_samples",
                             sa_load_wave_samples, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, mod, "scan_silence",
                             sa_scan_silence, MRB_ARGS_REQ(3));
}

void
mrb_study_audio_gem_final(mrb_state *mrb)
{
  /* nothing */
}

