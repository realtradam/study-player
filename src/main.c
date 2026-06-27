/* main.c — composition root.
 *
 * Owns: window/audio init, main loop, tab switching + config save,
 * drag-drop / web file loading, platform glue.
 * Delegates to: player, study, ui, config, layout_editor. */

#define _POSIX_C_SOURCE 200809L

#include "raylib.h"
#include "raygui.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "config.h"
#include "layout_editor.h"
#include "player.h"
#include "study.h"
#include "ui.h"

#ifdef PLATFORM_LINUX
#include <unistd.h>
#endif
#ifdef PLATFORM_WEB
#include <emscripten/emscripten.h>
#endif

/* ------------------------------------------------------------------ */
/* Shared state (needed for emscripten main loop callback)            */
/* ------------------------------------------------------------------ */

static PlayerState state = { 0 };
static UIState     ui;
static UILayout    layout;
static char        exeDir[512];
static int         activeTab = 0;
static int         prevTab   = 0;

/* --- Screenshot mode (env: STUDY_PLAYER_SCREENSHOT=filename) --- */
static const char *screenshotFile = NULL;
static int         screenshotFrameCount = 0;
#define SCREENSHOT_DELAY_FRAMES 60  /* ~1 second at 60fps for window to fully map */

/* ------------------------------------------------------------------ */
/* File loading (drag-drop desktop / JS callback web)                  */
/* ------------------------------------------------------------------ */

static void load_audio_file(const char *path)
{
    if (!player_load(&state, path)) return;

    /* Detect silence regions (threshold: 0.015, min duration: 0.75s) */
    study_detect_silence(path, &state, 0.015f, 0.75f);

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

/* ------------------------------------------------------------------ */
/* Main loop body (one frame)                                         */
/* ------------------------------------------------------------------ */

static void update_frame(void)
{
    /* --- Drag & drop file loading (desktop only) --- */
#ifndef PLATFORM_WEB
    if (IsFileDropped())
    {
        FilePathList files = LoadDroppedFiles();
        if (files.count > 0)
            load_audio_file(files.paths[0]);
        UnloadDroppedFiles(files);
    }
#endif

    /* --- Input (player tab only) --- */
    if (activeTab == 0)
        ui_handle_input(&ui, &state, &layout);

    /* --- Music stream update + study auto-pause --- */
    if (state.loaded)
    {
        player_update(&state);
        if (state.studyMode && state.playing)
            study_auto_pause_check(&state, ui.smartPlayHeld, IsKeyDown(KEY_SPACE));
    }

    /* --- Save layout on tab switch --- */
    if (prevTab == 1 && activeTab == 0)
        config_save(exeDir, &layout);
    prevTab = activeTab;

    /* --- Drawing --- */
    BeginDrawing();
    ClearBackground(ui.bgColor);

    char *tabNames[] = { "Player", "Layout" };
    GuiTabBar((Rectangle){ 0, 10, SCREEN_W, 32 }, tabNames, 2, &activeTab);

    if (activeTab == 0) {
        if (state.loaded)
            ui_render_player(&ui, &state, &layout);
        else
            ui_render_empty(&ui, &layout);
        ui_render_overlay(&ui, &state, &layout);
    } else {
        layout_editor_draw(exeDir, &layout);
    }

    EndDrawing();

    /* --- Screenshot mode: render to FBO, save as PNG, then exit --- */
    if (screenshotFile) {
        screenshotFrameCount++;
        if (screenshotFrameCount >= SCREENSHOT_DELAY_FRAMES) {
            RenderTexture2D target = LoadRenderTexture(SCREEN_W, SCREEN_H);
            BeginTextureMode(target);
                ClearBackground(ui.bgColor);
                /* Explicitly fill the entire texture with bg color + alpha 255 */
                DrawRectangle(0, 0, SCREEN_W, SCREEN_H, ui.bgColor);
                char *tabNames2[] = { "Player", "Layout" };
                GuiTabBar((Rectangle){ 0, 10, SCREEN_W, 32 }, tabNames2, 2, &activeTab);
                if (state.loaded)
                    ui_render_player(&ui, &state, &layout);
                else
                    ui_render_empty(&ui, &layout);
                ui_render_overlay(&ui, &state, &layout);
            EndTextureMode();

            /* Read from the render texture — it has proper content */
            Image img = LoadImageFromTexture(target.texture);
            ImageFlipVertical(&img);
            /* ClearBackground doesn't fill FBO alpha on some Mesa drivers.
             * Manually replace all transparent (alpha=0) pixels with the
             * background color, so the saved PNG has a proper background. */
            if (img.format == PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) {
                unsigned char *px = (unsigned char *)img.data;
                for (int i = 0; i < img.width * img.height * 4; i += 4) {
                    if (px[i+3] == 0) {
                        px[i]   = ui.bgColor.r;
                        px[i+1] = ui.bgColor.g;
                        px[i+2] = ui.bgColor.b;
                        px[i+3] = 255;
                    }
                }
            }
            ExportImage(img, screenshotFile);
            UnloadImage(img);
            UnloadRenderTexture(target);
            screenshotFile = NULL;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Entry point                                                       */
/* ------------------------------------------------------------------ */

int main(void)
{
    InitWindow(SCREEN_W, SCREEN_H, "Study Player");
    InitAudioDevice();
    SetTargetFPS(60);

    /* --- Screenshot mode (env-controlled, for automated testing) --- */
    screenshotFile = getenv("STUDY_PLAYER_SCREENSHOT");
    if (screenshotFile)
        MaximizeWindow();  /* force window to be mapped/visible */

    ui_init(&ui);

    memset(&state, 0, sizeof(state));
    state.studyMode = true;
    state.lastSilenceIdx = -1;

    /* Determine executable directory (for config load/save) */
    {
        char exePath[512] = {0};
#ifdef PLATFORM_LINUX
        readlink("/proc/self/exe", exePath, sizeof(exePath) - 1);
#endif
        config_load(exePath, &layout);

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

        layout_editor_init();
    }

#ifdef PLATFORM_WEB
    emscripten_set_main_loop(update_frame, 0, 1);
#else
    while (!WindowShouldClose()) {
        update_frame();
        if (screenshotFile == NULL && screenshotFrameCount >= SCREENSHOT_DELAY_FRAMES)
            break;  /* screenshot taken, exit */
    }
#endif

    player_unload(&state);
    ui_destroy(&ui);
    CloseAudioDevice();
    CloseWindow();

    return 0;
}
