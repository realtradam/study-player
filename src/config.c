#include "config.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifdef PLATFORM_LINUX
#include <unistd.h>
#endif

#define CONFIG_FILENAME "study-player.cfg"
#define MAX_LINE 256

static void set_defaults(UILayout *layout)
{
    layout->titleY     = 60.0f;
    layout->barY       = 460.0f;
    layout->barHeight  = 50.0f;
    layout->barWidth   = 1920.0f * 0.65f;
    layout->btnRadius  = 55.0f;
    layout->helpY      = 1080.0f - 80.0f;
    layout->btnCenterX = 1920.0f / 2.0f;

    layout->barX    = (1920.0f - layout->barWidth) / 2.0f;
    layout->statusY = layout->barY + layout->barHeight + 30.0f;
    layout->btnY    = layout->statusY + 120.0f + 55.0f;
    layout->smartPlayY = 1080.0f - 80.0f - 120.0f;
    layout->secNavY    = layout->btnY + 55.0f + 80.0f + 30.0f;
}

static void chomp(char *line)
{
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
        line[--len] = '\0';
}

static const char *dirname_of(const char *path, char *buf, size_t bufsize)
{
    const char *lastSep = NULL;
    for (const char *p = path; *p; p++)
        if (*p == '/') lastSep = p;

    if (!lastSep)
    {
        buf[0] = '.';
        buf[1] = '\0';
        return buf;
    }

    size_t dirlen = (size_t)(lastSep - path);
    if (dirlen >= bufsize) dirlen = bufsize - 1;
    memcpy(buf, path, dirlen);
    buf[dirlen] = '\0';
    return buf;
}

static void build_config_path(const char *exePath, char *out, size_t outSize)
{
    char dir[512];
    dirname_of(exePath, dir, sizeof(dir));
    snprintf(out, outSize, "%s/%s", dir, CONFIG_FILENAME);
}

static float parse_float(const char *s)
{
    char *end;
    float val = strtof(s, &end);
    if (end == s) return -1.0f;
    return val;
}

static int parse_config(const char *path, UILayout *layout)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;

    char line[MAX_LINE];
    int loaded = 0;

    while (fgets(line, sizeof(line), fp))
    {
        chomp(line);

        if (line[0] == '#' || line[0] == '\0')
            continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        const char *key = line;
        const char *val = eq + 1;

        float f = parse_float(val);
        if (f < 0.0f) continue;

        if (strcmp(key, "title_y") == 0)       layout->titleY = f;
        else if (strcmp(key, "bar_y") == 0)    layout->barY = f;
        else if (strcmp(key, "bar_height") == 0) layout->barHeight = f;
        else if (strcmp(key, "bar_width") == 0)  layout->barWidth = f;
        else if (strcmp(key, "btn_radius") == 0) layout->btnRadius = f;
        else if (strcmp(key, "help_y") == 0)     layout->helpY = f;
        else if (strcmp(key, "btn_y") == 0)      layout->btnY = f;
        else if (strcmp(key, "btn_center_x") == 0) layout->btnCenterX = f;
        else if (strcmp(key, "smart_play_y") == 0) layout->smartPlayY = f;
        else if (strcmp(key, "sec_nav_y") == 0)    layout->secNavY = f;

        loaded = 1;
    }

    fclose(fp);

    layout->barX    = (1920.0f - layout->barWidth) / 2.0f;
    layout->statusY = layout->barY + layout->barHeight + 30.0f;

    return loaded;
}

int config_load(const char *exePath, UILayout *layout)
{
    set_defaults(layout);

    char cfgPath[1024];
    build_config_path(exePath, cfgPath, sizeof(cfgPath));

    int loaded = parse_config(cfgPath, layout);
    layout->barX    = (1920.0f - layout->barWidth) / 2.0f;
    layout->statusY = layout->barY + layout->barHeight + 30.0f;
    return loaded;
}

int config_save(const char *exePath, const UILayout *layout)
{
    char cfgPath[1024];
    build_config_path(exePath, cfgPath, sizeof(cfgPath));

    FILE *fp = fopen(cfgPath, "w");
    if (!fp) return 0;

    fprintf(fp, "# Study Player layout config\n");
    fprintf(fp, "title_y=%.2f\n", layout->titleY);
    fprintf(fp, "bar_y=%.2f\n", layout->barY);
    fprintf(fp, "bar_height=%.2f\n", layout->barHeight);
    fprintf(fp, "bar_width=%.2f\n", layout->barWidth);
    fprintf(fp, "btn_radius=%.2f\n", layout->btnRadius);
    fprintf(fp, "help_y=%.2f\n", layout->helpY);
    fprintf(fp, "btn_y=%.2f\n", layout->btnY);
    fprintf(fp, "btn_center_x=%.2f\n", layout->btnCenterX);
    fprintf(fp, "smart_play_y=%.2f\n", layout->smartPlayY);
    fprintf(fp, "sec_nav_y=%.2f\n", layout->secNavY);
    fclose(fp);
    return 1;
}
