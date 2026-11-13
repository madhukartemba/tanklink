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

typedef enum {
    TANK_BLE_WINDOW_DONE = 0,  /* advertise window ended */
    TANK_BLE_WINDOW_PAIR,      /* hold → leave for LoRa pairing */
    TANK_BLE_WINDOW_CLICK,     /* short press → send LoRa again; window stays up */
} tank_ble_window_result_t;

/**
 * Block until the advertise window ends, a short press, or hold-to-pair.
 * A short press does not stop advertising.
 */
tank_ble_window_result_t tank_ble_wait_ota_window(void);

/** Convenience: start + wait once. */
tank_ble_window_result_t tank_ble_run_ota_window(uint32_t timeout_ms);

bool tank_ble_ota_busy(void);
/** Stop advertising / abort OTA window (stack stays up). */
void tank_ble_stop(void);
/** Tear down NimBLE + BT controller before deep sleep (~mA → µA). */
void tank_ble_deinit(void);

#ifdef __cplusplus
}
#endif
