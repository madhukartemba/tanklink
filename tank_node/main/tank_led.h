#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_led_init(int gpio);
void tank_led_set(bool on);
/** 0–100 percent brightness (soft PWM). */
void tank_led_set_brightness(uint8_t pct);
void tank_led_off(void);

void tank_led_fade_to(uint8_t pct, uint32_t ms);
void tank_led_fade_in_out(uint8_t peak_pct, uint32_t up_ms, uint32_t down_ms);
void tank_led_blink(int times, int on_ms, int off_ms);
void tank_led_tx_pulse(void);
void tank_led_boot(void);
void tank_led_success(void);
void tank_led_failure(void);
void tank_led_pairing_flash_start(void);
/** Non-blocking-ish flash step; call often while pairing. */
void tank_led_pairing_flash_tick(void);
void tank_led_pairing_flash_stop(void);

/**
 * LED error code: N long hard blinks, pause, repeat twice.
 * Soft pulses are reserved for boot / TX / success / pairing (see docs/ERROR_CODES.md).
 */
void tank_led_show_error(uint8_t code);

#ifdef __cplusplus
}
#endif
