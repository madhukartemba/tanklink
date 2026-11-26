#pragma once

/*
 * Byte layouts of the pump's BLE characteristics (docs/PROTOCOL.md).
 *
 * Each function fills a flat buffer from the current pump state and returns
 * its length. Nothing here talks to NimBLE, so the layouts can be read next
 * to the app's lib/ble/protocol.dart.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pump_battery_log.h"
#include "pump_config.h"
#include "pump_history.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "pump_wifi.h"
#include "tanklink_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 26 bytes of settings, then the pump name (24, UTF-8, NUL-padded). */
#define GATT_SETTINGS_READ_LEN (14 + TANKLINK_USAGE_LEN + PUMP_NAME_MAX + 2)
#define GATT_OTA_STATUS_LEN 6
#define GATT_WIFI_STATUS_MAX_LEN (7 + PUMP_WIFI_SSID_MAX + TANKLINK_WIFI_UPDATE_LEN)
#define GATT_WIFI_SCAN_MAX_LEN (3 + PUMP_WIFI_SCAN_PAGE * (3 + PUMP_WIFI_SSID_MAX))
#define GATT_SCHED_MAX_LEN (4 + PUMP_SCHED_MAX * 4 + 1)
#define GATT_TANKS_MAX_LEN (2 + PUMP_TANK_SLOT_MAX * TANKLINK_TANKS_ENTRY_LEN + 1)
/* Entry list, then one fault byte per entry. */
#define GATT_NODES_MAX_LEN \
    (2 + PUMP_NODE_MAX * (TANKLINK_NODES_ENTRY_LEN + 1 + TANKLINK_NODES_BEAT_LEN))
#define GATT_HISTORY_MAX_LEN (3 + TANKLINK_HISTORY_PAGE * TANKLINK_HISTORY_ENTRY_LEN)
#define GATT_BATTERY_MAX_LEN (1 + PUMP_NODE_MAX * (2 + PUMP_BATLOG_DAYS * TANKLINK_BATTERY_DAY_LEN))

/** Info (frozen layout). [authed] is whether the reading connection is signed in. */
size_t gatt_payload_info(uint8_t out[TANKLINK_INFO_LEN], bool authed);

/** Settings read. */
size_t gatt_payload_settings(uint8_t out[GATT_SETTINGS_READ_LEN]);

/** Tank: the selected tank's sensor, plus the interrupted fill. */
size_t gatt_payload_tank_status(uint8_t out[TANKLINK_TANK_STATUS_LEN]);

/** Schedule: pump clock, fill times, clock flags. */
size_t gatt_payload_sched(uint8_t out[GATT_SCHED_MAX_LEN]);

/** Tanks: the selected slot and every tank slot. */
size_t gatt_payload_tanks(uint8_t out[GATT_TANKS_MAX_LEN]);

/** History: the last fills, newest first. */
/** One page of the fill history, from fill [start] (0 = newest). */
size_t gatt_payload_history(uint8_t out[GATT_HISTORY_MAX_LEN], uint8_t start);

/** Battery: each sensor's daily low and high battery. */
size_t gatt_payload_battery(uint8_t out[GATT_BATTERY_MAX_LEN]);

/** Sensors: every paired tank sensor. */
size_t gatt_payload_nodes(uint8_t out[GATT_NODES_MAX_LEN]);

/** Wifi status: state, signal, address, network name. */
size_t gatt_payload_wifi_status(uint8_t out[GATT_WIFI_STATUS_MAX_LEN]);

/** Wifi scan results, [page] of PUMP_WIFI_SCAN_PAGE networks. */
size_t gatt_payload_wifi_scan(uint8_t out[GATT_WIFI_SCAN_MAX_LEN], uint8_t page);

/** OtaStatus: state, error, offset. */
size_t gatt_payload_ota_status(uint8_t out[GATT_OTA_STATUS_LEN]);

#ifdef __cplusplus
}
#endif
