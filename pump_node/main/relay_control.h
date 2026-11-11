#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Starter / contactor wiring profiles.
 * GPIOs are Kconfig placeholders (−1 = not assigned yet).
 *
 * Two-button: Relay A = START pulse, Relay B = STOP pulse
 * (momentary NO across the starter’s Start / Stop pushbuttons).
 */
typedef enum {
    PUMP_STARTER_NONE = 0,       /* Logical on/off only (LED/app); no relays */
    PUMP_STARTER_TWO_BUTTON = 1, /* Dual momentary relays */
    /* Future: PUMP_STARTER_LATCHING, PUMP_STARTER_CONTACTOR, … */
    PUMP_STARTER_COUNT
} pump_starter_type_t;

/** Init GPIOs (if assigned) and immediately force the starter OFF. */
esp_err_t relay_control_init(void);

/**
 * Request running state. Paramount safety: while blocked, ON is ignored and
 * OFF is always honored. TWO_BUTTON pulses Start/Stop; NONE is logical only.
 */
void relay_control_set_running(bool on);

/** Always attempt a physical Stop (even if already “off”). Use for safety. */
void relay_control_force_off(void);

/**
 * Block pump start (OTA, pairing, etc.). Forces off when entering blocked.
 * While blocked, set_running(true) is ignored.
 */
void relay_control_set_blocked(bool blocked);
bool relay_control_is_blocked(void);

bool relay_control_is_running(void);
bool relay_control_gpios_assigned(void);

pump_starter_type_t relay_control_get_type(void);
esp_err_t relay_control_set_type(pump_starter_type_t type);

uint16_t relay_control_get_pulse_ms(void);
void relay_control_set_pulse_ms(uint16_t ms);

#ifdef __cplusplus
}
#endif
