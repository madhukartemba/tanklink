#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "tanklink_ble_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_ble_token_init(void);
const uint8_t *tank_ble_token_bytes(void);
bool tank_ble_token_check(const uint8_t *token, size_t len);

#ifdef __cplusplus
}
#endif
