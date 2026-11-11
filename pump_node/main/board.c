#include "board.h"

#include "esp_log.h"
#include "sdkconfig.h"
#include "status_led.h"

#if CONFIG_PUMP_ENABLE_BUTTON
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#endif

#define TAG "BOARD"

#ifndef CONFIG_PUMP_PAIRING_HOLD_MS
#define CONFIG_PUMP_PAIRING_HOLD_MS 5000
#endif

static board_button_cb_t s_click_cb;
static board_hold_progress_cb_t s_hold_cb;
static board_long_press_cb_t s_long_cb;
static bool s_pump_on;
static status_led_mode_t s_mode_before_hold = STATUS_LED_IDLE;

#if CONFIG_PUMP_ENABLE_BUTTON
static bool button_is_pressed(void)
{
    int level = gpio_get_level(CONFIG_PUMP_BUTTON_GPIO);
#if CONFIG_PUMP_BUTTON_ACTIVE_LOW
    return level == 0;
#else
    return level == 1;
#endif
}

static void button_task(void *arg)
{
    (void)arg;
    bool prev = false;
    bool long_fired = false;
    TickType_t press_start = 0;

    while (1) {
        bool pressed = button_is_pressed();
        TickType_t now = xTaskGetTickCount();

        if (pressed && !prev) {
            press_start = now;
            long_fired = false;
            s_mode_before_hold = status_led_get_mode();
            status_led_set_mode(STATUS_LED_HOLD_PROGRESS);
            status_led_set_hold_progress(0);
        }

        if (pressed && prev && !long_fired) {
            uint32_t held_ms = (now - press_start) * portTICK_PERIOD_MS;
            uint8_t pct = (uint8_t)((held_ms * 100) / CONFIG_PUMP_PAIRING_HOLD_MS);
            if (pct > 100) {
                pct = 100;
            }
            if (s_hold_cb) {
                s_hold_cb(pct);
            }
            status_led_set_hold_progress(pct);

            if (held_ms >= CONFIG_PUMP_PAIRING_HOLD_MS) {
                long_fired = true;
                ESP_LOGI(TAG, "Long press %u ms → pairing", (unsigned)held_ms);
                if (s_long_cb) {
                    s_long_cb();
                }
            }
        }

        if (!pressed && prev) {
            uint32_t held_ms = (now - press_start) * portTICK_PERIOD_MS;
            if (!long_fired && held_ms >= 30 && held_ms < CONFIG_PUMP_PAIRING_HOLD_MS) {
                if (s_click_cb) {
                    s_click_cb();
                }
                status_led_set_mode(s_mode_before_hold);
            }
            /* long press: pairing mode owns LED */
        }

        prev = pressed;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
#endif

esp_err_t board_init(void)
{
    esp_err_t err = status_led_init();
    if (err != ESP_OK) {
        return err;
    }

#if CONFIG_PUMP_ENABLE_BUTTON
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << CONFIG_PUMP_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
#if CONFIG_PUMP_BUTTON_ACTIVE_LOW
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
#else
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
#endif
        .intr_type = GPIO_INTR_DISABLE,
    };
    err = gpio_config(&io);
    if (err != ESP_OK) {
        return err;
    }

    if (xTaskCreate(button_task, "pump_btn", 3072, NULL, 5, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "Button GPIO %d (hold %d ms → pairing)", CONFIG_PUMP_BUTTON_GPIO,
             CONFIG_PUMP_PAIRING_HOLD_MS);
#else
    ESP_LOGI(TAG, "Button disabled");
#endif

    board_set_pump_on(false);
    return ESP_OK;
}

void board_set_pump_on(bool on)
{
    s_pump_on = on;
    status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_HOLD_PROGRESS || mode == STATUS_LED_PAIRING ||
        mode == STATUS_LED_UNPAIRED) {
        return;
    }
    if (on) {
        status_led_set_mode(STATUS_LED_PUMP_ON);
    } else if (mode == STATUS_LED_CONNECTED) {
        /* keep connected glow */
    } else {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

void board_set_button_callback(board_button_cb_t cb)
{
    s_click_cb = cb;
}

void board_set_hold_progress_callback(board_hold_progress_cb_t cb)
{
    s_hold_cb = cb;
}

void board_set_long_press_callback(board_long_press_cb_t cb)
{
    s_long_cb = cb;
}
