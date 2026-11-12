#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_ota_init(void);
bool tank_ota_is_active(void);
uint8_t tank_ota_start(uint16_t conn_handle, uint32_t image_size, const uint8_t sha256[32]);
uint8_t tank_ota_write(uint16_t conn_handle, uint32_t offset, const uint8_t *data, uint16_t len);
uint8_t tank_ota_abort(void);
uint8_t tank_ota_abort_from(uint16_t conn_handle);
uint8_t tank_ota_finish(uint16_t conn_handle);
void tank_ota_on_disconnect(uint16_t conn_handle);
uint8_t tank_ota_state(void);
uint8_t tank_ota_last_error(void);
uint32_t tank_ota_offset(void);

typedef void (*tank_ota_status_cb_t)(void);
void tank_ota_set_status_cb(tank_ota_status_cb_t cb);

#ifdef __cplusplus
}
#endif
