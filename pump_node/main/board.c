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

static board_button_cb_t s_start_cb;
static board_button_cb_t s_stop_cb;
static board_hold_progress_cb_t s_hold_cb;
static board_long_press_cb_t s_long_cb;
static bool s_pump_on;
static status_led_mode_t s_mode_before_hold = STATUS_LED_IDLE;

#if CONFIG_PUMP_ENABLE_BUTTON

static bool gpio_is_pressed(int gpio)
{
    int level = gpio_get_level(gpio);
#if CONFIG_PUMP_BUTTON_ACTIVE_LOW
    return level == 0;
#else
    return level == 1;
#endif
}

static void enter_hold_progress(void)
{
    s_mode_before_hold = status_led_get_mode();
    status_led_set_mode(STATUS_LED_HOLD_PROGRESS);
    status_led_set_hold_progress(0);
}

static void leave_hold_progress_if_needed(void)
{
    if (status_led_get_mode() == STATUS_LED_HOLD_PROGRESS) {
        status_led_set_mode(s_mode_before_hold);
    }
}

static void button_task(void *arg)
{
    (void)arg;
    bool prev_start = false;
    bool prev_stop = false;
    bool both_active = false;
    bool long_fired = false;
    bool suppress_clicks = false;
    TickType_t both_start = 0;
    TickType_t start_down = 0;
    TickType_t stop_down = 0;

    while (1) {
        const bool start = gpio_is_pressed(CONFIG_PUMP_BUTTON_START_GPIO);
        const bool stop = gpio_is_pressed(CONFIG_PUMP_BUTTON_STOP_GPIO);
        const bool both = start && stop;
        TickType_t now = xTaskGetTickCount();

        if (start && !prev_start) {
            start_down = now;
        }
        if (stop && !prev_stop) {
            stop_down = now;
        }

        if (both && !both_active) {
            both_active = true;
            long_fired = false;
            suppress_clicks = true;
            both_start = now;
            enter_hold_progress();
        }

        if (both_active && both && !long_fired) {
            uint32_t held_ms = (now - both_start) * portTICK_PERIOD_MS;
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
                ESP_LOGI(TAG, "Both held %u ms → BLE pairing", (unsigned)held_ms);
                if (s_long_cb) {
                    s_long_cb();
                }
            }
        }

        if (both_active && !both) {
            if (!long_fired) {
                leave_hold_progress_if_needed();
            }
            both_active = false;
        }

        /* Use suppress from before clearing so the release that ends a
         * dual-hold session does not fire Start/Stop. */
        const bool allow_clicks = !suppress_clicks && !both_active;
        if (!start && !stop) {
            suppress_clicks = false;
        }

        if (allow_clicks && prev_start && !start && !stop) {
            uint32_t held_ms = (now - start_down) * portTICK_PERIOD_MS;
            if (held_ms >= 30 && held_ms < CONFIG_PUMP_PAIRING_HOLD_MS && s_start_cb) {
                s_start_cb();
            }
        }

        if (allow_clicks && prev_stop && !stop && !start) {
            uint32_t held_ms = (now - stop_down) * portTICK_PERIOD_MS;
            if (held_ms >= 30 && held_ms < CONFIG_PUMP_PAIRING_HOLD_MS && s_stop_cb) {
                s_stop_cb();
            }
        }

        prev_start = start;
        prev_stop = stop;
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
        .pin_bit_mask = (1ULL << CONFIG_PUMP_BUTTON_START_GPIO) |
                        (1ULL << CONFIG_PUMP_BUTTON_STOP_GPIO),
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
    ESP_LOGI(TAG, "Start GPIO %d / Stop GPIO %d (hold both %d ms → BLE pair)",
             CONFIG_PUMP_BUTTON_START_GPIO, CONFIG_PUMP_BUTTON_STOP_GPIO,
             CONFIG_PUMP_PAIRING_HOLD_MS);
#else
    ESP_LOGI(TAG, "Buttons disabled");
#endif

    board_set_pump_on(false);
    return ESP_OK;
}

void board_set_pump_on(bool on)
{
    s_pump_on = on;
    status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_HOLD_PROGRESS || mode == STATUS_LED_PAIRING ||
        mode == STATUS_LED_TANK_PAIRING || mode == STATUS_LED_UNPAIRED) {
        return;
    }
    if (on) {
        status_led_set_mode(STATUS_LED_PUMP_ON);
    } else {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

void board_set_start_callback(board_button_cb_t cb)
{
    s_start_cb = cb;
}

void board_set_stop_callback(board_button_cb_t cb)
{
    s_stop_cb = cb;
}

void board_set_hold_progress_callback(board_hold_progress_cb_t cb)
{
    s_hold_cb = cb;
}

void board_set_long_press_callback(board_long_press_cb_t cb)
{
    s_long_cb = cb;
}
