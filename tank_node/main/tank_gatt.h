#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "host/ble_hs.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_gatt_init(void);
void tank_gatt_on_connect(uint16_t conn_handle);
void tank_gatt_on_disconnect(uint16_t conn_handle);
void tank_gatt_on_subscribe(uint16_t conn_handle, uint16_t attr_handle, bool notify);
bool tank_gatt_is_authed_conn(uint16_t conn_handle);
int tank_gatt_conn_count(void);
void tank_gatt_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg);

#ifdef __cplusplus
}
#endif
