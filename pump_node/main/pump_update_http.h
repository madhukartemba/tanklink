#pragma once

/*
 * The network half of the pump's self-update: ask the update server what the
 * newest firmware for this board is, and download an image. Nothing here
 * decides *when* (pump_update.c does) or touches the flash (pump_ota.c does).
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_UPDATE_URL_MAX 320

/** What the server offers: the newest release that fits this board. */
typedef struct {
    uint8_t version[3]; /* major, minor, patch */
    uint32_t size;
    uint8_t sha256[32];
    char url[PUMP_UPDATE_URL_MAX]; /* https only */
} pump_update_offer_t;

typedef enum {
    PUMP_UPDATE_FETCH_OFFER,       /* [out] holds the newest release */
    PUMP_UPDATE_FETCH_NONE,        /* the server has nothing for this board */
    PUMP_UPDATE_FETCH_NO_INTERNET, /* couldn't connect */
    PUMP_UPDATE_FETCH_ERROR,       /* connected, but the answer was wrong */
} pump_update_fetch_t;

/** GET /v1/firmware/pump/latest. Blocks for up to a few seconds. */
pump_update_fetch_t pump_update_http_latest(pump_update_offer_t *out);

/** Receives the image in order. Return false to stop the download. */
typedef bool (*pump_update_sink_t)(const uint8_t *data, size_t len, void *arg);

/** Download [offer]'s image into [sink]. True only if exactly offer->size bytes
 * arrived with status 200 and the sink took them all. [got] gets the byte count. */
bool pump_update_http_download(const pump_update_offer_t *offer, pump_update_sink_t sink,
                               void *arg, uint32_t *got);

#ifdef __cplusplus
}
#endif
