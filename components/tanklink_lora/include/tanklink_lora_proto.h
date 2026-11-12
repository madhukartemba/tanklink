#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Tank ↔ pump LoRa packet (packed, little-endian seq). */
#define TANKLINK_LORA_MAGIC0 0x54u /* 'T' */
#define TANKLINK_LORA_MAGIC1 0x4Cu /* 'L' */
#define TANKLINK_LORA_VER 2
#define TANKLINK_LORA_TYPE_STATUS 0x01
#define TANKLINK_LORA_TYPE_PAIR 0x02
#define TANKLINK_LORA_TYPE_ACK 0x03

#define TANKLINK_LORA_FLAG_FULL (1u << 0)
#define TANKLINK_LORA_FLAG_EMPTY (1u << 1)
#define TANKLINK_LORA_FLAG_BTN (1u << 2)
#define TANKLINK_LORA_FLAG_PAIRING (1u << 3)

#define TANKLINK_LORA_TANK_ID_LEN 6

typedef struct __attribute__((packed)) {
    uint8_t magic0;
    uint8_t magic1;
    uint8_t ver;
    uint8_t type;
    uint8_t flags;
    uint8_t battery_pct; /* 0-100; ACK may echo 0 */
    uint16_t seq;        /* STATUS/PAIR seq; ACK echoes the same seq */
    uint8_t tank_id[TANKLINK_LORA_TANK_ID_LEN]; /* ESP32 station MAC */
    uint8_t fw_major;
    uint8_t fw_minor;
    uint8_t fw_patch;
} tanklink_lora_status_t;

/** Pump → tank ACK uses the same layout with type=ACK. */

#ifdef __cplusplus
}
#endif
