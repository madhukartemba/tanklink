#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t pump_ota_init(void);

bool pump_ota_is_active(void);

/** START from a specific BLE connection: size + 32-byte SHA-256. */
uint8_t pump_ota_start(uint16_t conn_handle, uint32_t image_size, const uint8_t sha256[32]);

/** Write sequential chunk at expected offset (owner conn only). */
uint8_t pump_ota_write(uint16_t conn_handle, uint32_t offset, const uint8_t *data, uint16_t len);

/** Abort from owner conn, or any caller when idle. */
uint8_t pump_ota_abort_from(uint16_t conn_handle);

/** Internal abort (e.g. host reset) — no owner check. */
uint8_t pump_ota_abort(void);

/** Verify hash, set boot partition, schedule reboot (owner conn only). */
uint8_t pump_ota_finish(uint16_t conn_handle);

/** If the OTA owner disconnects, abort the transfer. */
void pump_ota_on_disconnect(uint16_t conn_handle);

uint8_t pump_ota_state(void);
uint8_t pump_ota_last_error(void);
uint32_t pump_ota_offset(void);

typedef void (*pump_ota_status_cb_t)(void);
void pump_ota_set_status_cb(pump_ota_status_cb_t cb);

#ifdef __cplusplus
}
#endif
