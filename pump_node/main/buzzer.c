#include "buzzer.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
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
void buzzer_play(buzzer_sound_t sound)
{
    (void)sound;
}

#else

/* On/off times in ms, alternating, starting with on; 0 ends the pattern.
 * An active buzzer only has timing, so the patterns differ a lot. */
#define MAX_STEPS 12
static const uint16_t s_patterns[BUZZER_SOUND_COUNT][MAX_STEPS] = {
    [BUZZER_SOUND_CLICK] = {70},
    [BUZZER_SOUND_TICK] = {20},
    [BUZZER_SOUND_LONG] = {280},
    [BUZZER_SOUND_DOUBLE] = {55, 90, 55},
    [BUZZER_SOUND_TRIPLE] = {45, 70, 45, 70, 45},
    [BUZZER_SOUND_RISING] = {50, 80, 50, 80, 220},
    [BUZZER_SOUND_FALLING] = {220, 100, 60},
    [BUZZER_SOUND_CHIRP] = {25, 35, 25, 35, 25, 35, 25},
    [BUZZER_SOUND_ALARM] = {120, 120, 120, 120, 120, 120, 120, 120, 120, 120, 120},
};

static QueueHandle_t s_queue;

static void set_level(int level)
{
    gpio_set_level(CONFIG_PUMP_BUZZER_GPIO, level);
}

static void buzzer_task(void *arg)
{
    (void)arg;
    uint8_t sound;
    while (1) {
        if (xQueueReceive(s_queue, &sound, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        const uint16_t *p = s_patterns[sound];
        for (int i = 0; i < MAX_STEPS && p[i] != 0; i++) {
            set_level((i & 1) == 0);
            vTaskDelay(pdMS_TO_TICKS(p[i]));
        }
        set_level(0);
        /* A gap, so two queued sounds stay two sounds. */
        vTaskDelay(pdMS_TO_TICKS(120));
    }
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
    s_queue = xQueueCreate(3, sizeof(uint8_t));
    if (!s_queue || xTaskCreate(buzzer_task, "buzzer", 2048, NULL, 4, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "GPIO %d (active)", CONFIG_PUMP_BUZZER_GPIO);
    return ESP_OK;
}

void buzzer_play(buzzer_sound_t sound)
{
    if (sound >= BUZZER_SOUND_COUNT || !s_queue) {
        return;
    }
    const uint8_t b = (uint8_t)sound;
    xQueueSend(s_queue, &b, 0);
}

#endif /* CONFIG_PUMP_ENABLE_BUZZER */
