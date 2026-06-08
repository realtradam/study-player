#define _POSIX_C_SOURCE 200809L
#include "raylib.h"
#include <string.h>
#include <ctype.h>
#include <stdio.h>
#include "config.h"
#include "layout_editor.h"
#include "raygui.h"
#include "font_data.h"

#ifdef PLATFORM_LINUX
#include <unistd.h>
#endif
#ifdef PLATFORM_WEB
#include <emscripten/emscripten.h>
#endif

#define SCREEN_W 1920
#define SCREEN_H 1080

#define MAX_SILENCE_REGIONS 4096

typedef struct {
    float start;  /* normalized 0..1 */
    float end;    /* normalized 0..1 */
} SilenceRegion;

typedef struct {
    Music music;
    bool loaded;
    bool playing;
    float duration;
    float currentTime;
    char filename[256];
    SilenceRegion silence[MAX_SILENCE_REGIONS];
    int silenceCount;
    bool studyMode;
    bool wasInSilence;    /* for detecting silence entry */
    int  lastSilenceIdx;  /* index of silence region we were last in, or -1 */
    int skipAutoUpdate;   /* frames to skip auto-updating currentTime */
    double lastVPress;    /* unused, kept for struct compat */
} PlayerState;

/* --- File-scope state (needed for emscripten main loop callback) --- */
static PlayerState state = { 0 };

static Font fontSmall, font, fontMed, fontLarge, fontHelp;
static float szSmall, szHelp, szFont, szMed, szLarge;

static Color bgColor;
static Color textColor;
static Color accentColor;
static Color mutedColor;
static Color barBgColor;
static Color btnHoverColor;

static UILayout layout;

static int activeTab = 0;
static int prevTab = 0;
static bool smartPlayHeld = false;
static char exeDir[512];

static int strcasecmp_ext(const char *a, const char *b)
{
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 1;
        a++; b++;
    }
    return *a != *b;
}

static void detect_silence(const char *path, PlayerState *s, float threshold, float minDuration)
{
    s->silenceCount = 0;
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
                if ((float)len >= minFrames && s->silenceCount < MAX_SILENCE_REGIONS)
                {
                    s->silence[s->silenceCount].start = (float)silenceStart / (float)totalFrames;
                    s->silence[s->silenceCount].end   = (float)i / (float)totalFrames;
                    s->silenceCount++;
                }
                inSilence = false;
            }
        }
    }
    /* Close any trailing silence */
    if (inSilence)
    {
        unsigned int len = totalFrames - silenceStart;
        if ((float)len >= minFrames && s->silenceCount < MAX_SILENCE_REGIONS)
        {
            s->silence[s->silenceCount].start = (float)silenceStart / (float)totalFrames;
            s->silence[s->silenceCount].end   = (float)totalFrames / (float)totalFrames;
            s->silenceCount++;
        }
    }

    UnloadWave(wave);

    /* Pad speaking portions by shrinking silence regions 0.25s on each side */
    if (s->duration > 0.0f)
    {
        float padNorm = 0.25f / s->duration; /* 0.25s in normalized units */
        for (int i = 0; i < s->silenceCount; i++)
        {
            s->silence[i].start += padNorm;
            s->silence[i].end   -= padNorm;
            if (s->silence[i].start >= s->silence[i].end)
            {
                /* Region too small after padding, remove it */
                for (int j = i; j < s->silenceCount - 1; j++)
                    s->silence[j] = s->silence[j + 1];
                s->silenceCount--;
                i--;
            }
        }
    }
}

static const char *basename_from_path(const char *path)
{
    const char *last = path;
    for (const char *p = path; *p; p++) {
        if (*p == '/' || *p == '\\') last = p + 1;
    }
    return last;
}

static void seek_to(PlayerState *s, float target)
{
    if (target < 0.0f) target = 0.0f;
    if (target > s->duration) target = s->duration;
    SeekMusicStream(s->music, target);
    s->currentTime = target;
    s->skipAutoUpdate = 3; /* skip a few frames to let audio engine catch up */
}

static void format_time(float seconds, char *buf, int bufsize)
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

/* Find the silence region index containing the normalized position, or -1 */
static int find_silence_at(PlayerState *s, float pos)
{
    for (int i = 0; i < s->silenceCount; i++)
        if (pos >= s->silence[i].start && pos < s->silence[i].end) return i;
    return -1;
}

