#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "esp_sleep.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool full;  /* HIGH = full / disconnect */
    bool empty; /* HIGH = empty / disconnect */
    bool button_down; /* true while held (active low) */
} tank_inputs_t;

esp_err_t tank_board_init(void);
void tank_board_read(tank_inputs_t *out);
void tank_led_set(bool on);
void tank_led_blink(int times, int on_ms, int off_ms);
/** Pulse LED once briefly (TX activity). */
void tank_led_tx_pulse(void);

/** Configure deep-sleep wake: floats HIGH, button LOW, plus timer. */
void tank_board_prepare_deep_sleep(uint32_t heartbeat_sec);

esp_sleep_wakeup_cause_t tank_board_wakeup_cause(void);
bool tank_board_woke_from_button(void);
bool tank_board_woke_from_float(void);
bool tank_board_woke_from_timer(void);

/**
 * After a button wake: wait briefly and classify.
 * Returns hold_ms actually observed; *is_hold set if >= hold_threshold_ms.
 * Leaves when button released or hold confirmed.
 */
void tank_board_classify_button(uint32_t hold_threshold_ms, bool *is_hold,
                               uint32_t *held_ms);

#ifdef __cplusplus
}
#endif
