#pragma once

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

int config_load(const char *exePath, UILayout *layout);
int config_save(const char *exePath, const UILayout *layout);