/* Get the start of speaking portion N (0-based). Returns normalized position. */
static float speaking_portion_start(PlayerState *s, int portion)
{
    if (portion <= 0) return 0.0f;
    if (portion > s->silenceCount) return s->silence[s->silenceCount - 1].end;
    return s->silence[portion - 1].end;
}

/* Get which speaking portion (0-based) the normalized position is in.
   During silence, returns the previous speaking portion. */
static int current_speaking_portion(PlayerState *s, float pos)
{
    int portion = 0;
    for (int i = 0; i < s->silenceCount; i++)
    {
        if (pos >= s->silence[i].end)
            portion = i + 1;
        else
            break;
    }
    return portion;
}

/* Total number of speaking portions */
static int total_speaking_portions(PlayerState *s)
{
    return s->silenceCount + 1;
}

/* Get the seek target (in seconds) for jumping to a speaking portion.
   Lands 2 render-frames (~33ms) into the padding zone. */
static float segment_seek_target(PlayerState *s, int portion)
{
    float pos = speaking_portion_start(s, portion);
    float target = pos * s->duration + (2.0f / 60.0f);
    if (target < 0.0f) target = 0.0f;
    if (target > s->duration) target = s->duration;
    return target;
}

/* Check if normalized position is in the padding zone of a speaking portion.
   The padding zone is [speaking_start, speaking_start + 0.25s/duration]. */
static bool in_padding_zone(PlayerState *s, float pos, int portion)
{
    if (s->duration <= 0.0f) return false;
    float padNorm = 0.25f / s->duration;
    float start = speaking_portion_start(s, portion);
    return (pos >= start && pos < start + padNorm);
}

static void draw_text_centered(Font f, const char *text, float centerX, float y, float fontSize, Color color)
{
    float spacing = fontSize * 0.03f;
    Vector2 size = MeasureTextEx(f, text, fontSize, spacing);
    float x = centerX - size.x / 2.0f;
    DrawTextEx(f, text, (Vector2){ x, y }, fontSize, spacing, color);
}

/* Draw a right-pointing triangle (play icon) centered at cx,cy */
static void draw_play_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    Vector2 v1 = { cx - half * 0.7f, cy - half };
    Vector2 v2 = { cx - half * 0.7f, cy + half };
    Vector2 v3 = { cx + half * 0.8f, cy };
    DrawTriangle(v1, v2, v3, color);
}

/* Draw two vertical bars (pause icon) centered at cx,cy */
static void draw_pause_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    float barW = size * 0.25f;
    float gap = size * 0.15f;
    DrawRectangleRec((Rectangle){ cx - gap - barW, cy - half, barW, size }, color);
    DrawRectangleRec((Rectangle){ cx + gap, cy - half, barW, size }, color);
}

/* Draw a left-pointing triangle (seek back) centered at cx,cy */
static void draw_seek_back_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    Vector2 v1 = { cx + half * 0.7f, cy - half };
    Vector2 v2 = { cx - half * 0.8f, cy };
    Vector2 v3 = { cx + half * 0.7f, cy + half };
    DrawTriangle(v1, v2, v3, color);
}

/* Draw a right-pointing triangle (seek forward) centered at cx,cy */
static void draw_seek_fwd_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    Vector2 v1 = { cx - half * 0.7f, cy - half };
    Vector2 v2 = { cx - half * 0.7f, cy + half };
    Vector2 v3 = { cx + half * 0.8f, cy };
    DrawTriangle(v1, v2, v3, color);
}

static bool button_hit(float cx, float cy, float radius)
{
    if (!IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) return false;
    Vector2 m = GetMousePosition();
    float dx = m.x - cx;
    float dy = m.y - cy;
    return (dx * dx + dy * dy) <= (radius * radius);
}

