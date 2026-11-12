#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    STATUS_LED_BOOT = 0,
    STATUS_LED_UNPAIRED,
    STATUS_LED_PAIRING,
    STATUS_LED_IDLE,          /* standby — color reflects tank full */
    STATUS_LED_CONNECTED,     /* deprecated: same as IDLE (kept for callers) */
    STATUS_LED_PUMP_ON,
    STATUS_LED_HOLD_PROGRESS, /* button hold feedback 0..100% via set_hold_progress */
    STATUS_LED_UPDATING,      /* BLE OTA in progress */
    STATUS_LED_UPDATE_OK,     /* OTA verified — solid green */
    STATUS_LED_UPDATE_ERR,    /* OTA failed — solid red */
} status_led_mode_t;

esp_err_t status_led_init(void);
void status_led_set_mode(status_led_mode_t mode);
void status_led_set_hold_progress(uint8_t percent); /* 0-100 */
void status_led_set_update_progress(uint8_t percent); /* 0-100 OTA bar */
void status_led_set_brightness(uint8_t percent); /* 1-100 global master */
uint8_t status_led_get_brightness(void);
status_led_mode_t status_led_get_mode(void);

/** Standby glow: white = not full, soft teal = full (tank sensor / LoRa later). */
void status_led_set_tank_full(bool full);
bool status_led_get_tank_full(void);

/** Short center accent pulse on standby when a phone links, then back to glow. */
void status_led_notify_ble_connect(void);

#ifdef __cplusplus
}
#endif
