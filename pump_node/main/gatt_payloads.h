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

#include "pump_sched.h"
#include "pump_tanks.h"
#include "tanklink_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

#define GATT_SETTINGS_READ_LEN 16
#define GATT_OTA_STATUS_LEN 6
#define GATT_SCHED_MAX_LEN (4 + PUMP_SCHED_MAX * 4 + 1)
#define GATT_TANKS_MAX_LEN (4 + PUMP_TANK_SLOT_MAX * TANKLINK_TANKS_ENTRY_LEN)

/** Info (frozen layout). [authed] is whether the reading connection is signed in. */
size_t gatt_payload_info(uint8_t out[TANKLINK_INFO_LEN], bool authed);

/** Settings read. */
size_t gatt_payload_settings(uint8_t out[GATT_SETTINGS_READ_LEN]);

/** Tank: what the pump knows about the paired tank, plus the interrupted fill. */
size_t gatt_payload_tank_status(uint8_t out[TANKLINK_TANK_STATUS_LEN]);

/** Schedule: pump clock, fill times, clock flags. */
size_t gatt_payload_sched(uint8_t out[GATT_SCHED_MAX_LEN]);

/** Tanks: float mode and the tank slots. */
size_t gatt_payload_tanks(uint8_t out[GATT_TANKS_MAX_LEN]);

/** OtaStatus: state, error, offset. */
size_t gatt_payload_ota_status(uint8_t out[GATT_OTA_STATUS_LEN]);

#ifdef __cplusplus
}
#endif
