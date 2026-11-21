#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "buzzer.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_CONFIG_MAGIC 0x50554D54u /* 'PUMT': auto-off moved to tank slots */

#define PUMP_BUZZ_FLAG_ENABLED   (1u << 0)
#define PUMP_BUZZ_FLAG_ON_BUTTON (1u << 1)
#define PUMP_BUZZ_FLAG_ON_PUMP   (1u << 2)
#define PUMP_BUZZ_FLAG_ON_AUTO   (1u << 3)

#define PUMP_LED_BRIGHTNESS_DEFAULT 70
#define PUMP_RELAY_PULSE_MS_DEFAULT 1000
#define PUMP_RELAY_PULSE_MS_MIN 50
#define PUMP_RELAY_PULSE_MS_MAX 2000

/* The pump's own name, shown by every phone that has it. UTF-8, up to this many
 * bytes, no control characters. Empty until someone names it. */
#define PUMP_NAME_MAX 24

/* What the app needs to turn run time into litres and cost. Saved under its
 * own key, so changing it never touches the other settings. */
#define PUMP_USAGE_CURRENCY_LEN 4
#define PUMP_USAGE_WATTS_DEFAULT 750
typedef struct {
    uint16_t flow_dlpm;   /* pump flow in tenths of a litre a minute, 0 = not set */
    uint16_t watts;       /* pump power */
    uint16_t price_centi; /* price of a kWh in hundredths, 0 = not set */
    char currency[PUMP_USAGE_CURRENCY_LEN]; /* UTF-8, NUL-padded, e.g. "\xE2\x82\xB9" (₹) */
} pump_usage_t;

typedef struct {
    uint32_t magic;
    uint16_t dist_empty_cm;
    uint16_t dist_full_cm;
    uint16_t dist_low_cm;
    uint16_t dist_high_cm;
    int64_t time_unix;
    uint8_t buzzer_flags; /* PUMP_BUZZ_FLAG_* */
    uint8_t buzzer_tone;  /* buzzer_tone_t */
    uint8_t led_brightness; /* 1-100; 0 treated as default on load */
    uint8_t starter_type;   /* pump_starter_type_t */
    uint8_t auto_update;    /* 1 = install pump updates by itself at night (Wi-Fi) */
    uint8_t reserved_u8[3];
    uint32_t relay_pulse_ms; /* 50-2000; 0 = default on load */
    uint32_t reserved;
} pump_config_t;

esp_err_t pump_config_init(void);
const pump_config_t *pump_config_get(void);
esp_err_t pump_config_set(const pump_config_t *cfg);
/** Restore factory defaults and persist. */
esp_err_t pump_config_reset_defaults(void);

const char *pump_config_name(void);
/** Save the name: [len] bytes of valid UTF-8, 1 to PUMP_NAME_MAX, no control
 * characters; leading and trailing spaces are dropped. */
esp_err_t pump_config_set_name(const uint8_t *utf8, size_t len);

const pump_usage_t *pump_config_usage(void);
esp_err_t pump_config_set_usage(const pump_usage_t *usage);
esp_err_t pump_config_set_time_unix(int64_t unix_sec);

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

bool pump_config_auto_update(void);
esp_err_t pump_config_set_auto_update(bool on);

uint16_t pump_config_relay_pulse_ms(void);
esp_err_t pump_config_set_relay_pulse_ms(uint16_t ms);

/** 0 off, 1 almost-empty, 2 two tanks. */

void pump_config_log(void);

#ifdef __cplusplus
}
#endif
