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
    bool empty; /* HIGH = empty / disconnect; always false if empty float disabled */
    bool button_down; /* true while held (active low) */
} tank_inputs_t;

esp_err_t tank_board_init(void);
void tank_board_read(tank_inputs_t *out);
int tank_board_led_gpio(void);
bool tank_board_button_down(void);

/** Configure deep-sleep wake: floats HIGH, button LOW, plus timer. */
void tank_board_prepare_deep_sleep(uint32_t heartbeat_sec);

esp_sleep_wakeup_cause_t tank_board_wakeup_cause(void);
bool tank_board_woke_from_button(void);
bool tank_board_woke_from_float(void);
bool tank_board_woke_from_timer(void);

/**
 * Track hold with optional progress callback (pct 0–100).
 * *is_hold if held >= hold_threshold_ms (waits for release after).
 * Short press: returns after release with *is_hold=false.
 */
void tank_board_classify_button(uint32_t hold_threshold_ms, bool *is_hold,
                               uint32_t *held_ms,
                               void (*on_progress)(uint8_t pct, void *ctx),
                               void *ctx);

/** Wait for a short click (press+release). Returns false on timeout. */
bool tank_board_wait_click(uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif
