#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Factory reset: stop the pump, erase all saved data (the whole NVS
 * partition), show the LED cue, then restart. Safe from the button or a command.
 */
esp_err_t pump_factory_reset(void);

#ifdef __cplusplus
}
#endif
