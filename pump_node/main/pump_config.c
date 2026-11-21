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
#define NVS_KEY_USAGE "usage"
#define NVS_KEY_NAME "name"
#define DEFAULT_BUZZ_FLAGS \
    (PUMP_BUZZ_FLAG_ENABLED | PUMP_BUZZ_FLAG_ON_BUTTON | PUMP_BUZZ_FLAG_ON_PUMP | \
     PUMP_BUZZ_FLAG_ON_AUTO)

static pump_config_t s_cfg;
static pump_usage_t s_usage;
static char s_name[PUMP_NAME_MAX + 1];

static void usage_defaults(pump_usage_t *u)
{
    memset(u, 0, sizeof(*u));
    u->watts = PUMP_USAGE_WATTS_DEFAULT;
    memcpy(u->currency, "\xE2\x82\xB9", 3); /* ₹ */
}

static void load_usage(void)
{
    usage_defaults(&s_usage);
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    size_t len = sizeof(s_usage);
    if (nvs_get_blob(h, NVS_KEY_USAGE, &s_usage, &len) != ESP_OK || len != sizeof(s_usage)) {
        usage_defaults(&s_usage);
    }
    nvs_close(h);
}

static void load_name(void)
{
    s_name[0] = '\0';
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    size_t len = sizeof(s_name);
    if (nvs_get_str(h, NVS_KEY_NAME, s_name, &len) != ESP_OK) {
        s_name[0] = '\0';
    }
    nvs_close(h);
}

const char *pump_config_name(void)
{
    return s_name;
}

/** Well-formed UTF-8 (so a name is never cut in the middle of a character). */
static bool utf8_valid(const uint8_t *s, size_t n)
{
    for (size_t i = 0; i < n;) {
        const uint8_t c = s[i];
        size_t extra;
        if (c < 0x80) {
            extra = 0;
        } else if ((c >> 5) == 0x6) {
            extra = 1;
        } else if ((c >> 4) == 0xE) {
            extra = 2;
        } else if ((c >> 3) == 0x1E) {
            extra = 3;
        } else {
            return false;
        }
        for (size_t k = 1; k <= extra; k++) {
            if (i + k >= n || (s[i + k] & 0xC0) != 0x80) { /* also: cut off mid-character */
                return false;
            }
        }
        i += extra + 1;
    }
    return true;
}

esp_err_t pump_config_set_name(const uint8_t *utf8, size_t len)
{
    while (len > 0 && utf8[0] == ' ') {
        utf8++;
        len--;
    }
    while (len > 0 && utf8[len - 1] == ' ') {
        len--;
    }
    if (!utf8 || len == 0 || len > PUMP_NAME_MAX || !utf8_valid(utf8, len)) {
        return ESP_ERR_INVALID_ARG;
    }
    for (size_t i = 0; i < len; i++) {
        if (utf8[i] < 0x20 || utf8[i] == 0x7f) {
            return ESP_ERR_INVALID_ARG;
        }
    }
    char name[PUMP_NAME_MAX + 1];
    memcpy(name, utf8, len);
    name[len] = '\0';
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_str(h, NVS_KEY_NAME, name);
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    if (err == ESP_OK) {
        memcpy(s_name, name, sizeof(s_name));
    }
    return err;
}

const pump_usage_t *pump_config_usage(void)
{
    return &s_usage;
}

esp_err_t pump_config_set_usage(const pump_usage_t *usage)
{
    if (!usage) {
        return ESP_ERR_INVALID_ARG;
    }
    s_usage = *usage;
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY_USAGE, &s_usage, sizeof(s_usage));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

static void load_defaults(pump_config_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->magic = PUMP_CONFIG_MAGIC;
    cfg->dist_empty_cm = 120;
    cfg->dist_full_cm = 20;
    cfg->dist_low_cm = 100;
    cfg->dist_high_cm = 30;
    cfg->time_unix = 0;
    cfg->buzzer_flags = DEFAULT_BUZZ_FLAGS;
    cfg->buzzer_tone = BUZZER_TONE_CLICK;
    cfg->led_brightness = PUMP_LED_BRIGHTNESS_DEFAULT;
    cfg->starter_type = PUMP_STARTER_NONE;
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
    load_usage();
    load_name();

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

    /* Keep values in range if the blob holds something unexpected. */
    s_cfg.led_brightness = clamp_led_bri(s_cfg.led_brightness);
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
    pump_usage_t usage;
    usage_defaults(&usage);
    (void)pump_config_set_usage(&usage);
    s_name[0] = '\0';
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_key(h, NVS_KEY_NAME);
        nvs_commit(h);
        nvs_close(h);
    }
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

bool pump_config_auto_update(void)
{
    return s_cfg.auto_update != 0;
}

esp_err_t pump_config_set_auto_update(bool on)
{
    s_cfg.auto_update = on ? 1 : 0;
    return pump_config_set(&s_cfg);
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

void pump_config_log(void)
{
    ESP_LOGI(TAG,
             "empty=%ucm full=%ucm buzz_flags=0x%02x tone=%u led=%u starter=%u pulse=%ums",
             s_cfg.dist_empty_cm, s_cfg.dist_full_cm,
             s_cfg.buzzer_flags, s_cfg.buzzer_tone, s_cfg.led_brightness,
             s_cfg.starter_type, (unsigned)pump_config_relay_pulse_ms());
}
