#include "ui.h"
#include "study.h"
#include "player.h"
#include "font_data.h"

#include <stdio.h>

/* ------------------------------------------------------------------ */
/* Module-private drawing helpers                                     */
/* ------------------------------------------------------------------ */

static void draw_text_centered(Font f, const char *text, float centerX,
                               float y, float fontSize, Color color)
{
    float spacing = fontSize * 0.03f;
    Vector2 size = MeasureTextEx(f, text, fontSize, spacing);
    float x = centerX - size.x / 2.0f;
    DrawTextEx(f, text, (Vector2){ x, y }, fontSize, spacing, color);
}

static void draw_play_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    Vector2 v1 = { cx - half * 0.7f, cy - half };
    Vector2 v2 = { cx - half * 0.7f, cy + half };
    Vector2 v3 = { cx + half * 0.8f, cy };
    DrawTriangle(v1, v2, v3, color);
}

static void draw_pause_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    float barW = size * 0.25f;
    float gap = size * 0.15f;
    DrawRectangleRec((Rectangle){ cx - gap - barW, cy - half, barW, size }, color);
    DrawRectangleRec((Rectangle){ cx + gap, cy - half, barW, size }, color);
}

static void draw_seek_back_icon(float cx, float cy, float size, Color color)
{
    float half = size / 2.0f;
    Vector2 v1 = { cx + half * 0.7f, cy - half };
    Vector2 v2 = { cx - half * 0.8f, cy };
    Vector2 v3 = { cx + half * 0.7f, cy + half };
    DrawTriangle(v1, v2, v3, color);
}

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

/* ------------------------------------------------------------------ */
/* Lifecycle                                                          */
/* ------------------------------------------------------------------ */

void ui_init(UIState *ui)
{
#if FONT_EMBEDDED
    ui->fontSmall = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 60, NULL, 0);
    ui->font      = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 80, NULL, 0);
    ui->fontMed   = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 100, NULL, 0);
    ui->fontLarge = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 160, NULL, 0);
    ui->fontHelp  = LoadFontFromMemory(".otf", embedded_font_data, embedded_font_data_len, 40, NULL, 0);
    ui->szSmall = 60.0f;
    ui->szHelp  = 40.0f;
    ui->szFont  = 80.0f;
    ui->szMed   = 100.0f;
    ui->szLarge = 160.0f;
#else
    ui->fontSmall = GetFontDefault();
    ui->font      = GetFontDefault();
    ui->fontMed   = GetFontDefault();
    ui->fontLarge = GetFontDefault();
    ui->fontHelp  = GetFontDefault();
    ui->szSmall = 30.0f;
    ui->szHelp  = 20.0f;
    ui->szFont  = 40.0f;
    ui->szMed   = 50.0f;
    ui->szLarge = 80.0f;
#endif

    ui->bgColor       = (Color){ 26, 26, 46, 255 };
    ui->textColor     = (Color){ 234, 234, 234, 255 };
    ui->accentColor   = (Color){ 233, 69, 96, 255 };
    ui->mutedColor    = (Color){ 140, 140, 160, 255 };
    ui->barBgColor    = (Color){ 60, 60, 60, 255 };
    ui->btnHoverColor = (Color){ 255, 255, 255, 40 };

    ui->smartPlayHeld = false;
}

void ui_destroy(UIState *ui)
{
#if FONT_EMBEDDED
    UnloadFont(ui->fontSmall);
    UnloadFont(ui->font);
    UnloadFont(ui->fontMed);
    UnloadFont(ui->fontLarge);
    UnloadFont(ui->fontHelp);
#else
    (void)ui;
#endif
}

/* ------------------------------------------------------------------ */
/* Input                                                              */
/* ------------------------------------------------------------------ */

