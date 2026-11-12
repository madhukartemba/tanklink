#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "host/ble_hs.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Max simultaneous BLE centrals (must match CONFIG_BT_NIMBLE_MAX_CONNECTIONS). */
#define TANKLINK_MAX_BLE_CONN 5

int gatt_svr_init(void);
void gatt_svr_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg);

void gatt_svr_on_connect(uint16_t conn_handle);
void gatt_svr_on_disconnect(uint16_t conn_handle);
int gatt_svr_conn_count(void);
bool gatt_svr_is_authed_conn(uint16_t conn_handle);
bool gatt_svr_is_authed(void);
bool gatt_svr_is_connected(void);

uint8_t gatt_svr_pump_state(void);
void gatt_svr_set_pump_state(uint8_t on);
/** Same as set_pump_state but skips the on-pump buzzer (button already clicked). */
void gatt_svr_set_pump_state_silent(uint8_t on);
void gatt_svr_toggle_pump(void);
void gatt_svr_notify_state_if_subscribed(void);
void gatt_svr_notify_tank_if_subscribed(void);

/** Last pump NeoPixel / start-deny error (see pump_errors.h). */
uint8_t gatt_svr_last_error(void);
void gatt_svr_set_last_error(uint8_t code);
void gatt_svr_clear_last_error(void);

/** Call ~1 Hz: enforces auto-off while pump is running. */
void gatt_svr_poll(void);

uint32_t gatt_svr_run_seconds(void);

uint16_t gatt_svr_pair_val_handle(void);
uint16_t gatt_svr_state_val_handle(void);
void gatt_svr_on_subscribe(uint16_t conn_handle, uint16_t attr_handle, bool notify_enabled);

#ifdef __cplusplus
}
#endif
