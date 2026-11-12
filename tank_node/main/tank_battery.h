#pragma once

#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_battery_init(void);
/** Estimate 0-100 from LiPo divider on BAT ADC GPIO. */
uint8_t tank_battery_percent(void);

#ifdef __cplusplus
}
#endif
