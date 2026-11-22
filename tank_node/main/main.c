#include <string.h>

#include "esp_attr.h"
#include "esp_log.h"
#include "esp_rtc_time.h"
#include "esp_sleep.h"
#include "esp_system.h"
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
#include "tank_boot_pins.h"
#include "tank_errors.h"
#include "tank_led.h"
#include "tank_link.h"
#include "tanklink_lora_proto.h"
#include "tank_version.h"

#define TAG "TANK"
#define NVS_NS "tank"
#define NVS_KEY_FLAGS "flags"
#define NVS_KEY_PAIRED "paired"

/* Last-resort backstop, not a time limit: every path below ends in sleep by
 * itself (pairing 30 s, the update window, retries). Only a hang reaches
 * this, so it is well past the longest real wake (an update, ~3 min). */
#define AWAKE_LIMIT_MS (10 * 60 * 1000)

/* Unpaired, the tank only needs the button, but a timer wake is always set so
 * nothing can leave it asleep for good. */
#define UNPAIRED_WAKE_SEC (24 * 3600)

/* Held this long without a break, the button is stuck (or something presses
 * it in the enclosure), not a gesture: stop handling it and sleep, waking
 * again when it is let go. A pairing hold is 3 s. */
#define BUTTON_STUCK_MS 20000
/* A button that chatters (a failing switch) would otherwise keep one wake
 * going with press after press. Far more than anyone presses in one go. */
#define BUTTON_SESSION_MAX 30

/* A float that flaps (waves, a loose wire) would wake the radio over and
 * over. Past this many float wakes in the window, floats sleep until the next
 * heartbeat, which still reports them. */
#define FLOAT_WAKES_MAX 12
#define FLOAT_WINDOW_US (10LL * 60 * 1000000)

/* After a crash, hang or brownout the tank sleeps a heartbeat with the radio
 * off before it tries again, and each one in a row doubles that (up to 16x),
 * so a fault that repeats can't keep it awake and empty the cell. A wake that
 * ends normally clears it. Kept through deep sleep and restarts. */
#define TROUBLE_MAGIC 0x54524231u /* 'TRB1' */
#define TROUBLE_BACKOFF_MAX_SHIFT 4
typedef struct {
    uint32_t magic;
    uint8_t count; /* trouble wakes in a row */
    uint8_t hung;  /* the awake backstop fired: the restart is a hang */
} trouble_t;
static RTC_NOINIT_ATTR trouble_t s_trouble; /* garbage after power-on: magic */

static RTC_DATA_ATTR uint8_t s_float_wakes;
static RTC_DATA_ATTR uint64_t s_float_window_start_us;

static void awake_limit_hit(void *arg)
{
    (void)arg;
    ESP_LOGE(TAG, "awake for %d min: a hang, restarting", AWAKE_LIMIT_MS / 60000);
    s_trouble.hung = 1;
    esp_restart();
}

/** True when this start follows a crash, a hang or a brownout. */
static bool started_after_trouble(esp_reset_reason_t reset)
{
    if (s_trouble.magic != TROUBLE_MAGIC) {
        memset(&s_trouble, 0, sizeof(s_trouble));
        s_trouble.magic = TROUBLE_MAGIC;
    }
    const bool hung = s_trouble.hung != 0;
    s_trouble.hung = 0;
    switch (reset) {
    case ESP_RST_BROWNOUT:
    case ESP_RST_PANIC:
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:
        return true;
    case ESP_RST_SW:
        return hung;
    default:
        return false;
    }
}

/** Count a float wake (see FLOAT_WAKES_MAX). */
static void note_float_wake(void)
{
    const uint64_t now = esp_rtc_get_time_us();
    if (now - s_float_window_start_us > (uint64_t)FLOAT_WINDOW_US) {
        s_float_window_start_us = now;
        s_float_wakes = 0;
    }
    if (s_float_wakes < 255) {
        s_float_wakes++;
    }
}

