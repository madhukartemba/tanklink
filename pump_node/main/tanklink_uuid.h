#pragma once

#include "host/ble_uuid.h"
#include "sdkconfig.h"

#ifdef __cplusplus
extern "C" {
#endif

/* TankLink custom 128-bit UUIDs (LE byte order for NimBLE).
 * String form:
 *   Service  7f1a0001-ac01-4c8c-9b2e-74616e6b6c6e
 *   Info     7f1a0002-ac01-4c8c-9b2e-74616e6b6c6e
 *   Pair     7f1a0003-ac01-4c8c-9b2e-74616e6b6c6e
 *   Auth     7f1a0004-ac01-4c8c-9b2e-74616e6b6c6e
 *   State    7f1a0005-ac01-4c8c-9b2e-74616e6b6c6e
 *   Cmd      7f1a0006-ac01-4c8c-9b2e-74616e6b6c6e
 *   Settings 7f1a0007-ac01-4c8c-9b2e-74616e6b6c6e
 *   OtaCtrl  7f1a0008-ac01-4c8c-9b2e-74616e6b6c6e
 *   OtaData  7f1a0009-ac01-4c8c-9b2e-74616e6b6c6e
 *   OtaStatus 7f1a000a-ac01-4c8c-9b2e-74616e6b6c6e
 *   Tank      7f1a000b-ac01-4c8c-9b2e-74616e6b6c6e
 *   Schedule 7f1a000c-ac01-4c8c-9b2e-74616e6b6c6e
 *   Tanks    7f1a000d-ac01-4c8c-9b2e-74616e6b6c6e
 *   Sensors  7f1a000e-ac01-4c8c-9b2e-74616e6b6c6e
 */
#define TANKLINK_UUID_BASE_TAIL 0x6e, 0x6c, 0x6b, 0x6e, 0x61, 0x74, 0x2e, 0x9b, \
                                0x8c, 0x4c, 0x01, 0xac

#define TANKLINK_SVC_UUID_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x01, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_INFO_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x02, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_PAIR_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x03, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_AUTH_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x04, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_STATE_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x05, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_CMD_INIT   BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x06, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_SETTINGS_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x07, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_OTA_CTRL_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x08, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_OTA_DATA_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x09, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_OTA_STATUS_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x0a, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_TANK_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x0b, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_SCHED_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x0c, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_TANKS_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x0d, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_NODES_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x0e, 0x00, 0x1a, 0x7f)

#define TANKLINK_DEVICE_NAME_PREFIX "TankLink-"
/* GAP name before the serial suffix is known. Adverts use PREFIX + serial. */
#define TANKLINK_DEVICE_NAME "TankLink-Pump"

/* Firmware version. TANKLINK_FW_VERSION is built from the three numbers. */
#define TANKLINK_FW_MAJOR 0
#define TANKLINK_FW_MINOR 13
#define TANKLINK_FW_PATCH 0
#define TANKLINK_STR_(x) #x
#define TANKLINK_STR(x) TANKLINK_STR_(x)
#define TANKLINK_FW_VERSION \
    TANKLINK_STR(TANKLINK_FW_MAJOR) "." TANKLINK_STR(TANKLINK_FW_MINOR) "." TANKLINK_STR(TANKLINK_FW_PATCH)

/*
 * App <-> pump BLE protocol version, reported first in Info.
 *
 * MINOR: something was added (a field appended to a payload, a new opcode, a
 * new characteristic). Readers take the fields they know and ignore extra
 * bytes, so an app works with any pump of the same MAJOR.
 * MAJOR: a field was moved, resized or removed. The app refuses to control a
 * pump with a different MAJOR and offers a firmware update instead.
 *
 * Frozen across every MAJOR, so any app can always identify and update any
 * pump: the service UUID, the 18-byte Info layout (later versions may only
 * append), Pair, Auth, OtaCtrl, OtaData and OtaStatus.
 */
#define TANKLINK_PROTO_MAJOR 1
#define TANKLINK_PROTO_MINOR 0

/* Board revision of this build (Kconfig PUMP_HW_REV). Firmware manifests list
 * the revisions a binary fits, and the app only offers matching updates. */
#define TANKLINK_HW_REV CONFIG_PUMP_HW_REV

/* OTA_CTRL opcodes */
#define TANKLINK_OTA_OP_START  0x01
#define TANKLINK_OTA_OP_ABORT  0x02
#define TANKLINK_OTA_OP_FINISH 0x03

/* OTA_STATUS state byte */
#define TANKLINK_OTA_ST_IDLE      0
#define TANKLINK_OTA_ST_READY     1
#define TANKLINK_OTA_ST_WRITING   2
#define TANKLINK_OTA_ST_VERIFY_OK 3
#define TANKLINK_OTA_ST_REBOOTING 4
#define TANKLINK_OTA_ST_ERR       5

/* OTA_STATUS error byte */
#define TANKLINK_OTA_ERR_OK        0
#define TANKLINK_OTA_ERR_NOT_AUTH  1
#define TANKLINK_OTA_ERR_PUMP_ON   2
#define TANKLINK_OTA_ERR_BAD_PARAM 3
#define TANKLINK_OTA_ERR_FLASH     4
#define TANKLINK_OTA_ERR_HASH      5
#define TANKLINK_OTA_ERR_STATE     6
#define TANKLINK_OTA_ERR_BUSY      7
#define TANKLINK_TOKEN_LEN   16
#define TANKLINK_DEVICE_ID_LEN 6
#define TANKLINK_SERIAL_LEN  4
#define TANKLINK_ADV_NAME_MAX 16

/* Cmd opcodes (byte 0). Unknown opcodes are rejected. */
#define TANKLINK_CMD_OFF       0x00
#define TANKLINK_CMD_ON        0x01
#define TANKLINK_CMD_TEST_BEEP 0xB1
#define TANKLINK_CMD_TANK_PAIR 0xA1
#define TANKLINK_CMD_TANK_UNPAIR 0xA2 /* sensor_id(6) */
#define TANKLINK_CMD_TANK_SELECT 0xA4
#define TANKLINK_CMD_TANK_RENAME 0xA5
#define TANKLINK_CMD_TANK_AUTO_OFF 0xA6 /* slot(1) minutes(1), 0 = off */
#define TANKLINK_CMD_SENSOR_MODE 0xA7 /* sensor_id(6) mode(1) */
#define TANKLINK_CMD_UNPAIR    0xF0
#define TANKLINK_CMD_FACTORY_RESET 0xF1
#define TANKLINK_CMD_CLEAR_ERROR   0xE0
#define TANKLINK_CMD_DISMISS_INTERRUPT 0xE1

/**
 * Tank char payload:
 * bound(1) pairing(1) id(6) fw(3) flags(1) bat(1) online(1) age_sec_le(2)
 * rssi_dbm_i8(1) snr_db_i8(1) last_error(1) ble_token(16), then the
 * interrupted fill: reason(1) started(u32) last_seen(u32) back(u32)
 * ran_sec(u32), then tank_hw_rev(1) = 53 bytes. Times are pump-local seconds
 * since 1970, 0 = unknown.
 */
#define TANKLINK_TANK_STATUS_TOKEN_LEN 35
#define TANKLINK_TANK_STATUS_HW_AT 52
#define TANKLINK_TANK_STATUS_LEN 53

/* Schedule char write opcodes (authenticated). */
#define TANKLINK_SCHED_OP_SET_CLOCK 0x01
#define TANKLINK_SCHED_OP_SET_LIST  0x02
#define TANKLINK_SCHED_MAX          4

/* Info read length for this protocol version. */
#define TANKLINK_INFO_LEN 18

/* Settings write: buzzer_flags tone led starter pulse_ms(u16). Float modes
 * are per sensor (Cmd 0xA7). */
#define TANKLINK_SETTINGS_WRITE_LEN 6

/* Tanks: active_slot(1) count(1), then count x entry:
 * slot_index(1) sensor_pin(1) sensor_index(1, 0xFF = none) auto_off_min(1)
 * name(16). */
#define TANKLINK_TANKS_ENTRY_LEN 20

/* Sensors: count(1) max(1), then count x entry:
 * index(1) id(6) mode(1) raw_flags(1) battery(1) online(1) age_sec(u16)
 * rssi(i8) snr(i8) fw(3) hw_rev(1) ble_token(16). */
#define TANKLINK_NODES_ENTRY_LEN 35

#ifdef __cplusplus
}
#endif
