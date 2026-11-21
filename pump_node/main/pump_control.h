#pragma once

/*
 * Pump on/off state and the rules around it: start checks (tank full,
 * update running), run time, the last error shown on the LED and in the
 * app, daily schedules and per-tank auto-off.
 *
 * Changes are published to connected phones through gatt_svr.
 */

#include <stdbool.h>
#include <stdint.h>

#include "pump_history.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Call once in app_main, before any task can switch the pump. */
void pump_control_init(void);

bool pump_control_is_on(void);

/**
 * Start or stop the pump. Plays the start/stop beep when enabled. [cause]
 * says who asked; it goes into the fill history.
 */
void pump_control_set(bool on, pump_cause_t cause);

/** Same, without the beep (the caller already gave feedback). */
void pump_control_set_silent(bool on, pump_cause_t cause);

/** Button press: flip the pump, ignored while updating or unpaired. */
void pump_control_toggle(void);

/** Seconds since the pump started, 0 when off. */
uint32_t pump_control_run_seconds(void);

/** Last LED / start-denied error (see pump_errors.h). */
uint8_t pump_control_last_error(void);
void pump_control_set_error(uint8_t code);
void pump_control_clear_error(void);

/** Show the idle LED unless a pairing, update or running state owns it. */
void pump_control_refresh_idle_led(void);

/** Call about once a second: starts due schedules and auto-fills, enforces auto-off. */
void pump_control_poll(void);

#ifdef __cplusplus
}
#endif
