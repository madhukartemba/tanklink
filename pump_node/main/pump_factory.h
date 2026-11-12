#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Factory reset: stop pump, clear BLE pairing + tank bind, restore config
 * defaults, show LED cue, then reboot. Safe to call from button or BLE cmd.
 */
esp_err_t pump_factory_reset(void);

#ifdef __cplusplus
}
#endif
