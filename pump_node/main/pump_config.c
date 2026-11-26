#include "pump_config.h"

#include <string.h>

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "relay_control.h"
#include "sdkconfig.h"
#include "status_led.h"
#include "tanklink_lora_proto.h"

#define TAG "PUMP_CFG"
#define NVS_NAMESPACE "pump"
#define NVS_KEY "cfg"
#define NVS_KEY_USAGE "usage"
#define NVS_KEY_NAME "name"
#define NVS_KEY_BEAT "tank_beat"

static pump_usage_t s_usage;
static uint16_t s_beat_sec = TANKLINK_LORA_BEAT_DEFAULT_SEC;

static bool beat_valid(uint16_t sec)
{
    return sec >= TANKLINK_LORA_BEAT_MIN_SEC && sec <= TANKLINK_LORA_BEAT_MAX_SEC;
}

static void load_beat(void)
{
    s_beat_sec = TANKLINK_LORA_BEAT_DEFAULT_SEC;
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    uint16_t sec = 0;
    if (nvs_get_u16(h, NVS_KEY_BEAT, &sec) == ESP_OK && beat_valid(sec)) {
        s_beat_sec = sec;
    }
    nvs_close(h);
}

uint16_t pump_config_tank_beat_sec(void)
{
    return s_beat_sec;
}

esp_err_t pump_config_set_tank_beat_sec(uint16_t sec)
{
    if (!beat_valid(sec)) {
        return ESP_ERR_INVALID_ARG;
    }
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_u16(h, NVS_KEY_BEAT, sec);
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    if (err == ESP_OK) {
        s_beat_sec = sec;
        ESP_LOGI(TAG, "tank update interval %us", (unsigned)sec);
    }
    return err;
}
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
    if (!utf8) {
        return ESP_ERR_INVALID_ARG;
    }
    while (len > 0 && utf8[0] == ' ') {
        utf8++;
        len--;
    }
    while (len > 0 && utf8[len - 1] == ' ') {
        len--;
    }
    if (len == 0 || len > PUMP_NAME_MAX || !utf8_valid(utf8, len)) {
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
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY_USAGE, usage, sizeof(*usage));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    if (err == ESP_OK) {
        s_usage = *usage;
    }
    return err;
}

/* Saved layout. The fields marked unused are kept so the blob (and its magic)
 * stays the same and saved settings survive this firmware. */
typedef struct {
    uint32_t magic;
    uint16_t unused_dist[4];
    int64_t unused_time;
    uint8_t unused_buzz[2]; /* buzzer settings moved to pump_buzz.c */
    uint8_t led_brightness; /* 1-100 */
    uint8_t starter_type;   /* pump_starter_type_t */
    uint8_t auto_update;    /* 1 = install pump updates by itself (Wi-Fi) */
    uint8_t reserved_u8[3];
    uint32_t relay_pulse_ms; /* PUMP_RELAY_PULSE_MS_MIN-MAX */
    uint32_t reserved;
} pump_config_t;

static pump_config_t s_cfg;

static void load_defaults(pump_config_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->magic = PUMP_CONFIG_MAGIC;
    cfg->led_brightness = PUMP_LED_BRIGHTNESS_DEFAULT;
    cfg->starter_type = PUMP_STARTER_NONE;
    cfg->relay_pulse_ms = CONFIG_PUMP_RELAY_PULSE_MS;
    cfg->auto_update = 1; /* on: it only acts once Wi-Fi is set up, and only when idle */
}

static bool settings_valid(uint8_t led, uint8_t starter, uint32_t pulse_ms)
{
    return led >= 1 && led <= 100 && starter < PUMP_STARTER_COUNT &&
           pulse_ms >= PUMP_RELAY_PULSE_MS_MIN && pulse_ms <= PUMP_RELAY_PULSE_MS_MAX;
}

static void apply(void)
{
    status_led_set_brightness(s_cfg.led_brightness);
}

static esp_err_t save(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY, &s_cfg, sizeof(s_cfg));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

static void log_cfg(void)
{
    ESP_LOGI(TAG, "led=%u starter=%u pulse=%ums auto_update=%u", s_cfg.led_brightness,
             s_cfg.starter_type,
             (unsigned)s_cfg.relay_pulse_ms, s_cfg.auto_update);
}

esp_err_t pump_config_init(void)
{
    load_defaults(&s_cfg);
    load_usage();
    load_name();
    load_beat();

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &h);
    if (err == ESP_OK) {
        size_t len = sizeof(s_cfg);
        err = nvs_get_blob(h, NVS_KEY, &s_cfg, &len);
        nvs_close(h);
        if (err == ESP_OK &&
            (len != sizeof(s_cfg) || s_cfg.magic != PUMP_CONFIG_MAGIC ||
             !settings_valid(s_cfg.led_brightness, s_cfg.starter_type, s_cfg.relay_pulse_ms))) {
            err = ESP_ERR_NVS_INVALID_LENGTH; /* another layout, or damaged */
        }
    }
    if (err == ESP_ERR_NVS_NOT_FOUND || err == ESP_ERR_NVS_INVALID_LENGTH) {
        ESP_LOGW(TAG, "no valid settings saved; using defaults");
        load_defaults(&s_cfg);
        err = save();
    } else if (err != ESP_OK) {
        /* A read error: run on defaults, but don't save over what is there. */
        ESP_LOGE(TAG, "settings read failed: %s", esp_err_to_name(err));
        load_defaults(&s_cfg);
    }
    apply();
    log_cfg();
    return err;
}

esp_err_t pump_config_set_settings(const pump_settings_t *in)
{
    if (!in || !settings_valid(in->led_brightness, in->starter_type, in->relay_pulse_ms)) {
        return ESP_ERR_INVALID_ARG;
    }
    const pump_config_t before = s_cfg;
    s_cfg.led_brightness = in->led_brightness;
    s_cfg.starter_type = in->starter_type;
    s_cfg.relay_pulse_ms = in->relay_pulse_ms;
    s_cfg.auto_update = in->auto_update ? 1 : 0;
    const esp_err_t err = save(); /* NVS skips the write when nothing changed */
    if (err != ESP_OK) {
        s_cfg = before;
        return err;
    }
    apply();
    relay_control_set_pulse_ms(in->relay_pulse_ms);
    ESP_ERROR_CHECK(relay_control_set_type((pump_starter_type_t)in->starter_type));
    log_cfg();
    return ESP_OK;
}

uint8_t pump_config_led_brightness(void)
{
    return s_cfg.led_brightness;
}

void pump_config_apply_led(void)
{
    status_led_set_brightness(s_cfg.led_brightness);
}

uint8_t pump_config_starter_type(void)
{
    return s_cfg.starter_type;
}

bool pump_config_auto_update(void)
{
    return s_cfg.auto_update != 0;
}

uint16_t pump_config_relay_pulse_ms(void)
{
    return (uint16_t)s_cfg.relay_pulse_ms;
}
