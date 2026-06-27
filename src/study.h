#pragma once

/* study.h — study mode contract.
 *
 * Owns: silence detection, speaking-portion navigation, auto-pause logic.
 * All functions take PlayerState* and work with the normalized positions
 * stored in state->silence[]. */

#include "types.h"

/* Analyze an audio file and populate state->silence[] with detected gaps.
 * threshold  — amplitude below which a chunk is "silent" (e.g. 0.015).
 * minDuration — minimum silence length in seconds (e.g. 0.75).
 * Requires state->duration to be set (call after player_load). */
void study_detect_silence(const char *path, PlayerState *state,
                          float threshold, float minDuration);

/* Return the index of the silence region containing pos (normalized 0..1),
 * or -1 if none. */
int study_find_silence_at(const PlayerState *state, float pos);

/* Start (normalized) of speaking portion N (0-based). Portion 0 = 0.0. */
float study_speaking_portion_start(const PlayerState *state, int portion);

/* Which speaking portion (0-based) the position falls in.
 * During silence, returns the previous speaking portion. */
int study_current_speaking_portion(const PlayerState *state, float pos);

/* Total number of speaking portions (silenceCount + 1). */
int study_total_speaking_portions(const PlayerState *state);

/* Seek target (seconds) for jumping to a speaking portion.
 * Lands 2 render-frames (~33ms) into the padding zone. */
float study_segment_seek_target(const PlayerState *state, int portion);

/* Is pos inside the padding zone of the given speaking portion?
 * Padding zone = [speaking_start, speaking_start + 0.25s/duration]. */
bool study_in_padding_zone(const PlayerState *state, float pos, int portion);

/* Run the study-mode auto-pause check for this frame.
 * Call after player_update while state->studyMode && state->playing.
 * smartPlayHeld / spaceHeld suppress auto-pause when true.
 * Mutates: state->playing, state->currentTime, state->wasInSilence,
 *          state->lastSilenceIdx, state->skipAutoUpdate. */
void study_auto_pause_check(PlayerState *state, bool smartPlayHeld, bool spaceHeld);