static bool floats_may_wake(void)
{
    const uint64_t now = esp_rtc_get_time_us();
    return now - s_float_window_start_us > (uint64_t)FLOAT_WINDOW_US ||
           s_float_wakes < FLOAT_WAKES_MAX;
}

static void arm_awake_limit(void)
{
    const esp_timer_create_args_t args = {
        .callback = awake_limit_hit,
        .name = "awake_limit",
    };
    esp_timer_handle_t t = NULL;
    if (esp_timer_create(&args, &t) != ESP_OK ||
        esp_timer_start_once(t, (uint64_t)AWAKE_LIMIT_MS * 1000) != ESP_OK) {
        ESP_LOGW(TAG, "awake limit timer not started");
    }
}

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
    if (in->sensor1) {
        f |= TANKLINK_LORA_FLAG_SENSOR1;
    }
    if (in->sensor2) {
        f |= TANKLINK_LORA_FLAG_SENSOR2;
    }
    return f;
}

static void hold_progress(uint8_t pct, void *ctx)
{
    (void)ctx;
    tank_led_set_brightness(pct);
}

typedef struct {
    bool armed;
    int64_t up_since_us;
    bool saw_down;
    bool clicked;
} cancel_ctx_t;

static bool pair_should_cancel(void *ctx)
{
    cancel_ctx_t *c = (cancel_ctx_t *)ctx;
    const bool down = tank_board_button_down();
    const int64_t now = esp_timer_get_time();
    /* The hold that started pairing is not a cancel. Arm after it is released. */
    if (!c->armed) {
        if (down) {
            c->up_since_us = 0;
        } else if (c->up_since_us == 0) {
            c->up_since_us = now;
        } else if ((now - c->up_since_us) / 1000 >= 80) {
            c->armed = true;
        }
        return false;
    }
    if (down) {
        c->saw_down = true;
    } else if (c->saw_down) {
        c->clicked = true;
        c->saw_down = false;
        return true;
    }
    return false;
}

typedef struct {
    tank_button_hold_t hold;
    bool pair;
} pair_hold_ctx_t;

static bool status_hold_cancel(void *ctx)
{
    pair_hold_ctx_t *c = (pair_hold_ctx_t *)ctx;
    uint32_t held = 0;
    uint8_t pct = 0;
    const tank_button_hold_event_t ev =
        tank_button_hold_poll(&c->hold, CONFIG_TANK_BUTTON_HOLD_MS, &held, &pct);
    if (ev == TANK_HOLD_REACHED) {
        c->pair = true;
        tank_led_set_brightness(100);
        return true;
    }
    if (ev == TANK_HOLD_HOLDING) {
        tank_led_set_brightness(pct);
    } else if (ev == TANK_HOLD_RELEASED) {
        tank_led_off();
    }
    return false;
}

/** Sleep. [after_trouble]: this start followed a crash, hang or brownout, so
 * back off; otherwise the wake ended normally and the backoff is cleared. */
static void enter_deep_sleep(bool after_trouble)
{
    tank_ble_deinit();
    tank_link_deinit_radio();
    tank_led_prepare_deep_sleep();
    const bool paired = load_paired();
    uint32_t timer_sec;
    bool floats = false;
    if (!paired) {
        timer_sec = UNPAIRED_WAKE_SEC;
    } else {
        timer_sec = (uint32_t)CONFIG_TANK_HEARTBEAT_SEC;
        floats = floats_may_wake();
        if (!floats) {
            ESP_LOGW(TAG, "floats woke the tank %u times in 10 min: heartbeat only for now",
                     (unsigned)s_float_wakes);
        }
    }
    if (after_trouble) {
        const unsigned shift = s_trouble.count > 0 ? s_trouble.count - 1 : 0;
        if (paired) {
            timer_sec <<= shift > TROUBLE_BACKOFF_MAX_SHIFT ? TROUBLE_BACKOFF_MAX_SHIFT : shift;
        }
        floats = false;
        ESP_LOGW(TAG, "trouble %u in a row: radio off, sleeping %us", (unsigned)s_trouble.count,
                 (unsigned)timer_sec);
    } else {
        s_trouble.count = 0;
    }
    tank_board_prepare_deep_sleep(timer_sec, floats);
    ESP_LOGI(TAG, "entering deep sleep (%s)", paired ? "paired" : "unpaired");
    esp_deep_sleep_start();
}

