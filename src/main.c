#include "raylib.h"
#include <string.h>
#include <ctype.h>
#include <stdio.h>
#include "font_data.h"

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
    bool pausedAtSilence; /* paused by study mode at silence */
    int skipAutoUpdate;   /* frames to skip auto-updating currentTime */
    double lastVPress;    /* timestamp of last V press for double-tap */
} PlayerState;

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

static void draw_text_centered(Font font, const char *text, float y, float fontSize, Color color)
{
    float spacing = fontSize * 0.03f;
    Vector2 size = MeasureTextEx(font, text, fontSize, spacing);
    float x = (SCREEN_W - size.x) / 2.0f;
    DrawTextEx(font, text, (Vector2){ x, y }, fontSize, spacing, color);
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

int main(void)
{
    InitWindow(SCREEN_W, SCREEN_H, "Study Player");
    InitAudioDevice();
    SetTargetFPS(60);

    /* Load fonts (embedded or default) */
#if FONT_EMBEDDED
    Font fontSmall = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 60, NULL, 0);
    Font font      = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 80, NULL, 0);
    Font fontMed   = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 100, NULL, 0);
    Font fontLarge = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 160, NULL, 0);
    Font fontHelp  = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 40, NULL, 0);
    float szSmall = 60.0f;
    float szHelp  = 40.0f;
    float szFont  = 80.0f;
    float szMed   = 100.0f;
    float szLarge = 160.0f;
#else
    Font fontSmall = GetFontDefault();
    Font font      = GetFontDefault();
    Font fontMed   = GetFontDefault();
    Font fontLarge = GetFontDefault();
    Font fontHelp  = GetFontDefault();
    float szSmall = 30.0f;
    float szHelp  = 20.0f;
    float szFont  = 40.0f;
    float szMed   = 50.0f;
    float szLarge = 80.0f;
