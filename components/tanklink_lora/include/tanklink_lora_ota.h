#pragma once

/*
 * Tank firmware update over LoRa (experimental).
 *
 * The pump holds the image (sent by the app over BLE). When the tank's next
 * STATUS arrives, the pump's ACK carries TANKLINK_LORA_FLAG_OTA_PENDING and
 * the tank stays awake. Then:
 *
 *   pump OFFER(size, chunks, fast, sha256)     -> tank erases, OFFER_ACK
 *   pump DATA(index, 224 bytes) x up to 16     -> tank writes each chunk
 *   pump POLL(base)                            -> tank WIN_ACK(base, bits)
 *   ... missing chunks are sent again, then the next window ...
 *   pump DONE                                  -> tank checks sha256 and the
 *                                                 image signature, DONE_ACK,
 *                                                 then boots the new image
 *
 * With fast set, both sides switch to 500 kHz bandwidth after OFFER_ACK
 * (about 4x faster, less range) and back to 125 kHz at the end or after 10 s
 * without traffic. Every packet starts with tl_ota_hdr_t, is tagged with the
 * tank's link key (tl_lora_seal) and belongs to one session (random, from
 * the pump), so packets from another update or another tank are ignored.
 */

#include <stdint.h>

#include "tanklink_lora_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

#define TANKLINK_LORA_FLAG_OTA_PENDING (1u << 4) /* in an ACK: stay awake for an update */

#define TANKLINK_LORA_TYPE_OTA_OFFER 0x10
#define TANKLINK_LORA_TYPE_OTA_OFFER_ACK 0x11
#define TANKLINK_LORA_TYPE_OTA_DATA 0x12
#define TANKLINK_LORA_TYPE_OTA_POLL 0x13
#define TANKLINK_LORA_TYPE_OTA_WIN_ACK 0x14
#define TANKLINK_LORA_TYPE_OTA_DONE 0x15
#define TANKLINK_LORA_TYPE_OTA_DONE_ACK 0x16

#define TL_OTA_CHUNK 224 /* data bytes per DATA packet */
#define TL_OTA_WINDOW 16 /* chunks per POLL */
#define TL_OTA_MAX_SIZE (0x1C0000u - 0x20u)

/* OFFER_ACK / DONE_ACK status */
#define TL_OTA_OK 0
#define TL_OTA_ERR_SIZE 1    /* image does not fit */
#define TL_OTA_ERR_FLASH 2   /* erase or write failed */
#define TL_OTA_ERR_MISSING 3 /* DONE before every chunk arrived */
#define TL_OTA_ERR_HASH 4    /* sha256 of what arrived differs from the offer */
#define TL_OTA_ERR_IMAGE 5   /* not a valid, signed app image */

typedef struct __attribute__((packed)) {
    uint8_t magic0;
    uint8_t magic1;
    uint8_t ver;
    uint8_t type;
    uint8_t tank_id[TANKLINK_LORA_TANK_ID_LEN];
    uint32_t session;
} tl_ota_hdr_t;

typedef struct __attribute__((packed)) {
    tl_ota_hdr_t h;
    uint32_t size;
    uint16_t chunks;
    uint8_t fast;
    uint8_t sha256[32];
} tl_ota_offer_t;

typedef struct __attribute__((packed)) {
    tl_ota_hdr_t h;
    uint8_t status;
} tl_ota_status_t; /* OFFER_ACK and DONE_ACK */

typedef struct __attribute__((packed)) {
    tl_ota_hdr_t h;
    uint16_t index;
    uint8_t data[TL_OTA_CHUNK]; /* the last chunk may be shorter */
} tl_ota_data_t;

typedef struct __attribute__((packed)) {
    tl_ota_hdr_t h;
    uint16_t base;
} tl_ota_poll_t;

typedef struct __attribute__((packed)) {
    tl_ota_hdr_t h;
    uint16_t base;
    uint16_t bits; /* bit i: chunk base + i has arrived (or is past the end) */
} tl_ota_win_ack_t;

_Static_assert(sizeof(tl_ota_data_t) + TL_LORA_TAG_LEN <= 255, "DATA fits one LoRa packet");

static inline void tl_ota_hdr_fill(tl_ota_hdr_t *h, uint8_t type,
                                   const uint8_t tank_id[TANKLINK_LORA_TANK_ID_LEN],
                                   uint32_t session)
{
    h->magic0 = TANKLINK_LORA_MAGIC0;
    h->magic1 = TANKLINK_LORA_MAGIC1;
    h->ver = TANKLINK_LORA_VER;
    h->type = type;
    for (int i = 0; i < TANKLINK_LORA_TANK_ID_LEN; i++) {
        h->tank_id[i] = tank_id[i];
    }
    h->session = session;
}

#ifdef __cplusplus
}
#endif
