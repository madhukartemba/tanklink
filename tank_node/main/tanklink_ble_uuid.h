#pragma once

#include "host/ble_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Same TankLink UUID base as pump — tank advertises as TL-Tank-XXXX. */
#define TANKLINK_UUID_BASE_TAIL 0x6e, 0x6c, 0x6b, 0x6e, 0x61, 0x74, 0x2e, 0x9b, \
                                0x8c, 0x4c, 0x01, 0xac

#define TANKLINK_SVC_UUID_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x01, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_INFO_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x02, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_AUTH_INIT  BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x04, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_OTA_CTRL_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x08, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_OTA_DATA_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x09, 0x00, 0x1a, 0x7f)
#define TANKLINK_CHR_OTA_STATUS_INIT BLE_UUID128_INIT(TANKLINK_UUID_BASE_TAIL, 0x0a, 0x00, 0x1a, 0x7f)

#define TANKLINK_TANK_ADV_PREFIX "TL-Tank-"

/*
 * App <-> tank BLE protocol version, reported first in Info. Same rules as
 * the pump (see pump_node/main/tanklink_uuid.h): MINOR = appended fields,
 * MAJOR = breaking. The 13-byte Info layout (append-only), Auth and the OTA
 * characteristics never change, so any app can update any tank.
 *
 * The app has one protocol major for pump and tank, and only offers firmware
 * releases whose manifest carries it, so this follows the pump's major.
 */
#define TANKLINK_PROTO_MAJOR 1
#define TANKLINK_PROTO_MINOR 0

/* proto_major proto_minor hw_rev paired tank_id(6) fw_major fw_minor fw_patch */
#define TANKLINK_TANK_INFO_LEN 13
#define TANKLINK_TOKEN_LEN 16
#define TANKLINK_DEVICE_ID_LEN 6
#define TANKLINK_ADV_NAME_MAX 16

#define TANKLINK_OTA_OP_START  0x01
#define TANKLINK_OTA_OP_ABORT  0x02
#define TANKLINK_OTA_OP_FINISH 0x03

#define TANKLINK_OTA_ST_IDLE      0
#define TANKLINK_OTA_ST_READY     1
#define TANKLINK_OTA_ST_WRITING   2
#define TANKLINK_OTA_ST_VERIFY_OK 3
#define TANKLINK_OTA_ST_REBOOTING 4
#define TANKLINK_OTA_ST_ERR       5

#define TANKLINK_OTA_ERR_OK        0
#define TANKLINK_OTA_ERR_NOT_AUTH  1
#define TANKLINK_OTA_ERR_PUMP_ON   2 /* unused on tank */
#define TANKLINK_OTA_ERR_BAD_PARAM 3
#define TANKLINK_OTA_ERR_FLASH     4
#define TANKLINK_OTA_ERR_HASH      5
#define TANKLINK_OTA_ERR_STATE     6
#define TANKLINK_OTA_ERR_BUSY      7

/** Manufacturer company ID for tank_id in adv (testing / internal). */
#define TANKLINK_MFG_COMPANY_ID 0xFFFF

#ifdef __cplusplus
}
#endif
