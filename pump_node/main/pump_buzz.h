#pragma once

/*
 * When the buzzer sounds and how: one switch and one sound per event, a
 * master switch and quiet hours. Saved on the pump (NVS tl_buzz/cfg) and
 * read and written whole through the Buzzer characteristic.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "buzzer.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Bit index in the events mask and index in the sounds list: append only. */
typedef enum {
    PUMP_BUZZ_BUTTON = 0,     /* button press, and the 1 s "ready" mark */
    PUMP_BUZZ_PUMP_START = 1, /* started from the app */
    PUMP_BUZZ_PUMP_STOP = 2,  /* stopped from the app, or by pairing / an update */
    PUMP_BUZZ_TANK_FULL = 3,  /* stopped because the tank is full */
    PUMP_BUZZ_AUTO_OFF = 4,   /* stopped by the auto-off timer */
    PUMP_BUZZ_AUTO_FILL = 5,  /* auto-fill started, or stopped at the end of its allowed time */
    PUMP_BUZZ_SCHEDULE = 6,   /* a schedule started a fill */
    PUMP_BUZZ_DENIED = 7,     /* the button or the app asked for a start the pump refused */
    PUMP_BUZZ_ALERT = 8,      /* power cut, tank offline, battery low, sensor removed */
    PUMP_BUZZ_PAIRING = 9,    /* a pairing window opened, or a phone or tank paired */
    PUMP_BUZZ_PHONE = 10,     /* a phone signed in */
    PUMP_BUZZ_POWER_UP = 11,  /* the pump started up */
    PUMP_BUZZ_EVENT_COUNT
} pump_buzz_event_t;

#define PUMP_BUZZ_F_ENABLED (1u << 0)
#define PUMP_BUZZ_F_QUIET (1u << 1)        /* quiet hours on */
#define PUMP_BUZZ_F_QUIET_BUTTON (1u << 2) /* button sounds still play in quiet hours */

/* flags(1) events(u16) sounds(EVENT_COUNT) quiet_start_h quiet_start_m quiet_end_h quiet_end_m */
#define PUMP_BUZZ_PAYLOAD_LEN (3 + PUMP_BUZZ_EVENT_COUNT + 4)

esp_err_t pump_buzz_init(void);

/** Sound [event] if it is switched on, the buzzer is on, and it isn't quiet hours. */
void pump_buzz(pump_buzz_event_t event);

/** Play [sound] now, whatever the settings (the app's preview). */
void pump_buzz_test(buzzer_sound_t sound);

size_t pump_buzz_payload(uint8_t out[PUMP_BUZZ_PAYLOAD_LEN]);
/** Exactly PUMP_BUZZ_PAYLOAD_LEN bytes; every field is checked before any is saved. */
esp_err_t pump_buzz_write(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
