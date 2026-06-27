#pragma once

/* player.h — audio playback contract.
 *
 * Owns: loading MP3 files, play/pause/seek, time formatting,
 * music-stream updates, cleanup. */

#include "types.h"

/* Load an MP3 file into the player. Handles unloading any previously
 * loaded stream. Sets state->loaded, state->playing, state->duration,
 * state->filename. Returns true on success. */
bool player_load(PlayerState *state, const char *path);

/* Unload the current audio stream and reset loaded/playing flags. */
void player_unload(PlayerState *state);

/* Playback control. No-ops if nothing is loaded. */
void player_play(PlayerState *state);
void player_pause(PlayerState *state);

/* Seek to an absolute time (seconds), clamped to [0, duration]. */
void player_seek(PlayerState *state, float target);

/* Per-frame update: pumps the music stream and refreshes currentTime.
 * Call once per frame while state->loaded is true. */
void player_update(PlayerState *state);

/* Format a time in seconds as "H:MM:SS" or "M:SS" into buf. */
void player_format_time(float seconds, char *buf, int bufsize);
