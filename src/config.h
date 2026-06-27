#pragma once

/* config.h — UI layout persistence contract.
 *
 * Owns: loading/saving UILayout to study-player.cfg.
 * UILayout itself lives in types.h (the shared-types header). */

#include "types.h"

/* Load layout from <exeDir>/study-player.cfg; returns 1 if loaded, 0 if
 * the file was missing or unreadable (defaults are applied either way). */
int config_load(const char *exePath, UILayout *layout);

/* Save layout to <exeDir>/study-player.cfg; returns 1 on success. */
int config_save(const char *exePath, const UILayout *layout);
