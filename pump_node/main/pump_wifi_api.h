#pragma once

/*
 * The pump's app API over Wi-Fi: a TCP server on PUMP_API_PORT that carries the
 * same characteristic reads, writes and notifications as BLE, with the same
 * bytes (pump_api.c). Only the framing is new; docs/PROTOCOL.md ("Wi-Fi
 * transport") describes it. Started when the pump gets an IP address.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Frame types. */
#define PUMP_WIFI_API_HELLO 0x01
#define PUMP_WIFI_API_AUTH 0x02
#define PUMP_WIFI_API_READ 0x03
#define PUMP_WIFI_API_WRITE 0x04
#define PUMP_WIFI_API_RESULT 0x05
#define PUMP_WIFI_API_NOTIFY 0x06
#define PUMP_WIFI_API_ERROR 0x07

#define PUMP_WIFI_API_MAX_CLIENTS 3
/** type + chr + counter. */
#define PUMP_WIFI_API_HDR_LEN 6
#define PUMP_WIFI_API_TAG_LEN 8
/** Frames idle longer than this are dropped (clients send a read as keep-alive). */
#define PUMP_WIFI_API_IDLE_MS 90000
#define PUMP_WIFI_API_AUTH_MS 10000

/** Start the server (once; call when Wi-Fi has an address). */
void pump_wifi_api_start(void);

/** Send a notification to every signed-in client. */
void pump_wifi_api_notify(uint8_t chr, const uint8_t *buf, size_t len);

bool pump_wifi_api_is_authed(uint16_t id);
void pump_wifi_api_drop(uint16_t id);
void pump_wifi_api_sign_out_all(void);
void pump_wifi_api_drop_others(uint16_t keep_id);

#ifdef __cplusplus
}
#endif
