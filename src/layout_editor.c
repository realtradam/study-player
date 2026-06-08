#include "layout_editor.h"
#include "raylib.h"

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#define RAYGUI_IMPLEMENTATION
#include "raygui.h"
#pragma GCC diagnostic pop

#define TITLE_W     400.0f
#define TITLE_H     70.0f
#define TIME_W      80.0f
#define PCT_W       60.0f
#define PCT_H       30.0f
#define STATUS_W    120.0f
#define STATUS_H    40.0f
#define HELP_W      600.0f
#define HELP_H      30.0f

static int   dragIndex  = -1;
static float dragOffsetX = 0.0f;
static float dragOffsetY = 0.0f;

void layout_editor_init(void)
{
    GuiLoadStyleDefault();
}

static Color fillColor     = {  60,  60,  80, 100 };
static Color borderColor   = { 180, 180, 200, 200 };
static Color highlightColor = { 233,  69,  96, 150 };
static Color labelColor    = { 234, 234, 234, 255 };
static const int labelFontSize = 20;

static void draw_label(const char *text, Rectangle r, Color fill, Color border)
{
    DrawRectangleRec(r, fill);
    DrawRectangleLinesEx(r, 2.0f, border);
    int textY = (int)(r.y + r.height / 2.0f - (float)labelFontSize / 2.0f);
    DrawText(text, (int)r.x + 10, textY, labelFontSize, labelColor);
}

void layout_editor_draw(const char *exePath, UILayout *layout)
{
    (void)exePath;

    int   screenW = GetScreenWidth();
    Vector2 mouse  = GetMousePosition();

    /* --- Hit detection on press --- */
    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) {
        dragIndex = -1;

        /* Check element 4 first (Help), then 3, 2, 1, 0.
           Later checks overwrite earlier ones if they overlap —
           priority goes to elements drawn last / on top. */

        /* 4: Help */
        {
            Rectangle r = { 40.0f, layout->helpY, HELP_W, HELP_H };
            if (CheckCollisionPointRec(mouse, r)) {
                dragIndex  = 4;
                dragOffsetY = mouse.y - layout->helpY;
            }
        }

        /* 3: Play button (circle) */
        {
            float dx = mouse.x - layout->btnCenterX;
            float dy = mouse.y - layout->btnY;
            if (dx * dx + dy * dy <= layout->btnRadius * layout->btnRadius) {
                dragIndex  = 3;
                dragOffsetX = mouse.x - layout->btnCenterX;
                dragOffsetY = mouse.y - layout->btnY;
            }
        }

        /* 2: Status */
        {
            Rectangle r = { (float)screenW / 2.0f - STATUS_W / 2.0f,
                           layout->statusY, STATUS_W, STATUS_H };
            if (CheckCollisionPointRec(mouse, r)) {
                dragIndex  = 2;
                dragOffsetY = mouse.y - layout->statusY;
            }
        }

        /* 1: Bar group (bar + time labels + percentage) */
        {
            float gx = layout->barX - 90.0f;
            float gw = layout->barWidth + 10.0f + 80.0f + 90.0f;
            float gy = layout->barY - 40.0f;
            float gh = layout->barHeight + 40.0f;
            Rectangle group = { gx, gy, gw, gh };
            if (CheckCollisionPointRec(mouse, group)) {
                dragIndex  = 1;
                dragOffsetX = mouse.x - layout->barX;
                dragOffsetY = mouse.y - layout->barY;
            }
        }

        /* 0: Title */
        {
            Rectangle r = { (float)screenW / 2.0f - TITLE_W / 2.0f,
                           layout->titleY, TITLE_W, TITLE_H };
            if (CheckCollisionPointRec(mouse, r)) {
                dragIndex  = 0;
                dragOffsetY = mouse.y - layout->titleY;
            }
        }
    }

    /* --- Drag update --- */
    if (IsMouseButtonDown(MOUSE_BUTTON_LEFT) && dragIndex >= 0) {
        switch (dragIndex) {
        case 0: /* Title */
            layout->titleY = mouse.y - dragOffsetY;
            break;
        case 1: /* Bar group */
            layout->barX = mouse.x - dragOffsetX;
            layout->barY = mouse.y - dragOffsetY;
            break;
        case 2: /* Status */
            layout->statusY = mouse.y - dragOffsetY;
            break;
        case 3: /* Play button */
            layout->btnCenterX = mouse.x - dragOffsetX;
            layout->btnY       = mouse.y - dragOffsetY;
            break;
        case 4: /* Help */
            layout->helpY = mouse.y - dragOffsetY;
            break;
        }
    }

    /* --- Release --- */
    if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) {
        dragIndex = -1;
    }

    Color barFill = (dragIndex == 1) ? highlightColor : fillColor;

    /* --- 0: Title --- */
    {
        Color f = (dragIndex == 0) ? highlightColor : fillColor;
        Rectangle r = { (float)screenW / 2.0f - TITLE_W / 2.0f,
                       layout->titleY, TITLE_W, TITLE_H };
        draw_label("Title", r, f, borderColor);
    }

    /* --- 1: Bar group --- */
    /* Percentage above bar (centered on bar's X) */
    {
        Rectangle r = { layout->barX + layout->barWidth / 2.0f - PCT_W / 2.0f,
                       layout->barY - 40.0f, PCT_W, PCT_H };
        draw_label("%", r, barFill, borderColor);
    }
    /* Elapsed time */
    {
        Rectangle r = { layout->barX - 90.0f, layout->barY,
                       TIME_W, layout->barHeight };
        draw_label("Time", r, barFill, borderColor);
    }
    /* Bar */
    {
        Rectangle r = { layout->barX, layout->barY,
                       layout->barWidth, layout->barHeight };
        draw_label("Bar", r, barFill, borderColor);
    }
    /* Remaining time */
    {
        Rectangle r = { layout->barX + layout->barWidth + 10.0f,
                       layout->barY, TIME_W, layout->barHeight };
        draw_label("Time", r, barFill, borderColor);
    }

    /* --- 2: Status --- */
    {
        Color f = (dragIndex == 2) ? highlightColor : fillColor;
        Rectangle r = { (float)screenW / 2.0f - STATUS_W / 2.0f,
                       layout->statusY, STATUS_W, STATUS_H };
        draw_label("Status", r, f, borderColor);
    }

    /* --- 3: Play button --- */
    {
        float cx = layout->btnCenterX;
        float cy = layout->btnY;
        float r  = layout->btnRadius;
        Color  f = (dragIndex == 3) ? highlightColor : fillColor;
        DrawCircle((int)cx, (int)cy, r, f);
        DrawCircleLines((int)cx, (int)cy, r, borderColor);
        float half = r * 0.5f;
        Vector2 v1 = { cx - half * 0.7f, cy - half };
        Vector2 v2 = { cx - half * 0.7f, cy + half };
        Vector2 v3 = { cx + half * 0.8f, cy };
        DrawTriangle(v1, v2, v3, labelColor);
    }

    /* --- 4: Help --- */
    {
        Color f = (dragIndex == 4) ? highlightColor : fillColor;
        Rectangle r = { 40.0f, layout->helpY, HELP_W, HELP_H };
        draw_label("Help", r, f, borderColor);
    }
}
