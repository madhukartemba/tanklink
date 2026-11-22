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

/* The settings the app writes in one go (Settings characteristic). */
typedef struct {
    uint8_t buzzer_flags;    /* PUMP_BUZZ_FLAG_* */
    uint8_t buzzer_tone;     /* buzzer_tone_t */
    uint8_t led_brightness;  /* 1-100 */
    uint8_t starter_type;    /* pump_starter_type_t */
    uint16_t relay_pulse_ms; /* PUMP_RELAY_PULSE_MS_MIN-MAX */
    bool auto_update;        /* install pump updates by itself (Wi-Fi) */
} pump_settings_t;

esp_err_t pump_config_init(void);

const char *pump_config_name(void);
/** Save the name: [len] bytes of valid UTF-8, 1 to PUMP_NAME_MAX, no control
 * characters; leading and trailing spaces are dropped. */
esp_err_t pump_config_set_name(const uint8_t *utf8, size_t len);

const pump_usage_t *pump_config_usage(void);
esp_err_t pump_config_set_usage(const pump_usage_t *usage);
/** Check every field, then save them all with one write. Nothing changes
 * (in flash or in effect) if any field is out of range. */
esp_err_t pump_config_set_settings(const pump_settings_t *settings);

uint8_t pump_config_buzzer_flags(void);
uint8_t pump_config_buzzer_tone(void);
bool pump_config_buzzer_on_button(void);
bool pump_config_buzzer_on_pump(void);
bool pump_config_buzzer_on_auto(void);

uint8_t pump_config_led_brightness(void);
void pump_config_apply_led(void);

uint8_t pump_config_starter_type(void);
bool pump_config_auto_update(void);
uint16_t pump_config_relay_pulse_ms(void);

#ifdef __cplusplus
}
#endif
