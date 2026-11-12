#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "buzzer.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_CONFIG_MAGIC 0x50554D53u /* 'PUMS' — v5 starter + pulse ms */

#define PUMP_BUZZ_FLAG_ENABLED   (1u << 0)
#define PUMP_BUZZ_FLAG_ON_BUTTON (1u << 1)
#define PUMP_BUZZ_FLAG_ON_PUMP   (1u << 2)
#define PUMP_BUZZ_FLAG_ON_AUTO   (1u << 3)

#define PUMP_LED_BRIGHTNESS_DEFAULT 70
#define PUMP_RELAY_PULSE_MS_DEFAULT 400
#define PUMP_RELAY_PULSE_MS_MIN 50
#define PUMP_RELAY_PULSE_MS_MAX 2000

typedef struct {
    uint32_t magic;
    uint16_t dist_empty_cm;
    uint16_t dist_full_cm;
    uint16_t dist_low_cm;
    uint16_t dist_high_cm;
    int64_t time_unix;
    uint8_t auto_off_min;
    uint8_t buzzer_flags; /* PUMP_BUZZ_FLAG_* */
    uint8_t buzzer_tone;  /* buzzer_tone_t */
    uint8_t led_brightness; /* 1-100; 0 treated as default on load */
    uint8_t starter_type;   /* pump_starter_type_t */
    uint8_t reserved_u8[3];
    uint32_t relay_pulse_ms; /* 50-2000; 0 = default on load */
    uint32_t reserved;
} pump_config_t;

esp_err_t pump_config_init(void);
const pump_config_t *pump_config_get(void);
esp_err_t pump_config_set(const pump_config_t *cfg);
/** Restore factory defaults and persist. */
esp_err_t pump_config_reset_defaults(void);
esp_err_t pump_config_set_time_unix(int64_t unix_sec);
esp_err_t pump_config_set_auto_off_min(uint8_t minutes);
uint8_t pump_config_auto_off_min(void);

uint8_t pump_config_buzzer_flags(void);
uint8_t pump_config_buzzer_tone(void);
esp_err_t pump_config_set_buzzer(uint8_t flags, uint8_t tone);
bool pump_config_buzzer_on_button(void);
bool pump_config_buzzer_on_pump(void);
bool pump_config_buzzer_on_auto(void);

/** Apply NVS buzzer settings into the buzzer driver. */
void pump_config_apply_buzzer(void);

uint8_t pump_config_led_brightness(void);
esp_err_t pump_config_set_led_brightness(uint8_t percent);
void pump_config_apply_led(void);

uint8_t pump_config_starter_type(void);
esp_err_t pump_config_set_starter_type(uint8_t type);

uint16_t pump_config_relay_pulse_ms(void);
esp_err_t pump_config_set_relay_pulse_ms(uint16_t ms);

void pump_config_log(void);

#ifdef __cplusplus
}
#endif