/**
 * Pairing mode ended (paired, cancelled or timed out): if this tank was paired
 * with a pump before, tell that pump it has been removed. Sent last, with the
 * old key. A pump that was just paired again has the new key and ignores it, so
 * re-pairing with the same pump keeps its names, schedules and settings.
 */
static void tell_old_pump(bool had_pair, uint8_t old_key[TL_KEY_LEN], uint8_t bat)
{
    if (had_pair) {
        (void)tank_link_send_unpair(bat, old_key);
    }
    memset(old_key, 0, TL_KEY_LEN);
}

static esp_err_t run_pairing_mode(uint8_t bat)
{
    ESP_LOGI(TAG, "pairing mode (%d ms window, click to cancel)", CONFIG_TANK_PAIR_WINDOW_MS);
    const bool had_pair = load_paired();
    uint8_t old_key[TL_KEY_LEN];
    memcpy(old_key, tank_link_key(), sizeof(old_key));
    save_paired(false);
    tank_led_pairing_flash_start();
    cancel_ctx_t cancel = {0};

    const int64_t deadline =
        esp_timer_get_time() + (int64_t)CONFIG_TANK_PAIR_WINDOW_MS * 1000;
    esp_err_t err = ESP_ERR_TIMEOUT;
    while (esp_timer_get_time() < deadline) {
        if (pair_should_cancel(&cancel)) {
            tank_led_pairing_flash_stop();
            tank_led_show_error(TANK_ERR_PAIR_CANCELLED);
            tell_old_pump(had_pair, old_key, bat);
            return ESP_ERR_INVALID_STATE;
        }
        err = tank_link_send_pair_request(bat, pair_should_cancel, &cancel);
        if (err == ESP_OK) {
            save_paired(true);
            tank_led_pairing_flash_stop();
            tank_led_success();
            tell_old_pump(had_pair, old_key, bat);
            /* Extra STATUS so the pump marks online even if PAIR apply was missed. */
            tank_inputs_t in;
            tank_board_read(&in);
            (void)tank_link_send_status(&in, bat, false, NULL, NULL);
            ESP_LOGI(TAG, "paired OK");
            return ESP_OK;
        }
        if (err == ESP_ERR_INVALID_STATE || cancel.clicked) {
            tank_led_pairing_flash_stop();
            tank_led_show_error(TANK_ERR_PAIR_CANCELLED);
            tell_old_pump(had_pair, old_key, bat);
            return ESP_ERR_INVALID_STATE;
        }
        /* Keep flashing between retry rounds until window ends. */
        for (int i = 0; i < 25; i++) {
            if (pair_should_cancel(&cancel)) {
                tank_led_pairing_flash_stop();
                tank_led_show_error(TANK_ERR_PAIR_CANCELLED);
                tell_old_pump(had_pair, old_key, bat);
                return ESP_ERR_INVALID_STATE;
            }
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
    tank_led_pairing_flash_stop();
    tank_led_show_error(TANK_ERR_PAIR_TIMEOUT);
    ESP_LOGW(TAG, "pairing timed out");
    tell_old_pump(had_pair, old_key, bat);
    return ESP_ERR_TIMEOUT;
}

/** One press. [timed]: it is already over and was timed across a sleep (its
 * release woke the tank), and [known_hold] says whether it was a hold.
 * Otherwise the press is watched now. */
static void run_gesture(bool timed, bool known_hold)
{
    bool is_hold = known_hold;
    uint32_t held = 0;
    if (!timed) {
        tank_board_classify_button(CONFIG_TANK_BUTTON_HOLD_MS, &is_hold, &held,
                                   hold_progress, NULL);
    }
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

    pair_hold_ctx_t hold = {0};
    esp_err_t err = tank_link_send_status(&in, bat, true, status_hold_cancel, &hold);
    ESP_LOGI(TAG, "status result: %s", esp_err_to_name(err));
    save_last_flags(now_flags);
    if (hold.pair) {
        tank_ble_stop();
        (void)run_pairing_mode(bat);
        return;
    }

    if (ble_err == ESP_OK) {
        /* A hold that began during the send keeps counting in the window. */
        tank_button_hold_t carry = hold.hold;
        for (;;) {
            const tank_ble_window_result_t w = tank_ble_wait_ota_window(&carry);
            if (w == TANK_BLE_WINDOW_CLICK) {
                tank_board_read(&in);
                bat = tank_battery_percent();
                pair_hold_ctx_t again = {0};
                err = tank_link_send_status(&in, bat, true, status_hold_cancel, &again);
                ESP_LOGI(TAG, "repeat status: %s", esp_err_to_name(err));
                save_last_flags(flags_from_inputs(&in));
                if (again.pair) {
                    tank_ble_stop();
                    (void)run_pairing_mode(bat);
                    return;
                }
                carry = again.hold;
                continue;
            }
            if (w == TANK_BLE_WINDOW_PAIR) {
                tank_ble_stop();
                bat = tank_battery_percent();
                (void)run_pairing_mode(bat);
            }
            break;
        }
    }
}

static void handle_button_gesture(void)
{
    run_gesture(false, false);
}

/** A press to handle: the button is down, and not still held from before
 * the last sleep. */
static bool button_waiting(void)
{
    return tank_board_button_pressed();
}

/**
 * Handle the button until it rests: each gesture, then any press still down
 * after it (a long press started during an error blink, say), so the tank
 * never goes to sleep on a press. Stops for a button held without a break for
 * BUTTON_STUCK_MS: that is not a gesture, and the tank wakes on its release.
 */
static void button_session(void)
{
    for (int n = 1;; n++) {
        handle_button_gesture();
        if (tank_board_button_held_ms() >= BUTTON_STUCK_MS) {
            ESP_LOGW(TAG, "button held %u ms without a break: treating it as stuck",
                     (unsigned)tank_board_button_held_ms());
            return;
        }
        if (!button_waiting()) {
            return;
        }
        if (n >= BUTTON_SESSION_MAX) {
            ESP_LOGW(TAG, "%d presses in one wake: sleeping (the button wakes it again)", n);
            return;
        }
        ESP_LOGI(TAG, "another press: handling it before sleeping");
    }
}

void app_main(void)
{
    /* Kill LED glow before NVS / radio init (GPIO6 can sit weakly high after reset). */
    tank_led_force_off_pin(CONFIG_TANK_LED_GPIO);

#if !CONFIG_TANK_DEMO_NO_SLEEP
    arm_awake_limit();
#endif
    const esp_reset_reason_t reset = esp_reset_reason();
    ESP_LOGI(TAG, "TankLink tank node fw=%s reset=%d", TANK_FW_VERSION_STR, (int)reset);
    tank_boot_pins_log(TAG);

    /* Never abort here: an abort restarts at once, and a restart loop at
     * full power empties the battery. Without NVS the tank reads as
     * unpaired and sleeps until the button is pressed. */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        if (nvs_flash_erase() == ESP_OK) {
            err = nvs_flash_init();
        }
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS unavailable: %s", esp_err_to_name(err));
    }

    if (started_after_trouble(reset)) {
        /* A brownout (the cell sagged under radio load), a crash or a hang.
         * Trying again at once would likely repeat it: sleep first, longer
         * each time it happens in a row. */
        if (s_trouble.count < 255) {
            s_trouble.count++;
        }
        ESP_LOGW(TAG, "started after trouble (reset %d): sleeping without radio", (int)reset);
        (void)tank_board_init();
        /* The radio may still be in TX or standby: init resets it and
         * leaves it asleep without sending anything. */
        (void)tank_link_init();
        enter_deep_sleep(true);
    }

    if (tank_board_init() != ESP_OK) {
        ESP_LOGW(TAG, "board init failed — continuing");
    }
    if (tank_led_init(tank_board_led_gpio()) != ESP_OK) {
        ESP_LOGW(TAG, "LED PWM unavailable");
    }
    if (tank_battery_init() != ESP_OK) {
        ESP_LOGW(TAG, "battery ADC unavailable — pct=0");
        tank_link_set_fault(TANK_ERR_BATTERY);
    }
    if (tank_link_init() != ESP_OK) {
        ESP_LOGW(TAG, "LoRa unavailable — TX will fail soft");
    }
    if (tank_ble_token_init() != ESP_OK) {
        ESP_LOGW(TAG, "BLE token init failed");
    }
    /* Do not start NimBLE until an OTA window — BT left up was ~0.9 mA in "sleep". */

    esp_sleep_wakeup_cause_t cause = tank_board_wakeup_cause();
    const tank_button_wake_t button_wake = tank_board_button_wake();
    ESP_LOGI(TAG, "wakeup cause=%d paired=%d", (int)cause, (int)load_paired());

    tank_inputs_t in;
    tank_board_read(&in);
    uint8_t bat = tank_battery_percent();
    uint8_t now_flags = flags_from_inputs(&in);
    uint8_t last_flags = load_last_flags();

    if (cause == ESP_SLEEP_WAKEUP_UNDEFINED) {
        tank_led_boot();
        if (load_paired() && tank_link_radio_ok()) {
            err = tank_link_send_status(&in, bat, false, NULL, NULL);
            ESP_LOGI(TAG, "boot status: %s", esp_err_to_name(err));
            save_last_flags(now_flags);
        }
        if (tank_link_fault() == TANK_ERR_BATTERY) {
            tank_led_show_error(TANK_ERR_BATTERY);
        }
    } else if (tank_board_woke_from_timer()) {
        if (load_paired() && tank_link_radio_ok()) {
            err = tank_link_send_status(&in, bat, false, NULL, NULL);
            ESP_LOGI(TAG, "heartbeat: %s", esp_err_to_name(err));
            save_last_flags(now_flags);
        }
    } else if (cause == ESP_SLEEP_WAKEUP_GPIO) {
        if (button_wake == TANK_BTN_WAKE_PRESS) {
            button_session();
        } else if (button_wake == TANK_BTN_WAKE_RELEASE) {
            /* The button went down just as the tank fell asleep: its release
             * woke it, and the press still counts, a hold included. */
            const uint32_t held = tank_board_release_held_ms();
            if (held >= BUTTON_STUCK_MS) {
                ESP_LOGI(TAG, "button let go after %u ms (stuck): armed again", (unsigned)held);
            } else {
                ESP_LOGI(TAG, "press over a sleep, %u ms", (unsigned)held);
                run_gesture(true, held >= CONFIG_TANK_BUTTON_HOLD_MS);
            }
        } else {
            note_float_wake();
            /* Float change */
            if (now_flags != last_flags) {
                ESP_LOGI(TAG, "flags 0x%02x -> 0x%02x", last_flags, now_flags);
            }
            if (load_paired() && tank_link_radio_ok()) {
                err = tank_link_send_status(&in, bat, false, NULL, NULL);
                ESP_LOGI(TAG, "float status: %s", esp_err_to_name(err));
            }
            save_last_flags(now_flags);
        }
    } else {
        if (load_paired() && tank_link_radio_ok()) {
            err = tank_link_send_status(&in, bat, false, NULL, NULL);
            ESP_LOGI(TAG, "status: %s", esp_err_to_name(err));
            save_last_flags(now_flags);
        }
    }

#if CONFIG_TANK_DEMO_NO_SLEEP
    ESP_LOGW(TAG, "demo mode: no deep sleep");
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (button_waiting()) {
            button_session();
        }
    }
#else
    /* Never sleep on a press: one started while the tank was busy (a send,
     * the boot light) is handled now, like any other. */
    if (button_waiting()) {
        button_session();
    }
    enter_deep_sleep(false);
#endif
}
