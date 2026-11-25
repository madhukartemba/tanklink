#pragma once

/*
 * The pump's app API, the same over two transports: BLE (gatt_svr.c) and TCP
 * over Wi-Fi (pump_wifi_api.c). A transport owns its sessions and calls
 * pump_api_read / pump_api_write with the characteristic's UUID suffix byte
 * (0x02 Info ... 0x11 Wifi). The bytes are exactly what BLE carries
 * (docs/PROTOCOL.md). Behaviour lives here; byte layouts in gatt_payloads.c.
 *
 * Pairing a new phone (the Pair characteristic) is BLE only and stays in
 * gatt_svr.c, so nobody on the network can claim a pump.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "tanklink_crypto.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Characteristic ids: the UUID suffix byte. */
#define PUMP_API_CHR_INFO 0x02
#define PUMP_API_CHR_PAIR 0x03
#define PUMP_API_CHR_AUTH 0x04
#define PUMP_API_CHR_STATE 0x05
#define PUMP_API_CHR_CMD 0x06
#define PUMP_API_CHR_SETTINGS 0x07
#define PUMP_API_CHR_OTA_CTRL 0x08
#define PUMP_API_CHR_OTA_DATA 0x09
#define PUMP_API_CHR_OTA_STATUS 0x0a
#define PUMP_API_CHR_TANK 0x0b
#define PUMP_API_CHR_SCHED 0x0c
#define PUMP_API_CHR_TANKS 0x0d
#define PUMP_API_CHR_NODES 0x0e
#define PUMP_API_CHR_HISTORY 0x0f
#define PUMP_API_CHR_BATTERY 0x10
#define PUMP_API_CHR_WIFI 0x11
#define PUMP_API_CHR_ALERT_KEY 0x12
#define PUMP_API_CHR_ALERT_LOG 0x13
#define PUMP_API_CHR_BUZZER 0x14
#define PUMP_API_CHR_AUTO_FILL 0x15

/** Biggest value pump_api_read() can return. */
#define PUMP_API_READ_MAX 512
/** Biggest OTA data write: offset(4) plus a 2 KB chunk (Wi-Fi). */
#define PUMP_API_WRITE_MAX 2052

/** The pump itself, as the owner of an update it downloaded (always signed in). */
#define PUMP_API_LOCAL_ID 0x7FFE

/** Session ids: BLE connection handles are below this, TCP ones above. */
#define PUMP_API_TCP_ID_BASE 0x8000

typedef enum {
    PUMP_API_OK = 0,
    PUMP_API_ERR_NOT_AUTH, /* sign in first */
    PUMP_API_ERR_LEN,      /* write too short or too long */
    PUMP_API_ERR_REFUSED,  /* understood, not allowed or failed */
    PUMP_API_ERR_NO_MEM,
} pump_api_err_t;

/** One connected app, on either transport. The transport fills [id]. */
typedef struct {
    uint16_t id;                      /* names the session for OTA ownership */
    bool authed;
    int8_t phone;                     /* pump_pair phone index once authed, else -1 */
    uint8_t history_start;            /* History page a read returns */
    uint8_t wifi_page;                /* Wifi read: scan page, or 0xFF = status */
    uint8_t nonce[TL_NONCE_LEN];      /* Auth challenge, new after every attempt */
    uint8_t auth_nonce[TL_NONCE_LEN]; /* nonce the phone signed in with */
} pump_api_session_t;

/** Create the lock the two transports share. Call before either starts. */
void pump_api_init(void);

/** Reset [s] for a new connection with id [id] and a fresh nonce. */
void pump_api_session_init(pump_api_session_t *s, uint16_t id);
void pump_api_session_sign_out(pump_api_session_t *s);

/** Value of characteristic [chr] into [out] (at least PUMP_API_READ_MAX). */
pump_api_err_t pump_api_read(pump_api_session_t *s, uint8_t chr, uint8_t *out, size_t *len);

pump_api_err_t pump_api_write(pump_api_session_t *s, uint8_t chr, const uint8_t *data,
                              size_t len);

/** Notifications are public (State, OtaStatus) or need sign-in. */
bool pump_api_chr_notify_needs_auth(uint8_t chr);

/* The session with this id, whichever transport owns it. */
bool pump_api_id_authed(uint16_t id);
void pump_api_drop_id(uint16_t id);

#ifdef __cplusplus
}
#endif
