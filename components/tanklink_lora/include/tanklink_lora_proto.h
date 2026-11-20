#pragma once

#include <stdint.h>

#include "tanklink_crypto.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Tank ↔ pump LoRa packet (packed, little-endian). */
#define TANKLINK_LORA_MAGIC0 0x54u /* 'T' */
#define TANKLINK_LORA_MAGIC1 0x4Cu /* 'L' */
/**
 * LoRa protocol major version. A receiver drops packets with a different
 * major. Within one major, fields are only ever appended (before the tag):
 * a receiver reads the fields it knows and ignores the rest.
 */
#define TANKLINK_LORA_VER 5
#define TANKLINK_LORA_TYPE_STATUS 0x01
#define TANKLINK_LORA_TYPE_PAIR 0x02
#define TANKLINK_LORA_TYPE_ACK 0x03

/** Raw float pin levels: bit set when that pin is HIGH (internal pull-up). */
#define TANKLINK_LORA_FLAG_SENSOR1 (1u << 0)
#define TANKLINK_LORA_FLAG_SENSOR2 (1u << 1)
#define TANKLINK_LORA_FLAG_BTN (1u << 2)
#define TANKLINK_LORA_FLAG_PAIRING (1u << 3)

#define TANKLINK_LORA_TANK_ID_LEN 6
#define TANKLINK_LORA_KEY_LEN TL_KEY_LEN
#define TANKLINK_LORA_BLE_TOKEN_LEN 16

typedef struct __attribute__((packed)) {
    uint8_t magic0;
    uint8_t magic1;
    uint8_t ver;
    uint8_t type;
    uint8_t flags;
    uint8_t battery_pct; /* 0-100; 0 in ACK */
    uint32_t seq;        /* per tank, only goes up (kept in NVS); ACK echoes it */
    uint8_t tank_id[TANKLINK_LORA_TANK_ID_LEN]; /* ESP32 station MAC */
    uint8_t fw_major;
    uint8_t fw_minor;
    uint8_t fw_patch;
    uint8_t hw_rev; /* tank board revision (CONFIG_TANK_HW_REV); 0 in ACK */
    uint8_t fault;  /* tank LED code, 0 = none; 0 in ACK */
} tanklink_lora_status_t;

/*
 * On air:
 *   STATUS, ACK: status body, then the 8-byte tag.
 *   PAIR:        status body, link key(16), then the 8-byte tag.
 * The tag is HMAC-SHA256(link key, everything before it), first 8 bytes.
 * PAIR is tagged with the key it carries; the pump's ACK to a PAIR is
 * tagged with that same key, which is how the tank knows the pump took it.
 * Fields added later go before the tag.
 */
#define TANKLINK_LORA_STATUS_BODY_LEN (sizeof(tanklink_lora_status_t))
#define TANKLINK_LORA_STATUS_LEN (TANKLINK_LORA_STATUS_BODY_LEN + TL_LORA_TAG_LEN)
#define TANKLINK_LORA_PAIR_BODY_LEN (TANKLINK_LORA_STATUS_BODY_LEN + TANKLINK_LORA_KEY_LEN)
#define TANKLINK_LORA_PAIR_LEN (TANKLINK_LORA_PAIR_BODY_LEN + TL_LORA_TAG_LEN)

#ifdef __cplusplus
}
#endif
