#include "pump_config.h"

#include <string.h>

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "relay_control.h"
#include "status_led.h"

#define TAG "PUMP_CFG"
#define NVS_NAMESPACE "pump"
#define NVS_KEY "cfg"
#define DEFAULT_AUTO_OFF_MIN 30
#define DEFAULT_BUZZ_FLAGS \
    (PUMP_BUZZ_FLAG_ENABLED | PUMP_BUZZ_FLAG_ON_BUTTON | PUMP_BUZZ_FLAG_ON_PUMP | \
     PUMP_BUZZ_FLAG_ON_AUTO)

static pump_config_t s_cfg;

static void load_defaults(pump_config_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->magic = PUMP_CONFIG_MAGIC;
    cfg->dist_empty_cm = 120;
    cfg->dist_full_cm = 20;
    cfg->dist_low_cm = 100;
    cfg->dist_high_cm = 30;
    cfg->time_unix = 0;
    cfg->auto_off_min = DEFAULT_AUTO_OFF_MIN;
    cfg->buzzer_flags = DEFAULT_BUZZ_FLAGS;
    cfg->buzzer_tone = BUZZER_TONE_CLICK;
    cfg->led_brightness = PUMP_LED_BRIGHTNESS_DEFAULT;
    cfg->starter_type = PUMP_STARTER_NONE;
    cfg->empty_float = 0;
    cfg->relay_pulse_ms = PUMP_RELAY_PULSE_MS_DEFAULT;
}

static uint8_t clamp_led_bri(uint8_t percent)
{
    if (percent < 1) {
        return PUMP_LED_BRIGHTNESS_DEFAULT;
    }
    if (percent > 100) {
        return 100;
    }
    return percent;
}

static uint16_t clamp_pulse_ms(uint32_t ms)
{
    if (ms == 0) {
        return PUMP_RELAY_PULSE_MS_DEFAULT;
    }
    if (ms < PUMP_RELAY_PULSE_MS_MIN) {
        return PUMP_RELAY_PULSE_MS_MIN;
    }
    if (ms > PUMP_RELAY_PULSE_MS_MAX) {
        return PUMP_RELAY_PULSE_MS_MAX;
    }
    return (uint16_t)ms;
}

esp_err_t pump_config_init(void)
{
    load_defaults(&s_cfg);

    nvs_handle_t handle;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "No saved config; using defaults");
        err = pump_config_set(&s_cfg);
        pump_config_apply_buzzer();
        pump_config_apply_led();
        return err;
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        return err;
    }

    size_t len = sizeof(s_cfg);
    err = nvs_get_blob(handle, NVS_KEY, &s_cfg, &len);
    nvs_close(handle);

    if (err == ESP_ERR_NVS_NOT_FOUND || s_cfg.magic != PUMP_CONFIG_MAGIC || len != sizeof(s_cfg)) {
        ESP_LOGW(TAG, "Invalid/missing blob; resetting defaults");
        load_defaults(&s_cfg);
        err = pump_config_set(&s_cfg);
        pump_config_apply_buzzer();
        pump_config_apply_led();
        return err;
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_get_blob failed: %s", esp_err_to_name(err));
        load_defaults(&s_cfg);
        return err;
    }

    /* Old blobs used this byte as reserved (0) — promote to default. */
    s_cfg.led_brightness = clamp_led_bri(s_cfg.led_brightness);
    /* Older blobs left relay_pulse_ms as 0 (former reserved dword). */
    s_cfg.relay_pulse_ms = clamp_pulse_ms(s_cfg.relay_pulse_ms);

    pump_config_apply_buzzer();
    pump_config_apply_led();
    pump_config_log();
    return ESP_OK;
}

const pump_config_t *pump_config_get(void)
{
    return &s_cfg;
}

esp_err_t pump_config_reset_defaults(void)
{
    load_defaults(&s_cfg);
    return pump_config_set(&s_cfg);
}

esp_err_t pump_config_set(const pump_config_t *cfg)
{
    if (!cfg) {
        return ESP_ERR_INVALID_ARG;
    }

    s_cfg = *cfg;
    s_cfg.magic = PUMP_CONFIG_MAGIC;

    nvs_handle_t handle;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_set_blob(handle, NVS_KEY, &s_cfg, sizeof(s_cfg));
    if (err == ESP_OK) {
        err = nvs_commit(handle);
    }
    nvs_close(handle);

    if (err == ESP_OK) {
        pump_config_apply_buzzer();
        pump_config_apply_led();
        pump_config_log();
    }
    return err;
}

