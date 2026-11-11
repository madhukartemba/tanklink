#include "buzzer.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "sdkconfig.h"

#define TAG "BUZZER"

#if !CONFIG_PUMP_ENABLE_BUZZER

esp_err_t buzzer_init(void)
{
    ESP_LOGI(TAG, "disabled");
    return ESP_OK;
}
void buzzer_set_enabled(bool enabled)
{
    (void)enabled;
}
bool buzzer_enabled(void)
{
    return false;
}
void buzzer_set_user_tone(buzzer_tone_t tone)
{
    (void)tone;
}
buzzer_tone_t buzzer_user_tone(void)
{
    return BUZZER_TONE_CLICK;
}
void buzzer_play(buzzer_tone_t tone, bool force)
{
    (void)tone;
    (void)force;
}
void buzzer_play_user(bool force)
{
    (void)force;
}
void buzzer_off(void) {}

#else

static bool s_enabled = true;
static buzzer_tone_t s_user_tone = BUZZER_TONE_CLICK;

static void set_level(int level)
{
    gpio_set_level(CONFIG_PUMP_BUZZER_GPIO, level);
}

static void beep_ms(uint32_t on_ms)
{
    set_level(1);
    vTaskDelay(pdMS_TO_TICKS(on_ms < 10 ? 10 : on_ms));
    set_level(0);
}

esp_err_t buzzer_init(void)
{
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << CONFIG_PUMP_BUZZER_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t err = gpio_config(&io);
    if (err != ESP_OK) {
        return err;
    }
    set_level(0);
    ESP_LOGI(TAG, "GPIO %d (active)", CONFIG_PUMP_BUZZER_GPIO);
    return ESP_OK;
}

void buzzer_set_enabled(bool enabled)
{
    s_enabled = enabled;
    if (!enabled) {
        set_level(0);
    }
}

bool buzzer_enabled(void)
{
    return s_enabled;
}

void buzzer_off(void)
{
    set_level(0);
}

void buzzer_play(buzzer_tone_t tone, bool force)
{
    if (!force && !s_enabled) {
        return;
    }
    if (tone >= BUZZER_TONE_COUNT) {
        tone = BUZZER_TONE_CLICK;
    }

    /* Active buzzer (GPIO4) — patterns must differ a lot to be audible. */
    switch (tone) {
    case BUZZER_TONE_SOFT:
        beep_ms(20);
        break;
    case BUZZER_TONE_SHARP:
        beep_ms(280);
        break;
    case BUZZER_TONE_DOUBLE:
        beep_ms(55);
        vTaskDelay(pdMS_TO_TICKS(90));
        beep_ms(55);
        break;
    case BUZZER_TONE_CLICK:
    default:
        beep_ms(70);
        break;
    }
}

void buzzer_play_user(bool force)
{
    buzzer_play(s_user_tone, force);
}

void buzzer_set_user_tone(buzzer_tone_t tone)
{
    if (tone >= BUZZER_TONE_COUNT) {
        tone = BUZZER_TONE_CLICK;
    }
    s_user_tone = tone;
}

buzzer_tone_t buzzer_user_tone(void)
{
    return s_user_tone;
}

#endif /* CONFIG_PUMP_ENABLE_BUZZER */
