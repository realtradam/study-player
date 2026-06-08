#pragma once

typedef struct {
    float titleY;
    float barY;
    float barHeight;
    float barWidth;
    float barX;
    float statusY;
    float btnRadius;
    float helpY;
    float btnY;
    float btnCenterX;
    float smartPlayY;
    float secNavY;
} UILayout;

int config_load(const char *exePath, UILayout *layout);
int config_save(const char *exePath, const UILayout *layout);
