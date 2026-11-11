#include "pump_config.h"

#include <string.h>

#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"

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
        return err;
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_get_blob failed: %s", esp_err_to_name(err));
        load_defaults(&s_cfg);
        return err;
    }

    pump_config_apply_buzzer();
    pump_config_log();
    return ESP_OK;
}

const pump_config_t *pump_config_get(void)
{
    return &s_cfg;
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

void pump_config_log(void)
{
    ESP_LOGI(TAG,
             "empty=%ucm full=%ucm auto_off=%umin buzz_flags=0x%02x tone=%u",
             s_cfg.dist_empty_cm, s_cfg.dist_full_cm, s_cfg.auto_off_min,
             s_cfg.buzzer_flags, s_cfg.buzzer_tone);
}
