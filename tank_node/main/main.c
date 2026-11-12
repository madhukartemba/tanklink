#include <string.h>

#include "esp_log.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "tank_battery.h"
#include "tank_ble.h"
#include "tank_ble_token.h"
#include "tank_board.h"
#include "tank_errors.h"
#include "tank_led.h"
#include "tank_link.h"
#include "tank_version.h"

#define TAG "TANK"
#define NVS_NS "tank"
#define NVS_KEY_FLAGS "flags"
#define NVS_KEY_PAIRED "paired"

#ifndef CONFIG_TANK_BUTTON_AWAKE_MS
#define CONFIG_TANK_BUTTON_AWAKE_MS 10000
#endif
#ifndef CONFIG_TANK_BLE_OTA_WINDOW_MS
#define CONFIG_TANK_BLE_OTA_WINDOW_MS 120000
#endif
#ifndef CONFIG_TANK_PAIR_WINDOW_MS
#define CONFIG_TANK_PAIR_WINDOW_MS 60000
#endif

static uint8_t load_last_flags(void)
{
    uint8_t f = 0xFF;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        nvs_get_u8(h, NVS_KEY_FLAGS, &f);
        nvs_close(h);
    }
    return f;
}

static void save_last_flags(uint8_t flags)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u8(h, NVS_KEY_FLAGS, flags);
        nvs_commit(h);
        nvs_close(h);
    }
}

static bool load_paired(void)
{
    uint8_t p = 0;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        nvs_get_u8(h, NVS_KEY_PAIRED, &p);
        nvs_close(h);
    }
    return p != 0;
}

static void save_paired(bool paired)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u8(h, NVS_KEY_PAIRED, paired ? 1 : 0);
        nvs_commit(h);
        nvs_close(h);
    }
}

static uint8_t flags_from_inputs(const tank_inputs_t *in)
{
    uint8_t f = 0;
    if (in->full) {
        f |= 0x01;
    }
    if (in->empty) {
        f |= 0x02;
    }
    return f;
}

static void hold_progress(uint8_t pct, void *ctx)
{
    (void)ctx;
    tank_led_set_brightness(pct);
}

typedef struct {
    bool saw_down;
    bool clicked;
} cancel_ctx_t;

static bool pair_should_cancel(void *ctx)
{
    cancel_ctx_t *c = (cancel_ctx_t *)ctx;
    const bool down = tank_board_button_down();
    if (down) {
        c->saw_down = true;
    } else if (c->saw_down) {
        c->clicked = true;
        c->saw_down = false;
        return true;
    }
    tank_led_pairing_flash_tick();
    return false;
}

static void enter_deep_sleep(void)
{
    tank_ble_stop();
    tank_link_deinit_radio();
    tank_led_off();
    tank_board_prepare_deep_sleep(CONFIG_TANK_HEARTBEAT_SEC);
    ESP_LOGI(TAG, "entering deep sleep (%ds heartbeat)", CONFIG_TANK_HEARTBEAT_SEC);
    esp_deep_sleep_start();
}