/* Load an audio file into the player (used by both desktop drag-drop and web file input) */
static void load_audio_file(const char *path)
{
    const char *ext = GetFileExtension(path);
    if (ext == NULL || strcasecmp_ext(ext, ".mp3") != 0) return;

    if (state.loaded)
    {
        StopMusicStream(state.music);
        UnloadMusicStream(state.music);
        state.loaded = false;
        state.playing = false;
    }

    state.music = LoadMusicStream(path);
    state.duration = GetMusicTimeLength(state.music);
    state.loaded = true;
    state.playing = true;

    const char *base = basename_from_path(path);
    strncpy(state.filename, base, sizeof(state.filename) - 1);
    state.filename[sizeof(state.filename) - 1] = '\0';

    PlayMusicStream(state.music);

    /* Detect silence regions (threshold: 0.015, min duration: 0.75s) */
    detect_silence(path, &state, 0.015f, 0.75f);

    char titleBuf[320];
    snprintf(titleBuf, sizeof(titleBuf), "Study Player - %s", state.filename);
    SetWindowTitle(titleBuf);
}

#ifdef PLATFORM_WEB
/* Called from JavaScript when a file is uploaded via the file input */
EMSCRIPTEN_KEEPALIVE
void load_file_web(const char *path)
{
    load_audio_file(path);
}
#endif