void ui_handle_input(UIState *ui, PlayerState *state, const UILayout *layout)
{
    if (!state->loaded) {
        /* Study-mode checkbox is always available */
        goto checkbox;
    }

    /* --- Play/pause button --- */
    if (button_hit(layout->btnCenterX, layout->btnY, layout->btnRadius))
    {
        if (state->playing)
            player_pause(state);
        else
            player_play(state);
    }

    /* --- Section nav buttons --- */
    {
        float progress = (state->duration > 0.0f) ? state->currentTime / state->duration : 0.0f;
        int portion = study_current_speaking_portion(state, progress) + 1;
        int total = study_total_speaking_portions(state);
        if (portion > total) portion = total;
        float secBtnRadius = 35.0f;
        float secPrevX = layout->secNavX - 65.0f;
        float secNextX = layout->secNavX + 65.0f;
        float secBtnY = layout->secNavY;

        if (button_hit(secPrevX, secBtnY, secBtnRadius))
        {
            float pos = state->currentTime / state->duration;
            int p = study_current_speaking_portion(state, pos);
            bool inSil = (study_find_silence_at(state, pos) >= 0);
            bool inPad = study_in_padding_zone(state, pos, p);
            if ((inSil || inPad) && p > 0) p--;
            float target = study_segment_seek_target(state, p);
            player_seek(state, target);
            state->wasInSilence = false;
            state->lastSilenceIdx = -1;
        }
        if (button_hit(secNextX, secBtnY, secBtnRadius))
        {
            float pos = state->currentTime / state->duration;
            int p = study_current_speaking_portion(state, pos);
            if (p < total - 1) p++;
            float target = study_segment_seek_target(state, p);
            player_seek(state, target);
            state->wasInSilence = false;
            state->lastSilenceIdx = -1;
        }
    }

    /* --- Smart play hold button --- */
    {
        Rectangle smartBtn = { layout->smartPlayX, layout->smartPlayY, 200.0f, 80.0f };
        Vector2 mouse = GetMousePosition();
        bool overBtn = (mouse.x >= smartBtn.x && mouse.x <= smartBtn.x + smartBtn.width &&
                        mouse.y >= smartBtn.y && mouse.y <= smartBtn.y + smartBtn.height);

        if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT) && overBtn) {
            ui->smartPlayHeld = true;
            if (!state->playing) {
                ResumeMusicStream(state->music);
                state->playing = true;
            }
        }

        if (IsMouseButtonDown(MOUSE_BUTTON_LEFT) && ui->smartPlayHeld) {
            /* Allow finger drift - stay held */
        }

        if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) {
            ui->smartPlayHeld = false;
        }

        if (GetTouchPointCount() > 0 && ui->smartPlayHeld) {
            /* Touch fallback: keep held while touch points active */
        }
    }

    /* --- Keyboard input --- */
    if (IsKeyPressed(KEY_C) && state->playing)
        player_pause(state);

    if (IsKeyPressed(KEY_N) && !state->playing)
    {
        float pos = state->currentTime / state->duration;
        int portion = study_current_speaking_portion(state, pos);
        float target = study_segment_seek_target(state, portion);
        player_seek(state, target);
        player_play(state);
    }

    if (IsKeyPressed(KEY_SPACE) && !state->playing)
        player_play(state);

    if (IsKeyPressed(KEY_V))
    {
        float pos = state->currentTime / state->duration;
        int portion = study_current_speaking_portion(state, pos);
        bool inSil = (study_find_silence_at(state, pos) >= 0);
        bool inPad = study_in_padding_zone(state, pos, portion);
        if ((inSil || inPad) && portion > 0)
            portion--;
        float target = study_segment_seek_target(state, portion);
        player_seek(state, target);
        state->wasInSilence = false;
        state->lastSilenceIdx = -1;
    }

    if (IsKeyPressed(KEY_B))
    {
        float pos = state->currentTime / state->duration;
        int portion = study_current_speaking_portion(state, pos);
        int total = study_total_speaking_portions(state);
        if (portion < total - 1) portion++;
        float target = study_segment_seek_target(state, portion);
        player_seek(state, target);
        state->wasInSilence = false;
        state->lastSilenceIdx = -1;
    }

    /* Click-to-seek on progress bar */
    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT))
    {
        Vector2 mouse = GetMousePosition();
        if (mouse.x >= layout->barX && mouse.x <= layout->barX + layout->barWidth &&
            mouse.y >= layout->barY && mouse.y <= layout->barY + layout->barHeight)
        {
            float target = ((mouse.x - layout->barX) / layout->barWidth) * state->duration;
            player_seek(state, target);
        }
    }

    /* Arrow key seeking */
    if (IsKeyPressed(KEY_LEFT))
        player_seek(state, state->currentTime - 5.0f);
    if (IsKeyPressed(KEY_RIGHT))
        player_seek(state, state->currentTime + 5.0f);
    if (IsKeyPressed(KEY_UP) && !state->playing)
        player_play(state);
    if (IsKeyPressed(KEY_DOWN) && state->playing)
    {
        player_pause(state);
        float rewind = state->currentTime - 1.0f;
        if (rewind < 0.0f) rewind = 0.0f;
        SeekMusicStream(state->music, rewind);
        state->currentTime = rewind;
    }

    /* Number key seeking (0-9 = 0%-90%) */
    for (int k = 0; k <= 9; k++)
    {
        if (IsKeyPressed(KEY_ZERO + k))
        {
            float target = state->duration * (k / 10.0f);
            player_seek(state, target);
            break;
        }
    }

