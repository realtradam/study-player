#include "raylib.h"
#include <string.h>
#include <ctype.h>
#include <stdio.h>
#include "font_data.h"

#define SCREEN_W 1920
#define SCREEN_H 1080

typedef struct {
    Music music;
    bool loaded;
    bool playing;
    float duration;
    float currentTime;
    char filename[256];
} PlayerState;

static int strcasecmp_ext(const char *a, const char *b)
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

static void seek_to(PlayerState *s, float target)
{
    if (target < 0.0f) target = 0.0f;
    if (target > s->duration) target = s->duration;
    SeekMusicStream(s->music, target);
    s->currentTime = target;
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
            }

            /* Play/pause button */
            if (button_hit(btnCenterX, btnY, btnRadius))
            {
                if (state.playing)
                {
                    PauseMusicStream(state.music);
                    float rewind = state.currentTime - 1.0f;
                    if (rewind < 0.0f) rewind = 0.0f;
                    SeekMusicStream(state.music, rewind);
                    state.currentTime = rewind;
                    state.playing = false;
                }
                else
                {
                    ResumeMusicStream(state.music);
                    state.playing = true;
                }
            }

            /* Seek forward button */
            if (button_hit(btnCenterX + btnSpacing, btnY, btnRadius))
            {
                seek_to(&state, state.currentTime + 5.0f);
            }
        }

        /* --- 1.2 Play/pause with keyboard --- */
        if (state.loaded && IsKeyPressed(KEY_SPACE))
        {
            if (state.playing)
            {
                PauseMusicStream(state.music);
                float rewind = state.currentTime - 1.0f;
                if (rewind < 0.0f) rewind = 0.0f;
                SeekMusicStream(state.music, rewind);
                state.currentTime = rewind;
                state.playing = false;
            }
            else
            {
                ResumeMusicStream(state.music);
                state.playing = true;
            }
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
                state.currentTime = GetMusicTimePlayed(state.music);
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
            draw_text_centered(fontSmall, pctBuf, barY - timeFontSize - 10, timeFontSize, textColor);

            /* 3.3 Playback status */
            draw_text_centered(font, state.playing ? "PLAYING" : "PAUSED", statusY, szFont, accentColor);

            /* --- Buttons --- */
            Vector2 mousePos = GetMousePosition();

            /* Seek back button */
            float sbx = btnCenterX - btnSpacing;
            float sdx1 = mousePos.x - sbx, sdy1 = mousePos.y - btnY;
            bool hoverBack = (sdx1*sdx1 + sdy1*sdy1) <= (btnRadius*btnRadius);
            DrawCircle((int)sbx, (int)btnY, btnRadius, (Color){ 50, 50, 70, 255 });
            if (hoverBack) DrawCircle((int)sbx, (int)btnY, btnRadius, btnHoverColor);
            draw_seek_back_icon(sbx, btnY, 50, textColor);

            /* Play/pause button */
            float ppx = btnCenterX;
            float pdx = mousePos.x - ppx, pdy = mousePos.y - btnY;
            bool hoverPP = (pdx*pdx + pdy*pdy) <= ((btnRadius+5)*(btnRadius+5));
            DrawCircle((int)ppx, (int)btnY, btnRadius + 8, accentColor);
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
        }
        else
        {
            /* 3.1 Title — shown only when no file loaded */
            draw_text_centered(fontLarge, "Study Player", titleY, szLarge, textColor);
            /* 3.2 No file prompt — vertically centered */
            draw_text_centered(fontMed, "Drag an MP3 file here", SCREEN_H / 2.0f - 20, szMed, mutedColor);
        }

        /* 3.4 Help text */
        draw_text_centered(fontHelp, "Space: play/pause    Arrows: play/pause/seek    0-9: jump to 0%-90%    Click bar: seek", helpY, szHelp, mutedColor);

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
