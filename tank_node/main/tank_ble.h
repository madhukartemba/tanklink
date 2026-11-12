#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_ble_init(void);

/**
 * Start advertising for OTA immediately (non-blocking).
 * Call tank_ble_wait_ota_window() after any other work (e.g. LoRa TX).
 */
esp_err_t tank_ble_start_ota_window(uint32_t timeout_ms);

/**
 * Block until OTA window ends, transfer finishes/reboots, or hold-to-pair.
 * Returns ESP_ERR_INVALID_STATE if hold-to-pair was requested.
 */
esp_err_t tank_ble_wait_ota_window(void);

/** Convenience: start + wait. */
esp_err_t tank_ble_run_ota_window(uint32_t timeout_ms);

bool tank_ble_ota_busy(void);
/** Stop advertising / abort OTA window (stack stays up). */
void tank_ble_stop(void);
/** Tear down NimBLE + BT controller before deep sleep (~mA → µA). */
void tank_ble_deinit(void);

#ifdef __cplusplus
}
#endif