esp_err_t pump_config_set_time_unix(int64_t unix_sec)
{
    s_cfg.time_unix = unix_sec;
    return pump_config_set(&s_cfg);
}

esp_err_t pump_config_set_auto_off_min(uint8_t minutes)
{
    if (minutes > 240) {
        minutes = 240;
    }
    s_cfg.auto_off_min = minutes;
    return pump_config_set(&s_cfg);
}

uint8_t pump_config_auto_off_min(void)
{
    return s_cfg.auto_off_min;
}

uint8_t pump_config_buzzer_flags(void)
{
    return s_cfg.buzzer_flags;
}

uint8_t pump_config_buzzer_tone(void)
{
    return s_cfg.buzzer_tone;
}

esp_err_t pump_config_set_buzzer(uint8_t flags, uint8_t tone)
{
    if (tone >= BUZZER_TONE_COUNT) {
        tone = BUZZER_TONE_CLICK;
    }
    s_cfg.buzzer_flags = flags;
    s_cfg.buzzer_tone = tone;
    return pump_config_set(&s_cfg);
}

bool pump_config_buzzer_on_button(void)
{
    return (s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ENABLED) &&
           (s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ON_BUTTON);
}

bool pump_config_buzzer_on_pump(void)
{
    return (s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ENABLED) &&
           (s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ON_PUMP);
}

bool pump_config_buzzer_on_auto(void)
{
    return (s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ENABLED) &&
           (s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ON_AUTO);
}

void pump_config_apply_buzzer(void)
{
    buzzer_set_enabled((s_cfg.buzzer_flags & PUMP_BUZZ_FLAG_ENABLED) != 0);
    buzzer_set_user_tone((buzzer_tone_t)s_cfg.buzzer_tone);
}

uint8_t pump_config_led_brightness(void)
{
    return clamp_led_bri(s_cfg.led_brightness);
}

esp_err_t pump_config_set_led_brightness(uint8_t percent)
{
    s_cfg.led_brightness = clamp_led_bri(percent);
    return pump_config_set(&s_cfg);
}

void pump_config_apply_led(void)
{
    status_led_set_brightness(pump_config_led_brightness());
}

uint8_t pump_config_starter_type(void)
{
    if (s_cfg.starter_type >= PUMP_STARTER_COUNT) {
        return PUMP_STARTER_NONE;
    }
    return s_cfg.starter_type;
}

esp_err_t pump_config_set_starter_type(uint8_t type)
{
    if (type >= PUMP_STARTER_COUNT) {
        return ESP_ERR_INVALID_ARG;
    }
    s_cfg.starter_type = type;
    esp_err_t err = pump_config_set(&s_cfg);
    if (err == ESP_OK) {
        (void)relay_control_set_type((pump_starter_type_t)type);
    }
    return err;
}

uint16_t pump_config_relay_pulse_ms(void)
{
    return clamp_pulse_ms(s_cfg.relay_pulse_ms);
}

esp_err_t pump_config_set_relay_pulse_ms(uint16_t ms)
{
    s_cfg.relay_pulse_ms = clamp_pulse_ms(ms);
    esp_err_t err = pump_config_set(&s_cfg);
    if (err == ESP_OK) {
        relay_control_set_pulse_ms(pump_config_relay_pulse_ms());
    }
    return err;
}

uint8_t pump_config_empty_float(void)
{
    return s_cfg.empty_float ? 1 : 0;
}

esp_err_t pump_config_set_empty_float(uint8_t connected)
{
    s_cfg.empty_float = connected ? 1 : 0;
    return pump_config_set(&s_cfg);
}

void pump_config_log(void)
{
    ESP_LOGI(TAG,
             "empty=%ucm full=%ucm auto_off=%umin buzz_flags=0x%02x tone=%u led=%u starter=%u pulse=%ums empty_float=%u",
             s_cfg.dist_empty_cm, s_cfg.dist_full_cm, s_cfg.auto_off_min,
             s_cfg.buzzer_flags, s_cfg.buzzer_tone, s_cfg.led_brightness,
             s_cfg.starter_type, (unsigned)pump_config_relay_pulse_ms(),
             s_cfg.empty_float);
}
