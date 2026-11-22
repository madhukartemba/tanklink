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
#ifndef CONFIG_PUMP_FACTORY_RESET_EXTRA_MS
#define CONFIG_PUMP_FACTORY_RESET_EXTRA_MS 10000
#endif
#ifndef CONFIG_PUMP_ACTION_HOLD_MS
#define CONFIG_PUMP_ACTION_HOLD_MS 1000
#endif

static board_button_cb_t s_start_cb;
static board_button_cb_t s_stop_cb;
static board_hold_progress_cb_t s_hold_cb;
static board_long_press_cb_t s_long_cb;
static board_long_press_cb_t s_factory_cb;
static bool s_pump_on;
static status_led_mode_t s_mode_before_hold = STATUS_LED_IDLE;

#if CONFIG_PUMP_ENABLE_BUTTON

typedef enum {
    BTN_IDLE = 0,
    BTN_HOLD,
} btn_state_t;

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
    const status_led_mode_t cur = status_led_get_mode();
    if (cur != STATUS_LED_HOLD_PROGRESS) {
        s_mode_before_hold = cur;
        status_led_set_mode(STATUS_LED_HOLD_PROGRESS);
    }
    status_led_set_hold_progress(0);
}

static void leave_hold_progress_if_needed(void)
{
    if (status_led_get_mode() == STATUS_LED_HOLD_PROGRESS) {
        status_led_set_mode(s_mode_before_hold);
    }
}

static void update_hold_pct(uint32_t held_ms, uint32_t threshold_ms)
{
    if (threshold_ms == 0) {
        threshold_ms = 1;
    }
    uint8_t pct = (uint8_t)(((uint64_t)held_ms * 100) / threshold_ms);
    if (pct > 100) {
        pct = 100;
    }
    if (s_hold_cb) {
        s_hold_cb(pct);
    }
    status_led_set_hold_progress(pct);
}

/*
 * Single button:
 *   Pump running → press = OFF immediately (safety: fastest action).
 *   Pump off     → hold ≥ ACTION_HOLD_MS, then release = ON.
 *                  (Center LED fills over ACTION_HOLD_MS.)
 *   Any state    → keep holding to PAIRING_HOLD_MS = BLE pairing (no ON fired),
 *                  then FACTORY_RESET_EXTRA_MS more (red) = factory reset.
 */
static void button_task(void *arg)
{
    (void)arg;
    const uint32_t action_ms = CONFIG_PUMP_ACTION_HOLD_MS;
    const uint32_t pair_ms = (CONFIG_PUMP_PAIRING_HOLD_MS > CONFIG_PUMP_ACTION_HOLD_MS)
                                 ? CONFIG_PUMP_PAIRING_HOLD_MS
                                 : CONFIG_PUMP_ACTION_HOLD_MS + 1000;
    const uint32_t factory_ms = CONFIG_PUMP_FACTORY_RESET_EXTRA_MS;

    bool prev = false;
    btn_state_t state = BTN_IDLE;
    bool stopped_on_press = false; /* OFF already fired at press */
    bool armed_on = false;         /* held past action_ms; release → ON */
    bool pair_fired = false;
    bool factory_fired = false;
    TickType_t hold_start = 0;

    while (1) {
        const bool pressed = gpio_is_pressed(CONFIG_PUMP_BUTTON_GPIO);
        const TickType_t now = xTaskGetTickCount();

        switch (state) {
        case BTN_IDLE:
            if (pressed && !prev) {
                state = BTN_HOLD;
                hold_start = now;
                armed_on = false;
                pair_fired = false;
                factory_fired = false;
                stopped_on_press = false;
                status_led_set_hold_danger(false);
                if (s_pump_on) {
                    stopped_on_press = true;
                    ESP_LOGI(TAG, "Button press while running → OFF");
                    if (s_stop_cb) {
                        s_stop_cb();
                    }
                }
                enter_hold_progress();
            }
            break;

        case BTN_HOLD: {
            const uint32_t held_ms = (now - hold_start) * portTICK_PERIOD_MS;

            if (!pressed) {
                if (armed_on && !pair_fired && !stopped_on_press) {
                    ESP_LOGI(TAG, "Button held %u ms + release → ON", (unsigned)held_ms);
                    leave_hold_progress_if_needed();
                    if (s_start_cb) {
                        s_start_cb();
                    }
                } else if (!factory_fired) {
                    leave_hold_progress_if_needed();
                }
                status_led_set_hold_danger(false);
                state = BTN_IDLE;
                break;
            }

            if (!pair_fired) {
                if (!stopped_on_press && held_ms < action_ms) {
                    /* Phase 1: fill toward ON. */
                    update_hold_pct(held_ms, action_ms);
                } else {
                    if (!stopped_on_press && !armed_on) {
                        armed_on = true;
                        ESP_LOGI(TAG, "ON armed — release to start, keep holding for BLE pair");
                    }
                    /* Phase 2: fill toward BLE pairing. */
                    if (stopped_on_press) {
                        update_hold_pct(held_ms, pair_ms);
                    } else {
                        /* Stay fully spread once armed; restarting from 0 made the
                         * bloom collapse and regrow. */
                        update_hold_pct(action_ms, action_ms);
                    }
                }
                if (held_ms >= pair_ms) {
                    pair_fired = true;
                    ESP_LOGI(TAG, "Button held %u ms → BLE pairing", (unsigned)held_ms);
                    if (s_long_cb) {
                        s_long_cb();
                    }
                    /* Keep holding for factory reset — red progress. */
                    status_led_set_hold_danger(true);
                    enter_hold_progress();
                    update_hold_pct(0, factory_ms);
                }
            } else if (!factory_fired) {
                const uint32_t extra = held_ms - pair_ms;
                update_hold_pct(extra, factory_ms);
                if (extra >= factory_ms) {
                    factory_fired = true;
                    leave_hold_progress_if_needed();
                    status_led_set_hold_danger(false);
                    ESP_LOGW(TAG, "Button held %u ms → factory reset", (unsigned)held_ms);
                    if (s_factory_cb) {
                        s_factory_cb();
                    }
                }
            }
            break;
        }
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
        .pin_bit_mask = (1ULL << CONFIG_PUMP_BUTTON_GPIO),
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

    /* Room for a fill stopping here: the 2.4 KB history save and a notify. */
    if (xTaskCreate(button_task, "pump_btn", 4608, NULL, 5, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG,
             "Button GPIO %d (running: press → OFF; off: hold %d ms + release → ON; "
             "hold %d ms → BLE, +%d ms → factory reset)",
             CONFIG_PUMP_BUTTON_GPIO,
             CONFIG_PUMP_ACTION_HOLD_MS, CONFIG_PUMP_PAIRING_HOLD_MS,
             CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
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

void board_set_factory_reset_callback(board_long_press_cb_t cb)
{
    s_factory_cb = cb;
}
