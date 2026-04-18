#include "raylib.h"
#include <string.h>
#include <ctype.h>

typedef struct {
    Music music;
    bool loaded;
    bool playing;
    float duration;
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
}

int main(void)
{
    InitWindow(1920, 1080, "Study Player");
    InitAudioDevice();
    SetTargetFPS(60);

    PlayerState state = { 0 };

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
                    /* Unload previous */
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
                }
            }
            UnloadDroppedFiles(files);
        }

        /* --- 1.4 Music stream update --- */
        if (state.loaded)
        {
            UpdateMusicStream(state.music);
        }

        /* --- 1.2 Play/pause with rewind --- */
        if (state.loaded && IsKeyPressed(KEY_SPACE))
        {
            if (state.playing)
            {
                float pos = GetMusicTimePlayed(state.music);
                PauseMusicStream(state.music);
                float rewind = pos - 1.0f;
                if (rewind < 0.0f) rewind = 0.0f;
                SeekMusicStream(state.music, rewind);
                state.playing = false;
            }
            else
            {
                ResumeMusicStream(state.music);
                state.playing = true;
            }
        }

        /* --- 1.3 Arrow key seeking --- */
        if (state.loaded && IsKeyPressed(KEY_LEFT))
        {
            float pos = GetMusicTimePlayed(state.music);
            seek_to(&state, pos - 5.0f);
        }
        if (state.loaded && IsKeyPressed(KEY_RIGHT))
        {
            float pos = GetMusicTimePlayed(state.music);
            seek_to(&state, pos + 5.0f);
        }

        /* --- Drawing --- */
        BeginDrawing();
        ClearBackground((Color){ 26, 26, 46, 255 });

        if (state.loaded)
        {
DrawText(state.filename, 40, 40, 40, RAYWHITE);
DrawText(state.playing ? "Playing" : "Paused", 40, 90, 30, GRAY);
        }
        else
        {
DrawText("Drop an MP3 file here to play", 540, 340, 40, RAYWHITE);
        }

        EndDrawing();
    }

    if (state.loaded)
    {
        StopMusicStream(state.music);
        UnloadMusicStream(state.music);
    }

    CloseAudioDevice();
    CloseWindow();

    return 0;
}