checkbox:
    /* --- Study mode checkbox --- */
    {
        float helpSpacing = ui->szHelp * 0.03f;
        const char *label = "Study Mode";
        float cbSize = 30.0f;
        Vector2 labelSize = MeasureTextEx(ui->fontHelp, label, ui->szHelp, helpSpacing);
        float totalW = cbSize + 10 + labelSize.x;
        float cbX = SCREEN_W - totalW - layout->helpX;
        float cbY = layout->helpY + (ui->szHelp - cbSize) / 2.0f;

        if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT))
        {
            Vector2 mouse = GetMousePosition();
            if (mouse.x >= cbX && mouse.x <= cbX + totalW &&
                mouse.y >= cbY && mouse.y <= cbY + cbSize)
            {
                state->studyMode = !state->studyMode;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Rendering                                                          */
/* ------------------------------------------------------------------ */

void ui_render_player(const UIState *ui, const PlayerState *state,
                      const UILayout *layout)
{
    draw_text_centered(ui->font, state->filename, layout->titleX, layout->titleY,
                       ui->szFont, ui->mutedColor);

    /* Progress bar */
    float progress = (state->duration > 0.0f) ? state->currentTime / state->duration : 0.0f;
    if (progress > 1.0f) progress = 1.0f;

    Rectangle barBg = { layout->barX, layout->barY, layout->barWidth, layout->barHeight };
    Rectangle barFill = { layout->barX, layout->barY, layout->barWidth * progress, layout->barHeight };
    DrawRectangleRounded(barBg, 0.4f, 8, ui->barBgColor);
    if (progress > 0.001f)
        DrawRectangleRounded(barFill, 0.4f, 8, ui->accentColor);

    /* Time labels */
    char timeBuf[16];
    int elapsedSec = (int)state->currentTime;
    if (elapsedSec < 0) elapsedSec = 0;
    int totalSec = (int)state->duration;
    int remainSec = totalSec - elapsedSec;
    if (remainSec < 0) remainSec = 0;

    player_format_time((float)elapsedSec, timeBuf, sizeof(timeBuf));
    float timeFontSize = ui->szSmall;
    float timeSpacing = timeFontSize * 0.03f;
    Vector2 leftSize = MeasureTextEx(ui->fontSmall, timeBuf, timeFontSize, timeSpacing);
    DrawTextEx(ui->fontSmall, timeBuf,
               (Vector2){ layout->barX - leftSize.x - 20,
                          layout->barY + (layout->barHeight - timeFontSize) / 2.0f },
               timeFontSize, timeSpacing, ui->textColor);

    char remainBuf[16];
    player_format_time((float)remainSec, remainBuf, sizeof(remainBuf));
    float rightX = layout->barX + layout->barWidth + 20;
    DrawTextEx(ui->fontSmall, remainBuf,
               (Vector2){ rightX, layout->barY + (layout->barHeight - timeFontSize) / 2.0f },
               timeFontSize, timeSpacing, ui->textColor);

    /* Percent centered above progress bar */
    char pctBuf[16];
    int pct = (int)(progress * 100.0f);
    snprintf(pctBuf, sizeof(pctBuf), "%d%%", pct);
    bool inSilence = (study_find_silence_at(state, progress) >= 0);
    draw_text_centered(ui->fontSmall, pctBuf,
                       layout->barX + layout->barWidth / 2.0f,
                       layout->barY - timeFontSize - 10, timeFontSize, ui->textColor);

    /* Playback status */
    Color statusColor = (state->playing && inSilence)
                        ? (Color){ 160, 40, 55, 255 } : ui->accentColor;
    draw_text_centered(ui->font, state->playing ? "PLAYING" : "PAUSED",
                       layout->statusX, layout->statusY, ui->szFont, statusColor);

    /* Buttons */
    Vector2 mousePos = GetMousePosition();

    /* Play/pause button */
    Color playBtnColor = (state->playing && inSilence)
                         ? (Color){ 160, 40, 55, 255 } : ui->accentColor;
    float ppx = layout->btnCenterX;
    float pdx = mousePos.x - ppx, pdy = mousePos.y - layout->btnY;
    bool hoverPP = (pdx*pdx + pdy*pdy) <= ((layout->btnRadius+5)*(layout->btnRadius+5));
    DrawCircle((int)ppx, (int)layout->btnY, layout->btnRadius + 8, playBtnColor);
    if (hoverPP) DrawCircle((int)ppx, (int)layout->btnY, layout->btnRadius + 8, ui->btnHoverColor);
    if (state->playing)
        draw_pause_icon(ppx, layout->btnY, 50, ui->textColor);
    else
        draw_play_icon(ppx, layout->btnY, 50, ui->textColor);

    /* Speaking portion counter with prev/next section buttons */
    {
        int portion = study_current_speaking_portion(state, progress) + 1;
        int total = study_total_speaking_portions(state);
        if (portion > total) portion = total;
        char portionBuf[32];
        snprintf(portionBuf, sizeof(portionBuf), "%d/%d", portion, total);
        float secBtnRadius = 35.0f;
        float portionY = layout->secNavY - ui->szSmall - secBtnRadius - 10.0f;
        float portionSpacing = ui->szSmall * 0.03f;
        Vector2 portionSize = MeasureTextEx(ui->fontSmall, portionBuf, ui->szSmall, portionSpacing);
        float portionX = layout->secNavX - portionSize.x / 2.0f;
        DrawTextEx(ui->fontSmall, portionBuf,
                   (Vector2){ portionX, portionY },
                   ui->szSmall, portionSpacing, ui->mutedColor);

        /* Section nav buttons */
        float secPrevX = layout->secNavX - 65.0f;
        float secNextX = layout->secNavX + 65.0f;
        float secBtnY_draw = layout->secNavY;

        float sd3 = mousePos.x - secPrevX, sd4 = mousePos.y - secBtnY_draw;
        bool hoverSecPrev = (sd3*sd3 + sd4*sd4) <= (secBtnRadius*secBtnRadius);
        DrawCircle((int)secPrevX, (int)secBtnY_draw, secBtnRadius, (Color){ 50, 50, 70, 255 });
        if (hoverSecPrev) DrawCircle((int)secPrevX, (int)secBtnY_draw, secBtnRadius, ui->btnHoverColor);
        draw_seek_back_icon(secPrevX, secBtnY_draw, 30, ui->textColor);

        float sd5 = mousePos.x - secNextX, sd6 = mousePos.y - secBtnY_draw;
        bool hoverSecNext = (sd5*sd5 + sd6*sd6) <= (secBtnRadius*secBtnRadius);
        DrawCircle((int)secNextX, (int)secBtnY_draw, secBtnRadius, (Color){ 50, 50, 70, 255 });
        if (hoverSecNext) DrawCircle((int)secNextX, (int)secBtnY_draw, secBtnRadius, ui->btnHoverColor);
        draw_seek_fwd_icon(secNextX, secBtnY_draw, 30, ui->textColor);
    }

    /* --- Smart play hold button rendering --- */
    {
        Rectangle smartBtn = { layout->smartPlayX, layout->smartPlayY, 200.0f, 80.0f };
        Color btnFill = ui->smartPlayHeld ? (Color){ 80, 30, 50, 220 } : (Color){ 50, 50, 70, 180 };
        Color btnBorder = ui->smartPlayHeld ? ui->accentColor : ui->mutedColor;
        Color btnTextColor = ui->smartPlayHeld ? ui->accentColor : ui->textColor;
        DrawRectangleRounded(smartBtn, 0.3f, 8, btnFill);
        DrawRectangleRoundedLines(smartBtn, 0.3f, 8, btnBorder);
        float btnSpacing = ui->szSmall * 0.03f;
        Vector2 btnSize = MeasureTextEx(ui->fontSmall, "Play", ui->szSmall, btnSpacing);
        float tx = smartBtn.x + (smartBtn.width - btnSize.x) / 2.0f;
        float ty = smartBtn.y + (smartBtn.height - ui->szSmall) / 2.0f;
        DrawTextEx(ui->fontSmall, "Play", (Vector2){ tx, ty }, ui->szSmall, btnSpacing, btnTextColor);
    }
}

void ui_render_empty(const UIState *ui, const UILayout *layout)
{
    draw_text_centered(ui->fontLarge, "Study Player",
                       layout->titleX, layout->titleY, ui->szLarge, ui->textColor);
#ifdef PLATFORM_WEB
    draw_text_centered(ui->fontMed, "Use Load MP3 button above",
                       (float)SCREEN_W / 2.0f, SCREEN_H / 2.0f - 20, ui->szMed, ui->mutedColor);
#else
    draw_text_centered(ui->fontMed, "Drag an MP3 file here",
                       (float)SCREEN_W / 2.0f, SCREEN_H / 2.0f - 20, ui->szMed, ui->mutedColor);
#endif
}

void ui_render_overlay(const UIState *ui, const PlayerState *state,
                       const UILayout *layout)
{
    /* --- Help text --- */
    float helpSpacing = ui->szHelp * 0.03f;
    DrawTextEx(ui->fontHelp,
               "C: pause  N: play  Space(hold): override  V/B: prev/next  Arrows: seek  0-9: jump",
               (Vector2){ layout->helpX, layout->helpY },
               ui->szHelp, helpSpacing, ui->mutedColor);

    /* --- Study mode checkbox --- */
    const char *label = "Study Mode";
    float cbSize = 30.0f;
    Vector2 labelSize = MeasureTextEx(ui->fontHelp, label, ui->szHelp, helpSpacing);
    float totalW = cbSize + 10 + labelSize.x;
    float cbX = SCREEN_W - totalW - layout->helpX;
    float cbY = layout->helpY + (ui->szHelp - cbSize) / 2.0f;

    Rectangle cbRect = { cbX, cbY, cbSize, cbSize };
    DrawRectangleLinesEx(cbRect, 2, ui->mutedColor);
    if (state->studyMode)
        DrawRectangleRec((Rectangle){ cbX + 6, cbY + 6, cbSize - 12, cbSize - 12 }, ui->accentColor);
    DrawTextEx(ui->fontHelp, label,
               (Vector2){ cbX + cbSize + 10, layout->helpY },
               ui->szHelp, helpSpacing, ui->mutedColor);
}
