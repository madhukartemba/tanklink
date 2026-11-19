#pragma once

/*
 * The pump's BLE GATT service (see docs/PROTOCOL.md). Pump behaviour lives in
 * pump_control.h; this module only serves and notifies characteristics.
 */

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

/* GAP events, forwarded from main.c. */
void gatt_svr_on_connect(uint16_t conn_handle);
void gatt_svr_on_disconnect(uint16_t conn_handle);
void gatt_svr_on_subscribe(uint16_t conn_handle, uint16_t attr_handle, bool notify_enabled);

int gatt_svr_conn_count(void);

/** True once this connection wrote the right token to Auth (or claimed the pump). */
bool gatt_svr_is_authed_conn(uint16_t conn_handle);

/* Push the current value to subscribed phones. Safe to call any time. */
void gatt_svr_notify_state(void);
void gatt_svr_notify_tank(void);
void gatt_svr_notify_tanks(void);
void gatt_svr_notify_nodes(void);
void gatt_svr_notify_history(void);
void gatt_svr_notify_battery(void);
void gatt_svr_notify_sched(void);

#ifdef __cplusplus
}
#endif