/* --- Main loop body (one frame) --- */
static void update_frame(void)
{
    /* --- 1.1 Drag & drop file loading (desktop only) --- */
#ifndef PLATFORM_WEB
    if (IsFileDropped())
    {
        FilePathList files = LoadDroppedFiles();
        if (files.count > 0)
            load_audio_file(files.paths[0]);
        UnloadDroppedFiles(files);
    }
#endif

    if (activeTab == 0)
    {
    /* --- Button clicks --- */
    if (state.loaded)
    {
        /* Play/pause button */
        if (button_hit(layout.btnCenterX, layout.btnY, layout.btnRadius))
        {
            if (state.playing)
            {
                PauseMusicStream(state.music);
                state.playing = false;
            }
            else
            {
                ResumeMusicStream(state.music);
                state.playing = true;
            }
        }

        /* Section nav buttons */
        {
            float progress = (state.duration > 0.0f) ? state.currentTime / state.duration : 0.0f;
            int portion = current_speaking_portion(&state, progress) + 1;
            int total = total_speaking_portions(&state);
            if (portion > total) portion = total;
            float secBtnRadius = 35.0f;
            float secPrevX = layout.secNavX - 65.0f;
            float secNextX = layout.secNavX + 65.0f;
            float secBtnY = layout.secNavY;

            if (button_hit(secPrevX, secBtnY, secBtnRadius))
            {
                float pos = state.currentTime / state.duration;
                int p = current_speaking_portion(&state, pos);
                bool inSil = (find_silence_at(&state, pos) >= 0);
                bool inPad = in_padding_zone(&state, pos, p);
                if ((inSil || inPad) && p > 0) p--;
                float target = segment_seek_target(&state, p);
                seek_to(&state, target);
                state.wasInSilence = false;
                state.lastSilenceIdx = -1;
            }
            if (button_hit(secNextX, secBtnY, secBtnRadius))
            {
                float pos = state.currentTime / state.duration;
                int p = current_speaking_portion(&state, pos);
                if (p < total - 1) p++;
                float target = segment_seek_target(&state, p);
                seek_to(&state, target);
                state.wasInSilence = false;
                state.lastSilenceIdx = -1;
            }
        }

        /* --- Smart play hold button input --- */
        {
            Rectangle smartBtn = { layout.smartPlayX, layout.smartPlayY, 200.0f, 80.0f };
            Vector2 mouse = GetMousePosition();
            bool overBtn = (mouse.x >= smartBtn.x && mouse.x <= smartBtn.x + smartBtn.width &&
                            mouse.y >= smartBtn.y && mouse.y <= smartBtn.y + smartBtn.height);

            if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT) && overBtn) {
                smartPlayHeld = true;
                if (!state.playing) {
                    ResumeMusicStream(state.music);
                    state.playing = true;
                }
            }

            if (IsMouseButtonDown(MOUSE_BUTTON_LEFT) && smartPlayHeld) {
                /* Allow finger drift - stay held */
            }

            if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) {
                smartPlayHeld = false;
            }

            if (GetTouchPointCount() > 0 && smartPlayHeld) {
                /* Touch fallback: keep held while touch points active */
            }
        }
    }

    /* --- Keyboard input --- */
    if (state.loaded && IsKeyPressed(KEY_C) && state.playing)
    {
        PauseMusicStream(state.music);
        state.playing = false;
    }

    if (state.loaded && IsKeyPressed(KEY_N) && !state.playing)
    {
        float pos = state.currentTime / state.duration;
        int portion = current_speaking_portion(&state, pos);
        float target = segment_seek_target(&state, portion);
        seek_to(&state, target);
        ResumeMusicStream(state.music);
        state.playing = true;
    }

    if (state.loaded && IsKeyPressed(KEY_SPACE) && !state.playing)
    {
        ResumeMusicStream(state.music);
        state.playing = true;
    }

    if (state.loaded && IsKeyPressed(KEY_V))
    {
        float pos = state.currentTime / state.duration;
        int portion = current_speaking_portion(&state, pos);
        bool inSil = (find_silence_at(&state, pos) >= 0);
        bool inPad = in_padding_zone(&state, pos, portion);
        if ((inSil || inPad) && portion > 0)
            portion--;
        float target = segment_seek_target(&state, portion);
        seek_to(&state, target);
        state.wasInSilence = false;
        state.lastSilenceIdx = -1;
    }

    if (state.loaded && IsKeyPressed(KEY_B))
    {
        float pos = state.currentTime / state.duration;
        int portion = current_speaking_portion(&state, pos);
        int total = total_speaking_portions(&state);
        if (portion < total - 1) portion++;
        float target = segment_seek_target(&state, portion);
        seek_to(&state, target);
        state.wasInSilence = false;
        state.lastSilenceIdx = -1;
    }

    /* Click-to-seek on progress bar */
    if (state.loaded && IsMouseButtonPressed(MOUSE_BUTTON_LEFT))
    {
        Vector2 mouse = GetMousePosition();
        if (mouse.x >= layout.barX && mouse.x <= layout.barX + layout.barWidth &&
            mouse.y >= layout.barY && mouse.y <= layout.barY + layout.barHeight)
        {
            float target = ((mouse.x - layout.barX) / layout.barWidth) * state.duration;
            seek_to(&state, target);
        }
    }

    /* Arrow key seeking */
    if (state.loaded && IsKeyPressed(KEY_LEFT))
        seek_to(&state, state.currentTime - 5.0f);
    if (state.loaded && IsKeyPressed(KEY_RIGHT))
        seek_to(&state, state.currentTime + 5.0f);
    if (state.loaded && IsKeyPressed(KEY_UP) && !state.playing)
    {
        ResumeMusicStream(state.music);
        state.playing = true;
    }
    if (state.loaded && IsKeyPressed(KEY_DOWN) && state.playing)
    {
        PauseMusicStream(state.music);
        float rewind = state.currentTime - 1.0f;
        if (rewind < 0.0f) rewind = 0.0f;
        SeekMusicStream(state.music, rewind);
        state.currentTime = rewind;
        state.playing = false;
    }
    /* Number key seeking (0-9 = 0%-90%) */
    if (state.loaded)
    {
        for (int k = 0; k <= 9; k++)
        {
            if (IsKeyPressed(KEY_ZERO + k))
            {
                float target = state.duration * (k / 10.0f);
                seek_to(&state, target);
                break;
            }
        }
    }
    }

    /* --- Music stream update --- */
    if (state.loaded)
    {
        UpdateMusicStream(state.music);
        if (state.playing)
        {
            if (state.skipAutoUpdate > 0)
            {
                state.skipAutoUpdate--;
            }
            else
            {
                state.currentTime = GetMusicTimePlayed(state.music);
            }

            /* Study mode: auto-pause at silence boundaries */
            if (state.studyMode && state.duration > 0.0f)
            {
                float pos = state.currentTime / state.duration;
                int silIdx = find_silence_at(&state, pos);
                bool nowInSilence = (silIdx >= 0);

                if (nowInSilence && !state.wasInSilence && !IsKeyDown(KEY_SPACE) && !smartPlayHeld)
                {
                    float target = segment_seek_target(&state, silIdx + 1);
                    PauseMusicStream(state.music);
                    SeekMusicStream(state.music, target);
                    state.currentTime = target;
                    state.playing = false;
                    state.skipAutoUpdate = 3;
                }
                else if (!nowInSilence && state.wasInSilence && !IsKeyDown(KEY_SPACE) && !smartPlayHeld)
                {
                    int portion = current_speaking_portion(&state, pos);
                    float target = segment_seek_target(&state, portion);
                    PauseMusicStream(state.music);
                    SeekMusicStream(state.music, target);
                    state.currentTime = target;
                    state.playing = false;
                    state.skipAutoUpdate = 3;
                }

                state.wasInSilence = nowInSilence;
                if (nowInSilence) state.lastSilenceIdx = silIdx;
            }
        }
    }

    /* --- Save layout on tab switch --- */
    if (prevTab == 1 && activeTab == 0) {
        config_save(exeDir, &layout);
    }
    prevTab = activeTab;

    /* --- Drawing --- */
    BeginDrawing();
    ClearBackground(bgColor);

    char *tabNames[] = { "Player", "Layout" };
    GuiTabBar((Rectangle){ 0, 10, SCREEN_W, 32 }, tabNames, 2, &activeTab);

    if (activeTab == 0) {
    if (state.loaded)
    {
        draw_text_centered(font, state.filename, layout.titleX, layout.titleY, szFont, mutedColor);

        /* Progress bar */
        float currentTime = state.currentTime;
        float progress = (state.duration > 0.0f) ? currentTime / state.duration : 0.0f;
        if (progress > 1.0f) progress = 1.0f;

        Rectangle barBg = { layout.barX, layout.barY, layout.barWidth, layout.barHeight };
        Rectangle barFill = { layout.barX, layout.barY, layout.barWidth * progress, layout.barHeight };
        DrawRectangleRounded(barBg, 0.4f, 8, barBgColor);
        if (progress > 0.001f)
            DrawRectangleRounded(barFill, 0.4f, 8, accentColor);

        /* Time labels */
        char timeBuf[16];
        int elapsedSec = (int)currentTime;
        if (elapsedSec < 0) elapsedSec = 0;
        int totalSec = (int)state.duration;
        int remainSec = totalSec - elapsedSec;
        if (remainSec < 0) remainSec = 0;

        format_time((float)elapsedSec, timeBuf, sizeof(timeBuf));
        float timeFontSize = szSmall;
        float timeSpacing = timeFontSize * 0.03f;
        Vector2 leftSize = MeasureTextEx(fontSmall, timeBuf, timeFontSize, timeSpacing);
        DrawTextEx(fontSmall, timeBuf, (Vector2){ layout.barX - leftSize.x - 20, layout.barY + (layout.barHeight - timeFontSize) / 2.0f }, timeFontSize, timeSpacing, textColor);

        char remainBuf[16];
        format_time((float)remainSec, remainBuf, sizeof(remainBuf));
        float rightX = layout.barX + layout.barWidth + 20;
        DrawTextEx(fontSmall, remainBuf, (Vector2){ rightX, layout.barY + (layout.barHeight - timeFontSize) / 2.0f }, timeFontSize, timeSpacing, textColor);

        /* Percent centered above progress bar */
        char pctBuf[16];
        int pct = (int)(progress * 100.0f);
        snprintf(pctBuf, sizeof(pctBuf), "%d%%", pct);
        bool inSilence = (find_silence_at(&state, progress) >= 0);
        draw_text_centered(fontSmall, pctBuf, layout.barX + layout.barWidth / 2.0f, layout.barY - timeFontSize - 10, timeFontSize, textColor);

        /* Playback status */
        Color statusColor = (state.playing && inSilence) ? (Color){ 160, 40, 55, 255 } : accentColor;
        draw_text_centered(font, state.playing ? "PLAYING" : "PAUSED", layout.statusX, layout.statusY, szFont, statusColor);

        /* Buttons */
        Vector2 mousePos = GetMousePosition();

        /* Play/pause button */
        Color playBtnColor = (state.playing && inSilence) ? (Color){ 160, 40, 55, 255 } : accentColor;
        float ppx = layout.btnCenterX;
        float pdx = mousePos.x - ppx, pdy = mousePos.y - layout.btnY;
        bool hoverPP = (pdx*pdx + pdy*pdy) <= ((layout.btnRadius+5)*(layout.btnRadius+5));
        DrawCircle((int)ppx, (int)layout.btnY, layout.btnRadius + 8, playBtnColor);
        if (hoverPP) DrawCircle((int)ppx, (int)layout.btnY, layout.btnRadius + 8, btnHoverColor);
        if (state.playing)
            draw_pause_icon(ppx, layout.btnY, 50, textColor);
        else
            draw_play_icon(ppx, layout.btnY, 50, textColor);

        /* Speaking portion counter with prev/next section buttons */
        {
            int portion = current_speaking_portion(&state, progress) + 1;
            int total = total_speaking_portions(&state);
            if (portion > total) portion = total;
            char portionBuf[32];
            snprintf(portionBuf, sizeof(portionBuf), "%d/%d", portion, total);
            float portionY = layout.secNavY - szSmall / 2.0f;
            float portionSpacing = szSmall * 0.03f;
            Vector2 portionSize = MeasureTextEx(fontSmall, portionBuf, szSmall, portionSpacing);
            float portionX = layout.secNavX - portionSize.x / 2.0f;
            DrawTextEx(fontSmall, portionBuf, (Vector2){ portionX, portionY }, szSmall, portionSpacing, mutedColor);

            /* Section nav buttons */
            float secBtnRadius = 35.0f;
            float secPrevX = layout.secNavX - 65.0f;
            float secNextX = layout.secNavX + 65.0f;
            float secBtnY_draw = layout.secNavY;

            float sd3 = mousePos.x - secPrevX, sd4 = mousePos.y - secBtnY_draw;
            bool hoverSecPrev = (sd3*sd3 + sd4*sd4) <= (secBtnRadius*secBtnRadius);
            DrawCircle((int)secPrevX, (int)secBtnY_draw, secBtnRadius, (Color){ 50, 50, 70, 255 });
            if (hoverSecPrev) DrawCircle((int)secPrevX, (int)secBtnY_draw, secBtnRadius, btnHoverColor);
            draw_seek_back_icon(secPrevX, secBtnY_draw, 30, textColor);

            float sd5 = mousePos.x - secNextX, sd6 = mousePos.y - secBtnY_draw;
            bool hoverSecNext = (sd5*sd5 + sd6*sd6) <= (secBtnRadius*secBtnRadius);
            DrawCircle((int)secNextX, (int)secBtnY_draw, secBtnRadius, (Color){ 50, 50, 70, 255 });
            if (hoverSecNext) DrawCircle((int)secNextX, (int)secBtnY_draw, secBtnRadius, btnHoverColor);
            draw_seek_fwd_icon(secNextX, secBtnY_draw, 30, textColor);
        }

        /* --- Smart play hold button rendering --- */
        {
            Rectangle smartBtn = { layout.smartPlayX, layout.smartPlayY, 200.0f, 80.0f };
            Color btnFill = smartPlayHeld ? (Color){ 80, 30, 50, 220 } : (Color){ 50, 50, 70, 180 };
            Color btnBorder = smartPlayHeld ? accentColor : mutedColor;
            Color btnTextColor = smartPlayHeld ? accentColor : textColor;
            DrawRectangleRounded(smartBtn, 0.3f, 8, btnFill);
            DrawRectangleRoundedLines(smartBtn, 0.3f, 8, btnBorder);
            float btnSpacing = szSmall * 0.03f;
            Vector2 btnSize = MeasureTextEx(fontSmall, "HOLD", szSmall, btnSpacing);
            float tx = smartBtn.x + (smartBtn.width - btnSize.x) / 2.0f;
            float ty = smartBtn.y + (smartBtn.height - szSmall) / 2.0f;
            DrawTextEx(fontSmall, "HOLD", (Vector2){ tx, ty }, szSmall, btnSpacing, btnTextColor);
        }
    }
    else
    {
        draw_text_centered(fontLarge, "Study Player", layout.titleX, layout.titleY, szLarge, textColor);
#ifdef PLATFORM_WEB
        draw_text_centered(fontMed, "Use Load MP3 button above", (float)SCREEN_W / 2.0f, SCREEN_H / 2.0f - 20, szMed, mutedColor);
#else
        draw_text_centered(fontMed, "Drag an MP3 file here", (float)SCREEN_W / 2.0f, SCREEN_H / 2.0f - 20, szMed, mutedColor);
#endif
    }

    /* Help text and Study mode checkbox */
    {
        float helpSpacing = szHelp * 0.03f;
        DrawTextEx(fontHelp, "C: pause  N: play  Space(hold): override  V/B: prev/next  Arrows: seek  0-9: jump",
                (Vector2){ layout.helpX, layout.helpY }, szHelp, helpSpacing, mutedColor);

        const char *label = "Study Mode";
        float cbSize = 30.0f;
        Vector2 labelSize = MeasureTextEx(fontHelp, label, szHelp, helpSpacing);
        float totalW = cbSize + 10 + labelSize.x;
        float cbX = SCREEN_W - totalW - layout.helpX;
        float cbY = layout.helpY + (szHelp - cbSize) / 2.0f;

        Rectangle cbRect = { cbX, cbY, cbSize, cbSize };
        DrawRectangleLinesEx(cbRect, 2, mutedColor);
        if (state.studyMode)
            DrawRectangleRec((Rectangle){ cbX + 6, cbY + 6, cbSize - 12, cbSize - 12 }, accentColor);
        DrawTextEx(fontHelp, label, (Vector2){ cbX + cbSize + 10, layout.helpY }, szHelp, helpSpacing, mutedColor);

        if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT))
        {
            Vector2 mouse = GetMousePosition();
            if (mouse.x >= cbX && mouse.x <= cbX + totalW &&
                mouse.y >= cbY && mouse.y <= cbY + cbSize)
            {
                state.studyMode = !state.studyMode;
            }
        }
    }

    } else {
        layout_editor_draw(exeDir, &layout);
    }

    EndDrawing();
}

