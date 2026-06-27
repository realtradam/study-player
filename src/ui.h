#pragma once

/* ui.h — rendering and input contract.
 *
 * Owns: font/color initialization, all drawing, all mouse/keyboard input
 * for the player tab, the smart-play hold button, study-mode checkbox.
 * Does NOT own: tab bar (drawn by main via raygui), layout editor tab,
 * drag-drop file loading (main), config save on tab switch (main). */

#include "types.h"
#include "config.h"

/* ------------------------------------------------------------------ */
/* UI state — fonts, colors, interaction flags.                       */
/* ------------------------------------------------------------------ */

typedef struct {
    /* Fonts (loaded in ui_init, unloaded in ui_destroy) */
    Font fontSmall, font, fontMed, fontLarge, fontHelp;
    float szSmall, szHelp, szFont, szMed, szLarge;

    /* Colors */
    Color bgColor;
    Color textColor;
    Color accentColor;
    Color mutedColor;
    Color barBgColor;
    Color btnHoverColor;

    /* Interaction state */
    bool smartPlayHeld;
} UIState;

/* ------------------------------------------------------------------ */
/* Lifecycle                                                          */
/* ------------------------------------------------------------------ */

/* Load fonts (embedded or default) and set colors. Call after InitWindow. */
void ui_init(UIState *ui);

/* Unload fonts (embedded only). Call before CloseWindow. */
void ui_destroy(UIState *ui);

/* ------------------------------------------------------------------ */
/* Input — call once per frame BEFORE player_update, only on tab 0.   */
/* Processes button clicks, keyboard, click-to-seek, smart-play hold, */
/* study-mode checkbox toggle. Mutates state and ui->smartPlayHeld.   */
/* ------------------------------------------------------------------ */

void ui_handle_input(UIState *ui, PlayerState *state, const UILayout *layout);

/* ------------------------------------------------------------------ */
/* Rendering — call inside BeginDrawing/EndDrawing, only on tab 0.    */
/* ------------------------------------------------------------------ */

/* Draw the player UI (filename, progress bar, buttons, help, checkbox).
 * Call when state->loaded is true. */
void ui_render_player(const UIState *ui, const PlayerState *state,
                      const UILayout *layout);

/* Draw the "no file loaded" splash screen. */
void ui_render_empty(const UIState *ui, const UILayout *layout);

/* Draw the help text and study-mode checkbox (always visible on tab 0).
 * Call after ui_render_player or ui_render_empty. */
void ui_render_overlay(const UIState *ui, const PlayerState *state,
                       const UILayout *layout);
