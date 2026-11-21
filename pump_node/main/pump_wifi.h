#pragma once

/*
 * The pump's optional Wi-Fi (station mode, 2.4 GHz). Off until the app sets a
 * network over BLE, so a pump without Wi-Fi behaves exactly as before.
 * Credentials live in NVS namespace tl_wifi. When Wi-Fi is up the pump also
 * advertises itself over mDNS and sets its clock from SNTP (see
 * docs/plan-local-wifi.md).
 */

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** TCP port of the local API (Phase 2), advertised over mDNS. */
#define PUMP_API_PORT 7580

#define PUMP_WIFI_SSID_MAX 32
#define PUMP_WIFI_PASS_MAX 63
#define PUMP_WIFI_SCAN_MAX 20
#define PUMP_WIFI_SCAN_PAGE 8

/** Values are sent to the app as the state byte. */
typedef enum {
    PUMP_WIFI_OFF = 0,        /* no network set */
    PUMP_WIFI_CONNECTING = 1,
    PUMP_WIFI_CONNECTED = 2,  /* has an IP address */
    PUMP_WIFI_WRONG_PASSWORD = 3,
    PUMP_WIFI_NOT_FOUND = 4,  /* network not in range */
} pump_wifi_state_t;

/** Scan result auth byte. */
#define PUMP_WIFI_AUTH_OPEN 0
#define PUMP_WIFI_AUTH_SECURED 1
#define PUMP_WIFI_AUTH_UNSUPPORTED 2 /* WPA-Enterprise */

typedef struct {
    char ssid[PUMP_WIFI_SSID_MAX + 1];
    int8_t rssi;
    uint8_t auth;
} pump_wifi_net_t;

/** Load saved credentials and connect if there are any. Call after NVS init. */
esp_err_t pump_wifi_init(void);

/** Call every few hundred ms: applies a finished SNTP sync to the clock. */
void pump_wifi_poll(void);

pump_wifi_state_t pump_wifi_state(void);
/** Signal strength in dBm while connected, else 0. */
int8_t pump_wifi_rssi(void);
/** IPv4 address in network byte order (the first octet is the low byte), 0 = none. */
uint32_t pump_wifi_ip(void);
/** The saved network name ("" when none). */
const char *pump_wifi_ssid(void);

/** Save a network and connect to it. An empty [pass] means an open network. */
esp_err_t pump_wifi_set(const char *ssid, const char *pass);
/** Disconnect and clear the saved network. */
esp_err_t pump_wifi_forget(void);

/** Start a scan. Results are ready when pump_wifi_scan_busy() is false. */
esp_err_t pump_wifi_scan_start(void);
bool pump_wifi_scan_busy(void);
int pump_wifi_scan_count(void);
/** Result [i] (strongest first), false if out of range. */
bool pump_wifi_scan_get(int i, pump_wifi_net_t *out);

/** Called (from another task) when the state, signal or address changed. */
void pump_wifi_set_change_callback(void (*cb)(void));

#ifdef __cplusplus
}
#endif