int main(void)
{
    InitWindow(SCREEN_W, SCREEN_H, "Study Player");
    InitAudioDevice();
    SetTargetFPS(60);

    /* Load fonts */
#if FONT_EMBEDDED
    fontSmall = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 60, NULL, 0);
    font      = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 80, NULL, 0);
    fontMed   = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 100, NULL, 0);
    fontLarge = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 160, NULL, 0);
    fontHelp  = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 40, NULL, 0);
    szSmall = 60.0f;
    szHelp  = 40.0f;
    szFont  = 80.0f;
    szMed   = 100.0f;
    szLarge = 160.0f;
#else
    fontSmall = GetFontDefault();
    font      = GetFontDefault();
    fontMed   = GetFontDefault();
    fontLarge = GetFontDefault();
    fontHelp  = GetFontDefault();
    szSmall = 30.0f;
    szHelp  = 20.0f;
    szFont  = 40.0f;
    szMed   = 50.0f;
    szLarge = 80.0f;
#endif

    bgColor      = (Color){ 26, 26, 46, 255 };
    textColor    = (Color){ 234, 234, 234, 255 };
    accentColor  = (Color){ 233, 69, 96, 255 };
    mutedColor   = (Color){ 140, 140, 160, 255 };
    barBgColor   = (Color){ 60, 60, 60, 255 };
    btnHoverColor = (Color){ 255, 255, 255, 40 };

    memset(&state, 0, sizeof(state));
    state.studyMode = true;
    state.lastSilenceIdx = -1;

    {
        char exePath[512] = {0};
#ifdef PLATFORM_LINUX
        readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
#endif
        config_load(exePath, &layout);

        {
            const char *lastSlash = strrchr(exePath, '/');
            if (lastSlash) {
                size_t len = (size_t)(lastSlash - exePath);
                if (len >= sizeof(exeDir)) len = sizeof(exeDir) - 1;
                memcpy(exeDir, exePath, len);
                exeDir[len] = '\0';
            } else {
                exeDir[0] = '.';
                exeDir[1] = '\0';
            }
        }

        layout_editor_init();
    }

#ifdef PLATFORM_WEB
    emscripten_set_main_loop(update_frame, 0, 1);
#else
    while (!WindowShouldClose())
    {
        update_frame();
    }
#endif

    if (state.loaded)
    {
        StopMusicStream(state.music);
        UnloadMusicStream(state.music);
    }

#if FONT_EMBEDDED
    UnloadFont(fontSmall);
    UnloadFont(font);
    UnloadFont(fontMed);
    UnloadFont(fontLarge);
    UnloadFont(fontHelp);
#endif
    CloseAudioDevice();
    CloseWindow();

    return 0;
}
