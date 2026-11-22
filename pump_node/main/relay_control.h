#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Starter wiring profiles (the app's Starter setting).
 *
 * Two-button: relay 1 = START pulse (NO across the starter's Start button),
 * relay 2 = STOP pulse (NC in series with its Stop button).
 *
 * Single-phase MCB: relay 1 is held closed for as long as the pump runs and
 * drives the contactor coil (or a direct-on-line motor relay) behind the MCB.
 * Relay 2 is not used. Any restart, power cut or crash drops relay 1, so the
 * motor stops and stays off until started again.
 */
typedef enum {
    PUMP_STARTER_NONE = 0,         /* on/off tracked (LED, app), relays untouched */
    PUMP_STARTER_TWO_BUTTON = 1,   /* momentary Start / Stop relays */
    PUMP_STARTER_SINGLE_PHASE = 2, /* relay 1 held while running */
    PUMP_STARTER_COUNT
} pump_starter_type_t;

/** Why starts are blocked. Each is set and cleared on its own; starts are
 * allowed only when none is set. */
typedef enum {
    RELAY_BLOCK_OTA = 1u << 0,
    RELAY_BLOCK_PAIRING = 1u << 1,
    RELAY_BLOCK_RESET = 1u << 2,
} relay_block_t;

/** Drive relay GPIOs to idle immediately. Call first in app_main (no NVS needed). */
void relay_control_early_safe(void);

/** Init GPIOs (if assigned), load the saved starter type and force the starter OFF. */
esp_err_t relay_control_init(void);

/** Start the motor. False (and nothing done) while any block is set; true if
 * it is running afterwards, including when it already was. */
bool relay_control_start(void);

/** Stop the motor. Always acts on the hardware (pulses Stop / drops relay 1),
 * even if it is already thought to be off. */
void relay_control_stop(void);

/** Set or clear one block reason. Setting the first one stops the motor. */
void relay_control_block(relay_block_t why, bool on);
bool relay_control_is_blocked(void);

bool relay_control_is_running(void);

pump_starter_type_t relay_control_get_type(void);
/** Switch profile: stops the motor with the old profile first. */
esp_err_t relay_control_set_type(pump_starter_type_t type);

/** Two-button press length; caller passes a value already checked by pump_config. */
void relay_control_set_pulse_ms(uint16_t ms);

#ifdef __cplusplus
}
#endif
