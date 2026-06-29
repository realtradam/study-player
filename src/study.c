#include "study.h"

#include <stdio.h>

/* ------------------------------------------------------------------ */
/* Silence detection                                                  */
/* ------------------------------------------------------------------ */

void study_detect_silence(const char *path, PlayerState *state,
                          float threshold, float minDuration)
{
    state->silenceCount = 0;
    Wave wave = LoadWave(path);
    if (wave.data == NULL || wave.frameCount == 0) return;

    /* Convert to 32-bit float mono for easy analysis */
    WaveFormat(&wave, wave.sampleRate, 32, 1);
    float *samples = (float *)wave.data;
    unsigned int totalFrames = wave.frameCount;
    float sampleRate = (float)wave.sampleRate;

    /* Scan in chunks of ~10ms */
    int chunkSize = (int)(sampleRate * 0.01f);
    if (chunkSize < 1) chunkSize = 1;
    float minFrames = minDuration * sampleRate;

    bool inSilence = false;
    unsigned int silenceStart = 0;

    for (unsigned int i = 0; i < totalFrames; i += chunkSize)
    {
        unsigned int end = i + chunkSize;
        if (end > totalFrames) end = totalFrames;

        /* Find peak amplitude in this chunk */
        float peak = 0.0f;
        for (unsigned int j = i; j < end; j++)
        {
            float v = samples[j];
            if (v < 0) v = -v;
            if (v > peak) peak = v;
        }

        if (peak < threshold)
        {
            if (!inSilence) { silenceStart = i; inSilence = true; }
        }
        else
        {
            if (inSilence)
            {
                unsigned int len = i - silenceStart;
                if ((float)len >= minFrames && state->silenceCount < MAX_SILENCE_REGIONS)
                {
                    state->silence[state->silenceCount].start = (float)silenceStart / (float)totalFrames;
                    state->silence[state->silenceCount].end   = (float)i / (float)totalFrames;
                    state->silenceCount++;
                }
                inSilence = false;
            }
        }
    }
    /* Close any trailing silence */
    if (inSilence)
    {
        unsigned int len = totalFrames - silenceStart;
        if ((float)len >= minFrames && state->silenceCount < MAX_SILENCE_REGIONS)
        {
            state->silence[state->silenceCount].start = (float)silenceStart / (float)totalFrames;
            state->silence[state->silenceCount].end   = (float)totalFrames / (float)totalFrames;
            state->silenceCount++;
        }
    }

    UnloadWave(wave);

    /* Pad speaking portions by shrinking silence regions 0.25s on each side */
    if (state->duration > 0.0f)
    {
        float padNorm = 0.25f / state->duration;
        for (int i = 0; i < state->silenceCount; i++)
        {
            state->silence[i].start += padNorm;
            state->silence[i].end   -= padNorm;
            if (state->silence[i].start >= state->silence[i].end)
            {
                /* Region too small after padding, remove it */
                for (int j = i; j < state->silenceCount - 1; j++)
                    state->silence[j] = state->silence[j + 1];
                state->silenceCount--;
                i--;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Portion navigation                                                 */
/* ------------------------------------------------------------------ */

int study_find_silence_at(const PlayerState *state, float pos)
{
    for (int i = 0; i < state->silenceCount; i++)
        if (pos >= state->silence[i].start && pos < state->silence[i].end) return i;
    return -1;
}

float study_speaking_portion_start(const PlayerState *state, int portion)
{
    if (portion <= 0) return 0.0f;
    if (portion > state->silenceCount) return state->silence[state->silenceCount - 1].end;
    return state->silence[portion - 1].end;
}

int study_current_speaking_portion(const PlayerState *state, float pos)
{
    int portion = 0;
    for (int i = 0; i < state->silenceCount; i++)
    {
        if (pos >= state->silence[i].end)
            portion = i + 1;
        else
            break;
    }
    return portion;
}

int study_total_speaking_portions(const PlayerState *state)
{
    return state->silenceCount + 1;
}

float study_portion_seek_target(const PlayerState *state, int portion)
{
    float pos = study_speaking_portion_start(state, portion);
    float target = pos * state->duration + (2.0f / 60.0f);
    if (target < 0.0f) target = 0.0f;
    if (target > state->duration) target = state->duration;
    return target;
}

bool study_in_padding_zone(const PlayerState *state, float pos, int portion)
{
    if (state->duration <= 0.0f) return false;
    float padNorm = 0.25f / state->duration;
    float start = study_speaking_portion_start(state, portion);
    return (pos >= start && pos < start + padNorm);
}

/* ------------------------------------------------------------------ */
/* Auto-pause logic                                                   */
/* ------------------------------------------------------------------ */

void study_auto_pause_check(PlayerState *state, bool smartPlayHeld, bool spaceHeld)
{
    if (!state->studyMode || state->duration <= 0.0f || !state->playing)
        return;

    if (smartPlayHeld || spaceHeld) {
        /* Override: still track silence state but don't auto-pause */
        float pos = state->currentTime / state->duration;
        int silIdx = study_find_silence_at(state, pos);
        state->wasInSilence = (silIdx >= 0);
        if (silIdx >= 0) state->lastSilenceIdx = silIdx;
        return;
    }

    float pos = state->currentTime / state->duration;
    int silIdx = study_find_silence_at(state, pos);
    bool nowInSilence = (silIdx >= 0);

    if (nowInSilence && !state->wasInSilence)
    {
        /* Entering silence: seek to start of next speaking portion */
        float target = study_portion_seek_target(state, silIdx + 1);
        PauseMusicStream(state->music);
        SeekMusicStream(state->music, target);
        state->currentTime = target;
        state->playing = false;
        state->skipAutoUpdate = 3;
    }
    else if (!nowInSilence && state->wasInSilence)
    {
        /* Exiting silence: land at start of current speaking portion */
        int portion = study_current_speaking_portion(state, pos);
        float target = study_portion_seek_target(state, portion);
        PauseMusicStream(state->music);
        SeekMusicStream(state->music, target);
        state->currentTime = target;
        state->playing = false;
        state->skipAutoUpdate = 3;
    }

    state->wasInSilence = nowInSilence;
    if (nowInSilence) state->lastSilenceIdx = silIdx;
}
