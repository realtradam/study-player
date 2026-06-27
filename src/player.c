#include "player.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Helpers (module-private)                                           */
/* ------------------------------------------------------------------ */

static int ext_equals_nocase(const char *a, const char *b)
{
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 1;
        a++; b++;
    }
    return *a != *b;
}

static const char *basename_from_path(const char *path)
{
    const char *last = path;
    for (const char *p = path; *p; p++) {
        if (*p == '/' || *p == '\\') last = p + 1;
    }
    return last;
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

bool player_load(PlayerState *state, const char *path)
{
    const char *ext = GetFileExtension(path);
    if (ext == NULL || ext_equals_nocase(ext, ".mp3") != 0) return false;

    if (state->loaded) {
        StopMusicStream(state->music);
        UnloadMusicStream(state->music);
        state->loaded = false;
        state->playing = false;
    }

    state->music = LoadMusicStream(path);
    state->duration = GetMusicTimeLength(state->music);
    state->loaded = true;
    state->playing = true;

    const char *base = basename_from_path(path);
    strncpy(state->filename, base, sizeof(state->filename) - 1);
    state->filename[sizeof(state->filename) - 1] = '\0';

    PlayMusicStream(state->music);
    return true;
}

void player_unload(PlayerState *state)
{
    if (!state->loaded) return;
    StopMusicStream(state->music);
    UnloadMusicStream(state->music);
    state->loaded = false;
    state->playing = false;
}

void player_play(PlayerState *state)
{
    if (!state->loaded || state->playing) return;
    ResumeMusicStream(state->music);
    state->playing = true;
}

void player_pause(PlayerState *state)
{
    if (!state->loaded || !state->playing) return;
    PauseMusicStream(state->music);
    state->playing = false;
}

void player_seek(PlayerState *state, float target)
{
    if (!state->loaded) return;
    if (target < 0.0f) target = 0.0f;
    if (target > state->duration) target = state->duration;
    SeekMusicStream(state->music, target);
    state->currentTime = target;
    state->skipAutoUpdate = 3; /* skip a few frames to let audio engine catch up */
}

void player_update(PlayerState *state)
{
    if (!state->loaded) return;
    UpdateMusicStream(state->music);
    if (state->playing) {
        if (state->skipAutoUpdate > 0) {
            state->skipAutoUpdate--;
        } else {
            state->currentTime = GetMusicTimePlayed(state->music);
        }
    }
}

void player_format_time(float seconds, char *buf, int bufsize)
{
    int total = (int)seconds;
    if (total < 0) total = 0;
    int h = total / 3600;
    int m = (total % 3600) / 60;
    int s = total % 60;
    if (h > 0)
        snprintf(buf, bufsize, "%d:%02d:%02d", h, m, s);
    else
        snprintf(buf, bufsize, "%d:%02d", m, s);
}
