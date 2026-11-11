#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t pump_ota_init(void);

bool pump_ota_is_active(void);

/** START: size + 32-byte SHA-256. Returns OTA error code (TANKLINK_OTA_ERR_*). */
uint8_t pump_ota_start(uint32_t image_size, const uint8_t sha256[32]);

/** Write sequential chunk at expected offset. */
uint8_t pump_ota_write(uint32_t offset, const uint8_t *data, uint16_t len);

uint8_t pump_ota_abort(void);

/** Verify hash, set boot partition, schedule reboot. */
uint8_t pump_ota_finish(void);

uint8_t pump_ota_state(void);
uint8_t pump_ota_last_error(void);
uint32_t pump_ota_offset(void);

typedef void (*pump_ota_status_cb_t)(void);
void pump_ota_set_status_cb(pump_ota_status_cb_t cb);

#ifdef __cplusplus
}
#endif