#endif

    Color bgColor      = (Color){ 26, 26, 46, 255 };      /* #1a1a2e */
    Color textColor     = (Color){ 234, 234, 234, 255 };   /* #eaeaea */
    Color accentColor   = (Color){ 233, 69, 96, 255 };     /* #e94560 */
    Color mutedColor    = (Color){ 140, 140, 160, 255 };
    Color barBgColor    = (Color){ 60, 60, 60, 255 };
    Color btnHoverColor = (Color){ 255, 255, 255, 40 };

    PlayerState state = { 0 };
    state.studyMode = true;

    /* Layout constants */
    const float titleY    = 60.0f;
    const float barY      = 460.0f;
    const float barHeight = 50.0f;
    const float barWidth  = SCREEN_W * 0.65f;
    const float barX      = (SCREEN_W - barWidth) / 2.0f;
    const float statusY   = barY + barHeight + 30.0f;
    const float btnY      = statusY + 120.0f + 55.0f; /* below status text + gap */
    const float btnRadius = 55.0f;
    const float btnSpacing = 150.0f;
    const float btnCenterX = SCREEN_W / 2.0f;
    const float helpY     = SCREEN_H - 80.0f;

    while (!WindowShouldClose())
    {
        /* --- 1.1 Drag & drop file loading --- */
        if (IsFileDropped())
        {
            FilePathList files = LoadDroppedFiles();
            if (files.count > 0)
            {
                const char *path = files.paths[0];
                const char *ext = GetFileExtension(path);

                if (ext != NULL && strcasecmp_ext(ext, ".mp3") == 0)
                {
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

                    /* Detect silence regions (threshold: 0.01, min duration: 0.5s) */
                    detect_silence(path, &state, 0.015f, 0.75f);

                    char titleBuf[320];
                    snprintf(titleBuf, sizeof(titleBuf), "Study Player - %s", state.filename);
                    SetWindowTitle(titleBuf);
                }
            }
            UnloadDroppedFiles(files);
        }

        /* --- Button clicks --- */
        if (state.loaded)
        {
            /* Seek back button */
            if (button_hit(btnCenterX - btnSpacing, btnY, btnRadius))
            {
                seek_to(&state, state.currentTime - 5.0f);
                state.pausedAtSilence = false;
            }

            /* Play/pause button */
            if (button_hit(btnCenterX, btnY, btnRadius))
            {
                if (state.playing)
                {
                    PauseMusicStream(state.music);
                    if (state.studyMode)
                    {
                        /* Jump to start of current speaking part */
                        float pos = state.currentTime / state.duration;
                        int portion = current_speaking_portion(&state, pos);
                        float target = speaking_portion_start(&state, portion) * state.duration;
                        SeekMusicStream(state.music, target);
                        state.currentTime = target;
                    }
                    else
                    {
                        float rewind = state.currentTime - 1.0f;
                        if (rewind < 0.0f) rewind = 0.0f;
                        SeekMusicStream(state.music, rewind);
                        state.currentTime = rewind;
                    }
                    state.playing = false;
                    state.pausedAtSilence = false;
                }
                else
                {
                    if (state.studyMode && state.pausedAtSilence)
                    {
                        /* Resume after the silence gap */
                        float pos = state.currentTime / state.duration;
                        int silIdx = find_silence_at(&state, pos);
                        if (silIdx >= 0)
                        {
                            float target = state.silence[silIdx].end * state.duration;
                            SeekMusicStream(state.music, target);
                            state.currentTime = target;
                        }
                        state.pausedAtSilence = false;
                    }
                    ResumeMusicStream(state.music);
                    state.playing = true;
                }
            }

            /* Seek forward button */
            if (button_hit(btnCenterX + btnSpacing, btnY, btnRadius))
            {
                seek_to(&state, state.currentTime + 5.0f);
                state.pausedAtSilence = false;
            }
        }

        /* --- Keyboard input --- */
        if (state.loaded && IsKeyPressed(KEY_SPACE))
        {
            if (state.playing)
            {
                PauseMusicStream(state.music);
                if (state.studyMode)
                {
                    float pos = state.currentTime / state.duration;
                    int portion = current_speaking_portion(&state, pos);
                    float target = speaking_portion_start(&state, portion) * state.duration;
                    SeekMusicStream(state.music, target);
                    state.currentTime = target;
                }
                else
                {
                    float rewind = state.currentTime - 1.0f;
                    if (rewind < 0.0f) rewind = 0.0f;
                    SeekMusicStream(state.music, rewind);
                    state.currentTime = rewind;
                }
                state.playing = false;
                state.pausedAtSilence = false;
            }
            else
            {
                if (state.studyMode && state.pausedAtSilence)
                {
                    /* Skip past silence gap */
                    float pos = state.currentTime / state.duration;
                    int silIdx = find_silence_at(&state, pos);
                    if (silIdx >= 0)
                    {
                        float target = state.silence[silIdx].end * state.duration;
                        SeekMusicStream(state.music, target);
                        state.currentTime = target;
                    }
                    state.pausedAtSilence = false;
                }
                ResumeMusicStream(state.music);
                state.playing = true;
            }
        }

        /* V = jump to start of current speaking part (double-tap for previous) */
        if (state.loaded && IsKeyPressed(KEY_V))
        {
            float pos = state.currentTime / state.duration;
            int portion = current_speaking_portion(&state, pos);
            double now = GetTime();
            bool doubleTap = (now - state.lastVPress) < 0.5;
            state.lastVPress = now;

            if (doubleTap && portion > 0)
            {
                portion--;
            }
            float target = speaking_portion_start(&state, portion) * state.duration;
            seek_to(&state, target);
            state.pausedAtSilence = false;
            state.wasInSilence = false;
        }

        /* B = jump to start of next speaking part */
        if (state.loaded && IsKeyPressed(KEY_B))
        {
            float pos = state.currentTime / state.duration;
            int portion = current_speaking_portion(&state, pos);
            int total = total_speaking_portions(&state);
            if (portion < total - 1) portion++;
            float target = speaking_portion_start(&state, portion) * state.duration;
            seek_to(&state, target);
            state.pausedAtSilence = false;
            state.wasInSilence = false;
        }

        /* --- 2.3 Click-to-seek on progress bar --- */
        if (state.loaded && IsMouseButtonPressed(MOUSE_BUTTON_LEFT))
        {
            Vector2 mouse = GetMousePosition();
            if (mouse.x >= barX && mouse.x <= barX + barWidth &&
                mouse.y >= barY && mouse.y <= barY + barHeight)
            {
                float target = ((mouse.x - barX) / barWidth) * state.duration;
                seek_to(&state, target);
            }
        }

        /* --- 1.3 Arrow key seeking --- */
        if (state.loaded && IsKeyPressed(KEY_LEFT))
        {
            seek_to(&state, state.currentTime - 5.0f);
        }
        if (state.loaded && IsKeyPressed(KEY_RIGHT))
        {
            seek_to(&state, state.currentTime + 5.0f);
        }
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
        /* --- Number key seeking (0-9 = 0%-90%) --- */
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

        /* --- 1.4 Music stream update (after input so state is fresh) --- */
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
                    bool nowInSilence = (find_silence_at(&state, pos) >= 0);

                    if (nowInSilence && !state.wasInSilence && !IsKeyDown(KEY_SPACE))
                    {
                        /* Just entered silence — auto-pause */
                        PauseMusicStream(state.music);
                        state.playing = false;
                        state.pausedAtSilence = true;
                    }
                    state.wasInSilence = nowInSilence;
                }
            }
        }

        /* --- Drawing --- */
        BeginDrawing();
        ClearBackground(bgColor);

        if (state.loaded)
        {
            /* 3.2 Filename — shown below where title was */
            draw_text_centered(font, state.filename, titleY, szFont, mutedColor);

            /* --- 2.1 Progress bar --- */
            float currentTime = state.currentTime;
            float progress = (state.duration > 0.0f) ? currentTime / state.duration : 0.0f;
            if (progress > 1.0f) progress = 1.0f;

            Rectangle barBg = { barX, barY, barWidth, barHeight };
            Rectangle barFill = { barX, barY, barWidth * progress, barHeight };
            DrawRectangleRounded(barBg, 0.4f, 8, barBgColor);
            if (progress > 0.001f)
                DrawRectangleRounded(barFill, 0.4f, 8, accentColor);

            /* --- 2.2 Time labels --- */
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
            DrawTextEx(fontSmall, timeBuf, (Vector2){ barX - leftSize.x - 20, barY + (barHeight - timeFontSize) / 2.0f }, timeFontSize, timeSpacing, textColor);

            char remainBuf[16];
            format_time((float)remainSec, remainBuf, sizeof(remainBuf));
            float rightX = barX + barWidth + 20;
            DrawTextEx(fontSmall, remainBuf, (Vector2){ rightX, barY + (barHeight - timeFontSize) / 2.0f }, timeFontSize, timeSpacing, textColor);

            /* Percent centered above progress bar */
            char pctBuf[16];
            int pct = (int)(progress * 100.0f);
            snprintf(pctBuf, sizeof(pctBuf), "%d%%", pct);
            bool inSilence = (find_silence_at(&state, progress) >= 0);
            draw_text_centered(fontSmall, pctBuf, barY - timeFontSize - 10, timeFontSize, textColor);

            /* 3.3 Playback status — color changes with silence/speech only while playing */
            Color statusColor = (state.playing && inSilence) ? (Color){ 160, 40, 55, 255 } : accentColor;
            draw_text_centered(font, state.playing ? "PLAYING" : "PAUSED", statusY, szFont, statusColor);

            /* --- Buttons --- */
            Vector2 mousePos = GetMousePosition();

            /* Seek back button */
            float sbx = btnCenterX - btnSpacing;
            float sdx1 = mousePos.x - sbx, sdy1 = mousePos.y - btnY;
            bool hoverBack = (sdx1*sdx1 + sdy1*sdy1) <= (btnRadius*btnRadius);
            DrawCircle((int)sbx, (int)btnY, btnRadius, (Color){ 50, 50, 70, 255 });
            if (hoverBack) DrawCircle((int)sbx, (int)btnY, btnRadius, btnHoverColor);
            draw_seek_back_icon(sbx, btnY, 50, textColor);

            /* Play/pause button — color reflects silence/speech */
            Color playBtnColor = (state.playing && inSilence) ? (Color){ 160, 40, 55, 255 } : accentColor;
            float ppx = btnCenterX;
            float pdx = mousePos.x - ppx, pdy = mousePos.y - btnY;
            bool hoverPP = (pdx*pdx + pdy*pdy) <= ((btnRadius+5)*(btnRadius+5));
            DrawCircle((int)ppx, (int)btnY, btnRadius + 8, playBtnColor);
            if (hoverPP) DrawCircle((int)ppx, (int)btnY, btnRadius + 8, btnHoverColor);
            if (state.playing)
                draw_pause_icon(ppx, btnY, 50, textColor);
            else
                draw_play_icon(ppx, btnY, 50, textColor);

            /* Seek forward button */
            float sfx = btnCenterX + btnSpacing;
            float sdx2 = mousePos.x - sfx, sdy2 = mousePos.y - btnY;
            bool hoverFwd = (sdx2*sdx2 + sdy2*sdy2) <= (btnRadius*btnRadius);
            DrawCircle((int)sfx, (int)btnY, btnRadius, (Color){ 50, 50, 70, 255 });
            if (hoverFwd) DrawCircle((int)sfx, (int)btnY, btnRadius, btnHoverColor);
            draw_seek_fwd_icon(sfx, btnY, 50, textColor);

            /* Speaking portion counter below buttons */
            {
                int portion = current_speaking_portion(&state, progress) + 1;
                int total = total_speaking_portions(&state);
                if (portion > total) portion = total;
                char portionBuf[32];
                snprintf(portionBuf, sizeof(portionBuf), "%d/%d", portion, total);
                draw_text_centered(fontSmall, portionBuf, btnY + btnRadius + 80, szSmall, mutedColor);
            }
        }
        else
        {
            /* 3.1 Title — shown only when no file loaded */
            draw_text_centered(fontLarge, "Study Player", titleY, szLarge, textColor);
            /* 3.2 No file prompt — vertically centered */
            draw_text_centered(fontMed, "Drag an MP3 file here", SCREEN_H / 2.0f - 20, szMed, mutedColor);
        }

        /* 3.4 Help text (left-aligned) and Study mode checkbox (right-aligned) on same line */
        {
            float helpSpacing = szHelp * 0.03f;
            float padding = 40.0f;
            DrawTextEx(fontHelp, "Space: play/pause    Arrows: seek    V/B: prev/next section    0-9: jump",
                (Vector2){ padding, helpY }, szHelp, helpSpacing, mutedColor);

            /* Study mode checkbox - right aligned on same line */
            const char *label = "Study Mode";
            float cbSize = 30.0f;
            Vector2 labelSize = MeasureTextEx(fontHelp, label, szHelp, helpSpacing);
            float totalW = cbSize + 10 + labelSize.x;
            float cbX = SCREEN_W - totalW - padding;
            float cbY = helpY + (szHelp - cbSize) / 2.0f;

            Rectangle cbRect = { cbX, cbY, cbSize, cbSize };
            DrawRectangleLinesEx(cbRect, 2, mutedColor);
            if (state.studyMode)
                DrawRectangleRec((Rectangle){ cbX + 6, cbY + 6, cbSize - 12, cbSize - 12 }, accentColor);
            DrawTextEx(fontHelp, label, (Vector2){ cbX + cbSize + 10, helpY }, szHelp, helpSpacing, mutedColor);

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

        EndDrawing();
    }

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
