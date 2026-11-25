#pragma once

/*
 * Auto-fill: the selected tank fills itself when it runs low (see
 * pump_tanks_active_is_low), within the allowed times. Which tanks use it is
 * per tank (pump_tanks); how it behaves is pump-wide, here, saved in NVS
 * (tl_afill/cfg) and read and written through the AutoFill characteristic.
 *
 * It starts once per drop: armed when the tank is seen above its low mark
 * (on a reading sent since boot), it starts on the next drop. A fill that
 * ends any other way than "tank full", the end of its allowed time or the
 * pump stopping it for pairing or an update pauses it until the tank is next
 * seen full, so a dry source or a stuck float can't keep starting the pump.
 * Turning it on for the selected tank, or Arm in the app, arms it at once.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "pump_history.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_AF_WINDOW_MAX 4
#define PUMP_AF_GAP_MIN_MIN 5
#define PUMP_AF_GAP_MIN_MAX 180
#define PUMP_AF_GAP_MIN_DEFAULT 15

#define PUMP_AF_F_LIMIT (1u << 0)       /* only start within the allowed times */
#define PUMP_AF_F_STOP_AT_END (1u << 1) /* stop an auto-fill when its allowed time ends */

/* Sent to the app as one byte: append only. */
typedef enum {
    PUMP_AF_OFF = 0,        /* the selected tank has auto-fill off */
    PUMP_AF_OFFLINE = 1,    /* its sensor isn't heard */
    PUMP_AF_WATCHING = 2,   /* armed (or waiting for a first reading): fills when it runs low */
    PUMP_AF_WAIT_ARM = 3,   /* already low when it started watching: waits to see it above */
    PUMP_AF_WAIT_TIME = 4,  /* low, outside the allowed times; wait = minutes to the next */
    PUMP_AF_NO_CLOCK = 5,   /* allowed times set, but the pump doesn't know the time */
    PUMP_AF_COOLDOWN = 6,   /* low, too soon after the last stop; wait = minutes left */
    PUMP_AF_PAUSED = 7,     /* the last auto-fill didn't end full: waits for "full" or Arm */
    PUMP_AF_FILLING = 8,    /* the pump is running an auto-fill */
    PUMP_AF_BUSY = 9,       /* low, but pairing or an update is under way */
    PUMP_AF_PUMP_ON = 10,   /* low, but the pump is already running another fill */
} pump_af_state_t;

#define PUMP_AF_WAIT_NONE 0xFFFF

/* state slot wait_min(u16) flags gap_min count, then count x
 * enabled days start_h start_m end_h end_m */
#define PUMP_AF_WINDOW_LEN 6
#define PUMP_AF_PAYLOAD_MAX (7 + PUMP_AF_WINDOW_MAX * PUMP_AF_WINDOW_LEN)

esp_err_t pump_autofill_init(void);

/** About once a second, with the pump_control lock held. May start or stop the pump. */
void pump_autofill_poll(void);

/** Every stop of a fill (pump_control, lock held). */
void pump_autofill_on_stop(uint8_t started_by, pump_cause_t cause);

/** Arm now and clear a pause (taken on the next poll). */
void pump_autofill_arm(void);

size_t pump_autofill_payload(uint8_t out[PUMP_AF_PAYLOAD_MAX]);

/** 0x01 flags gap count windows = replace the settings; 0x02 = arm. */
esp_err_t pump_autofill_write(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
