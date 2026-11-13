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
#ifndef CONFIG_PUMP_BUTTON_STOP_GPIO
#define CONFIG_PUMP_BUTTON_STOP_GPIO 1
#endif

#define PUMP_BTN_SINGLE (CONFIG_PUMP_BUTTON_STOP_GPIO < 0)

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
    BTN_START_HOLD,
    BTN_STOP_HOLD,
    BTN_BOTH_HOLD,
} btn_state_t;

static bool gpio_is_pressed(int gpio)
{
    if (gpio < 0) {
        return false;
    }
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
    uint8_t pct = (uint8_t)((held_ms * 100) / threshold_ms);
    if (pct > 100) {
        pct = 100;
    }
    if (s_hold_cb) {
        s_hold_cb(pct);
    }
    status_led_set_hold_progress(pct);
}

static void button_task(void *arg)
{
    (void)arg;
    bool prev_start = false;
    bool prev_stop = false;
    btn_state_t state = BTN_IDLE;
    bool action_fired = false;
    bool pair_fired = false;
    bool factory_fired = false;
    TickType_t hold_start = 0;

    while (1) {
        const bool start = gpio_is_pressed(CONFIG_PUMP_BUTTON_START_GPIO);
        const bool stop = gpio_is_pressed(CONFIG_PUMP_BUTTON_STOP_GPIO);
        const bool both = start && stop;
        TickType_t now = xTaskGetTickCount();

        switch (state) {
        case BTN_IDLE:
            if (both) {
                state = BTN_BOTH_HOLD;
                pair_fired = false;
                factory_fired = false;
                hold_start = now;
                status_led_set_hold_danger(false);
                enter_hold_progress();
            } else if (start && !prev_start) {
                state = BTN_START_HOLD;
                action_fired = false;
                hold_start = now;
                status_led_set_hold_danger(false);
                enter_hold_progress();
            } else if (stop && !prev_stop) {
                state = BTN_STOP_HOLD;
                action_fired = false;
                hold_start = now;
                status_led_set_hold_danger(false);
                enter_hold_progress();
            }
            break;

        case BTN_START_HOLD:
            if (both) {
                /* Escalate to BLE pair hold. */
                state = BTN_BOTH_HOLD;
                pair_fired = false;
                factory_fired = false;
                hold_start = now;
                status_led_set_hold_danger(false);
                enter_hold_progress();
                update_hold_pct(0, CONFIG_PUMP_PAIRING_HOLD_MS);
            } else if (!start) {
                if (!action_fired) {
                    leave_hold_progress_if_needed();
                }
                state = BTN_IDLE;
            } else if (!action_fired) {
                uint32_t held_ms = (now - hold_start) * portTICK_PERIOD_MS;
                update_hold_pct(held_ms, CONFIG_PUMP_ACTION_HOLD_MS);
                if (held_ms >= CONFIG_PUMP_ACTION_HOLD_MS) {
                    action_fired = true;
#if PUMP_BTN_SINGLE
                    if (s_pump_on && s_stop_cb) {
                        ESP_LOGI(TAG, "Button held %u ms → OFF", (unsigned)held_ms);
                        s_stop_cb();
                    } else if (s_start_cb) {
                        ESP_LOGI(TAG, "Button held %u ms → ON", (unsigned)held_ms);
                        s_start_cb();
                    }
#else
                    leave_hold_progress_if_needed();
                    ESP_LOGI(TAG, "Start held %u ms → ON", (unsigned)held_ms);
                    if (s_start_cb) {
                        s_start_cb();
                    }
#endif
                }
            }
#if PUMP_BTN_SINGLE
            else if (start && action_fired) {
                uint32_t held_ms = (now - hold_start) * portTICK_PERIOD_MS;
                if (!pair_fired) {
                    update_hold_pct(held_ms, CONFIG_PUMP_PAIRING_HOLD_MS);
                    if (held_ms >= (uint32_t)CONFIG_PUMP_PAIRING_HOLD_MS) {
                        pair_fired = true;
                        ESP_LOGI(TAG, "Button held %u ms → BLE pairing", (unsigned)held_ms);
                        if (s_long_cb) {
                            s_long_cb();
                        }
                        status_led_set_hold_danger(true);
                        enter_hold_progress();
                        update_hold_pct(0, CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
                    }
                } else if (!factory_fired) {
                    uint32_t extra = 0;
                    if (held_ms > (uint32_t)CONFIG_PUMP_PAIRING_HOLD_MS) {
                        extra = held_ms - (uint32_t)CONFIG_PUMP_PAIRING_HOLD_MS;
                    }
                    update_hold_pct(extra, CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
                    if (extra >= (uint32_t)CONFIG_PUMP_FACTORY_RESET_EXTRA_MS) {
                        factory_fired = true;
                        leave_hold_progress_if_needed();
                        status_led_set_hold_danger(false);
                        ESP_LOGW(TAG, "Button held %u ms → factory reset", (unsigned)held_ms);
                        if (s_factory_cb) {
                            s_factory_cb();
                        }
                    }
                }
            }
#endif
            break;

        case BTN_STOP_HOLD:
            if (both) {
                state = BTN_BOTH_HOLD;
                pair_fired = false;
                factory_fired = false;
                hold_start = now;
                status_led_set_hold_danger(false);
                enter_hold_progress();
                update_hold_pct(0, CONFIG_PUMP_PAIRING_HOLD_MS);
            } else if (!stop) {
                if (!action_fired) {
                    leave_hold_progress_if_needed();
                }
                state = BTN_IDLE;
            } else if (!action_fired) {
                uint32_t held_ms = (now - hold_start) * portTICK_PERIOD_MS;
                update_hold_pct(held_ms, CONFIG_PUMP_ACTION_HOLD_MS);
                if (held_ms >= CONFIG_PUMP_ACTION_HOLD_MS) {
                    action_fired = true;
                    leave_hold_progress_if_needed();
                    ESP_LOGI(TAG, "Stop held %u ms → OFF", (unsigned)held_ms);
                    if (s_stop_cb) {
                        s_stop_cb();
                    }
                }
            }
            break;

        case BTN_BOTH_HOLD:
            if (!both) {
                if (!pair_fired || (!factory_fired && status_led_get_mode() == STATUS_LED_HOLD_PROGRESS)) {
                    leave_hold_progress_if_needed();
                }
                status_led_set_hold_danger(false);
                /* After aborting dual-hold, ignore remaining single until release. */
                state = BTN_IDLE;
            } else if (!pair_fired) {
                uint32_t held_ms = (now - hold_start) * portTICK_PERIOD_MS;
                update_hold_pct(held_ms, CONFIG_PUMP_PAIRING_HOLD_MS);
                if (held_ms >= CONFIG_PUMP_PAIRING_HOLD_MS) {
                    pair_fired = true;
                    ESP_LOGI(TAG, "Both held %u ms → BLE pairing", (unsigned)held_ms);
                    if (s_long_cb) {
                        s_long_cb();
                    }
                    /* Keep holding for factory reset — red progress. */
                    status_led_set_hold_danger(true);
                    enter_hold_progress();
                    update_hold_pct(0, CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
                }
            } else if (!factory_fired) {
                uint32_t held_ms = (now - hold_start) * portTICK_PERIOD_MS;
                uint32_t extra = 0;
                if (held_ms > (uint32_t)CONFIG_PUMP_PAIRING_HOLD_MS) {
                    extra = held_ms - (uint32_t)CONFIG_PUMP_PAIRING_HOLD_MS;
                }
                update_hold_pct(extra, CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
                if (extra >= (uint32_t)CONFIG_PUMP_FACTORY_RESET_EXTRA_MS) {
                    factory_fired = true;
                    leave_hold_progress_if_needed();
                    status_led_set_hold_danger(false);
                    ESP_LOGW(TAG, "Both held %u ms → factory reset", (unsigned)held_ms);
                    if (s_factory_cb) {
                        s_factory_cb();
                    }
                }
            }
            break;
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
    uint64_t btn_mask = (1ULL << CONFIG_PUMP_BUTTON_START_GPIO);
    if (CONFIG_PUMP_BUTTON_STOP_GPIO >= 0) {
        btn_mask |= (1ULL << CONFIG_PUMP_BUTTON_STOP_GPIO);
    }
    gpio_config_t io = {
        .pin_bit_mask = btn_mask,
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
    if (PUMP_BTN_SINGLE) {
        ESP_LOGI(TAG,
                 "Button GPIO %d only (hold %d ms → toggle, %d ms → BLE, +%d ms → factory)",
                 CONFIG_PUMP_BUTTON_START_GPIO, CONFIG_PUMP_ACTION_HOLD_MS,
                 CONFIG_PUMP_PAIRING_HOLD_MS, CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
    } else {
        ESP_LOGI(TAG,
                 "Start GPIO %d / Stop GPIO %d (hold %d ms → action, both %d ms → BLE, "
                 "+%d ms → factory reset)",
                 CONFIG_PUMP_BUTTON_START_GPIO, CONFIG_PUMP_BUTTON_STOP_GPIO,
                 CONFIG_PUMP_ACTION_HOLD_MS, CONFIG_PUMP_PAIRING_HOLD_MS,
                 CONFIG_PUMP_FACTORY_RESET_EXTRA_MS);
    }
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
