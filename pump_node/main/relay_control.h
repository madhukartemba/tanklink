#pragma once

#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Stub: starter relay driver (not wired yet). */
esp_err_t relay_control_init(void);
void relay_control_set_running(bool on);

#ifdef __cplusplus
}
#endif
