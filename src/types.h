#pragma once

/* types.h — shared types, constants, and defines.
 *
 * This is the ONE header every module includes for shared data structures.
 * No .c file — pure declarations. Raylib is included because PlayerState
 * holds a Music handle. */

#include "raylib.h"

/* ------------------------------------------------------------------ */
/* Screen dimensions                                                  */
/* ------------------------------------------------------------------ */

#define SCREEN_W 1920
#define SCREEN_H 1080

/* ------------------------------------------------------------------ */
/* Limits                                                             */
/* ------------------------------------------------------------------ */

#define MAX_SILENCE_REGIONS 4096
#define MAX_FILENAME        256

/* ------------------------------------------------------------------ */
/* Audio / study types                                                */
/* ------------------------------------------------------------------ */

/* A detected gap in the audio where amplitude stays below threshold.
 * start/end are normalized 0..1 relative to total frame count. */
typedef struct {
    float start;  /* normalized 0..1 */
    float end;    /* normalized 0..1 */
} SilenceRegion;

/* All mutable runtime state. Passed by pointer to every module. */
typedef struct {
    Music music;
    bool loaded;
    bool playing;
    float duration;
    float currentTime;
    char filename[MAX_FILENAME];

    SilenceRegion silence[MAX_SILENCE_REGIONS];
    int  silenceCount;

    bool studyMode;
    bool wasInSilence;    /* for detecting silence entry */
    int  lastSilenceIdx;  /* index of silence region we were last in, or -1 */
    int  skipAutoUpdate;  /* frames to skip auto-updating currentTime */
} PlayerState;

/* ------------------------------------------------------------------ */
/* UI layout — pixel positions for every on-screen element.           */
/* Persisted to study-player.cfg via config_load / config_save.       */
/* ------------------------------------------------------------------ */

typedef struct {
    float titleY;
    float titleX;
    float barY;
    float barHeight;
    float barWidth;
    float barX;
    float statusY;
    float statusX;
    float btnRadius;
    float helpY;
    float helpX;
    float btnY;
    float btnCenterX;
    float smartPlayY;
    float smartPlayX;
    float secNavY;
    float secNavX;
} UILayout;
