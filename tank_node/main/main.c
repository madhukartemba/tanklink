#include <string.h>

#include "esp_log.h"
#include "esp_sleep.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "tank_battery.h"
#include "tank_board.h"
#include "tank_link.h"

#define TAG "TANK"
#define NVS_NS "tank"
#define NVS_KEY_FLAGS "flags"

static uint8_t load_last_flags(void)
{
    uint8_t f = 0xFF; /* force first TX after erase */
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

static void clear_pairing_state(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_key(h, "pair_id");
        nvs_erase_key(h, "pair_key");
        nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "pairing state cleared");
}

void app_main(void)
{
    ESP_LOGI(TAG, "TankLink tank node");

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    ESP_ERROR_CHECK(tank_board_init());
    (void)tank_battery_init();
    (void)tank_link_init();

    esp_sleep_wakeup_cause_t cause = tank_board_wakeup_cause();
    ESP_LOGI(TAG, "wakeup cause=%d", (int)cause);

    tank_inputs_t in;
    tank_board_read(&in);
    uint8_t bat = tank_battery_percent();
    uint8_t now_flags = flags_from_inputs(&in);
    uint8_t last_flags = load_last_flags();

    bool do_tx = false;
    bool button_event = false;
    bool pairing = false;
    const char *reason = "boot";

    if (cause == ESP_SLEEP_WAKEUP_UNDEFINED) {
        do_tx = true;
        reason = "boot";
        tank_led_blink(1, 120, 0);
    } else if (tank_board_woke_from_timer()) {
        do_tx = true;
        reason = "heartbeat";
    } else if (cause == ESP_SLEEP_WAKEUP_GPIO) {
        if (in.button_down || tank_board_woke_from_button()) {
            bool is_hold = false;
            uint32_t held = 0;
            tank_board_classify_button(CONFIG_TANK_BUTTON_HOLD_MS, &is_hold, &held);
            ESP_LOGI(TAG, "button held %u ms hold=%d", (unsigned)held, (int)is_hold);
            if (is_hold) {
                pairing = true;
                do_tx = true;
                reason = "pair_hold";
            } else {
                button_event = true;
                do_tx = true;
                reason = "button_click";
            }
            tank_board_read(&in);
            now_flags = flags_from_inputs(&in);
        } else {
            do_tx = true;
            reason = "float";
        }
    } else {
        do_tx = true;
        reason = "other";
    }

    if (now_flags != last_flags) {
        do_tx = true;
        if (!pairing && !button_event && strcmp(reason, "heartbeat") != 0 &&
            strcmp(reason, "boot") != 0) {
            reason = "state_change";
        }
        ESP_LOGI(TAG, "flags 0x%02x -> 0x%02x", last_flags, now_flags);
    }

    ESP_LOGI(TAG, "full=%d empty=%d bat=%u%% reason=%s tx=%d", (int)in.full,
             (int)in.empty, bat, reason, (int)do_tx);

    if (pairing) {
        clear_pairing_state();
        err = tank_link_send_pair_request(bat);
        ESP_LOGI(TAG, "pair result: %s", esp_err_to_name(err));
        save_last_flags(now_flags);
    } else if (do_tx) {
        err = tank_link_send_status(&in, bat, button_event);
        ESP_LOGI(TAG, "status result: %s", esp_err_to_name(err));
        /* Persist last float snapshot even if ACK failed — avoids TX storm every wake.
         * Heartbeat will retry soon anyway. */
        save_last_flags(now_flags);
    }

    tank_link_deinit_radio();
    tank_led_set(false);

    tank_board_prepare_deep_sleep(CONFIG_TANK_HEARTBEAT_SEC);
    ESP_LOGI(TAG, "entering deep sleep");
    esp_deep_sleep_start();
}