static esp_err_t run_pairing_mode(uint8_t bat)
{
    ESP_LOGI(TAG, "pairing mode (%d ms window, click to cancel)", CONFIG_TANK_PAIR_WINDOW_MS);
    save_paired(false);
    tank_led_pairing_flash_start();
    cancel_ctx_t cancel = {0};
    /* Ignore the release that ended the hold. */
    while (tank_board_button_down()) {
        tank_led_pairing_flash_tick();
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    vTaskDelay(pdMS_TO_TICKS(40));

    const int64_t deadline =
        esp_timer_get_time() + (int64_t)CONFIG_TANK_PAIR_WINDOW_MS * 1000;
    esp_err_t err = ESP_ERR_TIMEOUT;
    while (esp_timer_get_time() < deadline) {
        if (pair_should_cancel(&cancel)) {
            tank_led_pairing_flash_stop();
            tank_led_show_error(TANK_ERR_PAIR_CANCELLED);
            return ESP_ERR_INVALID_STATE;
        }
        err = tank_link_send_pair_request(bat, pair_should_cancel, &cancel);
        if (err == ESP_OK) {
            save_paired(true);
            tank_led_pairing_flash_stop();
            tank_led_success();
            /* Extra STATUS so the pump marks online even if PAIR apply was missed. */
            tank_inputs_t in;
            tank_board_read(&in);
            (void)tank_link_send_status(&in, bat, false);
            ESP_LOGI(TAG, "paired OK");
            return ESP_OK;
        }
        if (err == ESP_ERR_INVALID_STATE || cancel.clicked) {
            tank_led_pairing_flash_stop();
            tank_led_show_error(TANK_ERR_PAIR_CANCELLED);
            return ESP_ERR_INVALID_STATE;
        }
        /* Keep flashing between retry rounds until window ends. */
        for (int i = 0; i < 25; i++) {
            if (pair_should_cancel(&cancel)) {
                tank_led_pairing_flash_stop();
                tank_led_show_error(TANK_ERR_PAIR_CANCELLED);
                return ESP_ERR_INVALID_STATE;
            }
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
    tank_led_pairing_flash_stop();
    tank_led_show_error(TANK_ERR_PAIR_TIMEOUT);
    ESP_LOGW(TAG, "pairing timed out");
    return ESP_ERR_TIMEOUT;
}

static void handle_button_gesture(void)
{
    bool is_hold = false;
    uint32_t held = 0;
    tank_board_classify_button(CONFIG_TANK_BUTTON_HOLD_MS, &is_hold, &held, hold_progress,
                               NULL);
    ESP_LOGI(TAG, "button held %u ms hold=%d", (unsigned)held, (int)is_hold);

    tank_inputs_t in;
    tank_board_read(&in);
    uint8_t bat = tank_battery_percent();
    uint8_t now_flags = flags_from_inputs(&in);

    if (is_hold) {
        tank_led_set_brightness(100);
        (void)run_pairing_mode(bat);
        save_last_flags(now_flags);
        return;
    }

    tank_led_fade_to(0, 100);

    if (!tank_link_radio_ok()) {
        tank_led_show_error(TANK_ERR_LORA_MISSING);
        return;
    }
    if (!load_paired()) {
        tank_led_show_error(TANK_ERR_NOT_PAIRED);
        return;
    }

    /* Advertise BLE first so the phone can connect during LoRa TX/ACK. */
    ESP_LOGI(TAG, "BLE OTA advertise start (%d ms)", CONFIG_TANK_BLE_OTA_WINDOW_MS);
    esp_err_t ble_err = tank_ble_start_ota_window(CONFIG_TANK_BLE_OTA_WINDOW_MS);
    if (ble_err != ESP_OK) {
        ESP_LOGW(TAG, "BLE OTA window failed: %s", esp_err_to_name(ble_err));
    }

    esp_err_t err = tank_link_send_status(&in, bat, true);
    ESP_LOGI(TAG, "status result: %s", esp_err_to_name(err));
    save_last_flags(now_flags);
    /* Success / no-ACK LED handled inside tank_link_send_status. */

    if (ble_err == ESP_OK) {
        err = tank_ble_wait_ota_window();
        if (err == ESP_ERR_INVALID_STATE) {
            tank_ble_stop();
            bat = tank_battery_percent();
            (void)run_pairing_mode(bat);
        }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "TankLink tank node fw=%s", TANK_FW_VERSION_STR);

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    if (tank_board_init() != ESP_OK) {
        ESP_LOGW(TAG, "board init failed — continuing");
    }
    if (tank_led_init(tank_board_led_gpio()) != ESP_OK) {
        ESP_LOGW(TAG, "LED PWM unavailable");
    }
    if (tank_battery_init() != ESP_OK) {
        ESP_LOGW(TAG, "battery ADC unavailable — pct=0");
    }
    if (tank_link_init() != ESP_OK) {
        ESP_LOGW(TAG, "LoRa unavailable — TX will fail soft");
    }
    if (tank_ble_token_init() != ESP_OK) {
        ESP_LOGW(TAG, "BLE token init failed");
    }
    if (tank_ble_init() != ESP_OK) {
        ESP_LOGW(TAG, "BLE unavailable — OTA window will fail soft");
    }

    esp_sleep_wakeup_cause_t cause = tank_board_wakeup_cause();
    ESP_LOGI(TAG, "wakeup cause=%d paired=%d", (int)cause, (int)load_paired());

    tank_inputs_t in;
    tank_board_read(&in);
    uint8_t bat = tank_battery_percent();
    uint8_t now_flags = flags_from_inputs(&in);
    uint8_t last_flags = load_last_flags();

    if (cause == ESP_SLEEP_WAKEUP_UNDEFINED) {
        tank_led_boot();
        if (load_paired() && tank_link_radio_ok()) {
            err = tank_link_send_status(&in, bat, false);
            ESP_LOGI(TAG, "boot status: %s", esp_err_to_name(err));
            save_last_flags(now_flags);
        }
    } else if (tank_board_woke_from_timer()) {
        if (load_paired() && tank_link_radio_ok()) {
            err = tank_link_send_status(&in, bat, false);
            ESP_LOGI(TAG, "heartbeat: %s", esp_err_to_name(err));
            save_last_flags(now_flags);
        }
    } else if (cause == ESP_SLEEP_WAKEUP_GPIO) {
        if (in.button_down || tank_board_woke_from_button()) {
            handle_button_gesture();
        } else {
            /* Float change */
            if (now_flags != last_flags) {
                ESP_LOGI(TAG, "flags 0x%02x -> 0x%02x", last_flags, now_flags);
            }
            if (load_paired() && tank_link_radio_ok()) {
                err = tank_link_send_status(&in, bat, false);
                ESP_LOGI(TAG, "float status: %s", esp_err_to_name(err));
                save_last_flags(now_flags);
            } else {
                save_last_flags(now_flags);
            }
        }
    } else {
        if (load_paired() && tank_link_radio_ok()) {
            err = tank_link_send_status(&in, bat, false);
            save_last_flags(now_flags);
            (void)err;
        }
    }

#if CONFIG_TANK_DEMO_NO_SLEEP
    ESP_LOGW(TAG, "demo mode: no deep sleep");
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (tank_board_button_down()) {
            handle_button_gesture();
        }
    }
#else
    enter_deep_sleep();
#endif
}
