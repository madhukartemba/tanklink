#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_ble_init(void);
/** Advertise for OTA until timeout_ms, connection+OTA finishes, or abort. */
esp_err_t tank_ble_run_ota_window(uint32_t timeout_ms);
bool tank_ble_ota_busy(void);
void tank_ble_stop(void);

#ifdef __cplusplus
}
#endif
