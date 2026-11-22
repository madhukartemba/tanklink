#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "esp_sleep.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool sensor1; /* first float; true when HIGH. Meaning is decided on the pump. */
    bool sensor2; /* second float; true when HIGH. Meaning is decided on the pump. */
    bool button_down; /* true while held (active low) */
} tank_inputs_t;

esp_err_t tank_board_init(void);
void tank_board_read(tank_inputs_t *out);
int tank_board_led_gpio(void);
bool tank_board_button_down(void);
/** How long the button has been down without a break, 0 when up. */
uint32_t tank_board_button_held_ms(void);

/** The button is down and it is a real press: false while it is still down
 * from before the last sleep (held or stuck). */
bool tank_board_button_pressed(void);

/**
 * Configure deep-sleep wake sources: always a timer wake of [timer_sec], the
 * button unless it is down right now, and with [float_wake] a change of
 * either float (the opposite of the level sampled now).
 */
void tank_board_prepare_deep_sleep(uint32_t timer_sec, bool float_wake);

esp_sleep_wakeup_cause_t tank_board_wakeup_cause(void);
typedef enum {
    TANK_BTN_WAKE_NONE = 0, /* not woken by the button (timer, a float) */
    TANK_BTN_WAKE_PRESS,    /* a press: handle it */
    TANK_BTN_WAKE_RELEASE,  /* a button held at sleep was let go: just sleep again */
} tank_button_wake_t;

/** What the button had to do with this wake. Call once, early. */
tank_button_wake_t tank_board_button_wake(void);
/** After TANK_BTN_WAKE_RELEASE: how long that press lasted, from its start
 * before the sleep to the release that woke the tank. */
uint32_t tank_board_release_held_ms(void);
bool tank_board_woke_from_timer(void);

/** Button-hold watcher. A gap shorter than the release debounce stays a hold. */
typedef struct {
    int64_t hold_start_us;
    int64_t up_since_us;
    bool active;
} tank_button_hold_t;

typedef enum {
    TANK_HOLD_NONE = 0,    /* button is up, and was not just released */
    TANK_HOLD_HOLDING,     /* down, or a bounce shorter than the release gap */
    TANK_HOLD_RELEASED,    /* released before the threshold */
    TANK_HOLD_REACHED,     /* held for the threshold; still down */
} tank_button_hold_event_t;

void tank_button_hold_reset(tank_button_hold_t *hold);

/**
 * Call about every 20 ms. *held_ms and *pct (0–100) are filled when the
 * button is part of a press. TANK_HOLD_REACHED fires as soon as the threshold
 * is met and does not wait for release.
 */
tank_button_hold_event_t tank_button_hold_poll(tank_button_hold_t *hold,
                                               uint32_t threshold_ms,
                                               uint32_t *held_ms, uint8_t *pct);

/**
 * Returns as soon as the hold threshold is met (*is_hold true).
 * A shorter press returns after release with *is_hold false.
 * If the button is already up, that is a short press (held 0).
 */
void tank_board_classify_button(uint32_t hold_threshold_ms, bool *is_hold,
                               uint32_t *held_ms,
                               void (*on_progress)(uint8_t pct, void *ctx),
                               void *ctx);

#ifdef __cplusplus
}
#endif
