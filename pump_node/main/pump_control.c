#include "pump_control.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "board.h"
#include "buzzer.h"
#include "gatt_svr.h"
#include "lora_link.h"
#include "pump_alert.h"
#include "pump_clock.h"
#include "pump_config.h"
#include "pump_errors.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_runlog.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "relay_control.h"
#include "status_led.h"
#include "tanklink_lora_proto.h"

#define TAG "PUMP_CTL"

/* Auto-fill: at least this long between a stop and the next automatic start,
 * so a float bobbing at the water line can't start the pump again and again. */
#define AUTO_FILL_COOLDOWN_US (15LL * 60 * 1000000)

static bool s_on;
static int64_t s_on_since_us;
/* The running fill, for the history entry written when it stops. */
static uint32_t s_fill_started_local;
static uint8_t s_fill_started_by;
static uint8_t s_last_error;
static int64_t s_stopped_us; /* when the pump last stopped, 0 = not since boot */

/*
 * Auto-fill state for the selected tank. It is armed once the tank is seen
 * above its almost-empty float, and fires once when the float drops: a tank
 * that is already low (after a restart, a manual stop or turning the setting
 * on) waits for the next drop. An automatic fill that ends any way other
 * than "tank full" pauses auto-fill until the tank is next seen full, so a
 * dry source or a stuck float can't cycle the pump.
 */
/* The button task, the BLE host, the LoRa task and the poll task all switch
 * the pump. One lock keeps a start and a stop from interleaving (a fill
 * counted twice, or the relay and s_on disagreeing). Recursive: the poll
 * holds it while it starts or stops a fill. */
static SemaphoreHandle_t s_lock;

static void lock(void)
{
    if (s_lock) {
        xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
    }
}

static void unlock(void)
{
    if (s_lock) {
        xSemaphoreGiveRecursive(s_lock);
    }
}

void pump_control_init(void)
{
    if (!s_lock) {
        s_lock = xSemaphoreCreateRecursiveMutex();
    }
}

static uint8_t s_af_slot = 0xFF;
static bool s_af_armed;
static bool s_af_paused;

bool pump_control_is_on(void)
{
    return s_on;
}

uint32_t pump_control_run_seconds(void)
{
    if (!s_on || s_on_since_us == 0) {
        return 0;
    }
    const int64_t elapsed = (esp_timer_get_time() - s_on_since_us) / 1000000LL;
    return elapsed < 0 ? 0 : (uint32_t)elapsed;
}

uint8_t pump_control_last_error(void)
{
    return s_last_error;
}

void pump_control_set_error(uint8_t code)
{
    s_last_error = code;
    gatt_svr_notify_tank();
}

void pump_control_clear_error(void)
{
    if (s_last_error == PUMP_ERR_NONE) {
        return;
    }
    s_last_error = PUMP_ERR_NONE;
    gatt_svr_notify_tank();
}

void pump_control_refresh_idle_led(void)
{
    const status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_HOLD_PROGRESS || mode == STATUS_LED_PAIRING ||
        mode == STATUS_LED_TANK_PAIRING || mode == STATUS_LED_UNPAIRED ||
        mode == STATUS_LED_PUMP_ON || mode == STATUS_LED_UPDATING ||
        mode == STATUS_LED_UPDATE_OK || mode == STATUS_LED_UPDATE_ERR) {
        return;
    }
    /* The idle glow also shows tank-full, so there is no separate
     * "phone connected" animation. */
    if (!s_on) {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

static void deny_start(uint8_t code)
{
    s_last_error = code;
    status_led_show_error(code);
    gatt_svr_notify_tank();
}

/** Returns the reason the pump may not start now, or PUMP_ERR_NONE. */
static uint8_t start_blocker(void)
{
    if (relay_control_is_blocked() || pump_ota_is_active()) {
        return PUMP_ERR_BLOCKED;
    }
    /* Only the selected tank counts: with a lever, others may already be full. */
    if (lora_link_active_tank_full()) {
        return PUMP_ERR_TANK_FULL;
    }
    return PUMP_ERR_NONE;
}

static void set_state(bool on, bool beep, pump_cause_t cause)
{
    if (on) {
        const uint8_t blocker = start_blocker();
        if (blocker != PUMP_ERR_NONE) {
            ESP_LOGW(TAG, "Start denied, error %u", blocker);
            deny_start(blocker);
            return;
        }
    }
    const bool changed = on != s_on;
    if (on && !s_on) {
        int64_t now = 0;
        s_fill_started_local = pump_clock_unix_now(&now) && now > 0 ? (uint32_t)now : 0;
        s_fill_started_by = (uint8_t)cause;
        s_on_since_us = esp_timer_get_time();
        s_last_error = PUMP_ERR_NONE;
        pump_runlog_on_start();
        gatt_svr_notify_tank();
    }
    if (!on && s_on) {
        const pump_fill_t fill = {
            .started_local = s_fill_started_local,
            .ran_sec = pump_control_run_seconds(),
            .slot = pump_tanks_active(),
            .started_by = s_fill_started_by,
            .stopped_by = (uint8_t)cause,
        };
        pump_history_add(&fill);
        /* Only these two stops are news: the others are the user's own doing. */
        if (cause == PUMP_CAUSE_TANK_FULL) {
            pump_alert_raise(TL_ALERT_TANK_FULL, PUMP_ALERT_FILL_ARG(fill.slot, fill.ran_sec));
        } else if (cause == PUMP_CAUSE_AUTO_OFF) {
            pump_alert_raise(TL_ALERT_AUTO_OFF, PUMP_ALERT_FILL_ARG(fill.slot, fill.ran_sec));
        }
        s_stopped_us = esp_timer_get_time();
        if (s_fill_started_by == PUMP_CAUSE_AUTO_FILL && cause != PUMP_CAUSE_TANK_FULL) {
            s_af_paused = true;
            ESP_LOGW(TAG, "Auto-fill paused until the tank is full (stopped by %d)", cause);
        }
    }
    if (!on) {
        s_on_since_us = 0;
        pump_runlog_on_stop();
    }
    s_on = on;
    board_set_pump_on(on);
    if (on) {
        relay_control_set_running(true);
    } else {
        /* Always pulse Stop, even if we thought the pump was already off. */
        relay_control_force_off();
    }
    ESP_LOGI(TAG, "Pump %s", on ? "on" : "off");
    if (changed && beep && pump_config_buzzer_on_pump()) {
        buzzer_play(on ? BUZZER_TONE_SHARP : BUZZER_TONE_CLICK, false);
    }
    if (!on) {
        pump_control_refresh_idle_led();
    }
    gatt_svr_notify_state();
}

void pump_control_set(bool on, pump_cause_t cause)
{
    lock();
    set_state(on, true, cause);
    unlock();
}

void pump_control_set_silent(bool on, pump_cause_t cause)
{
    lock();
    set_state(on, false, cause);
    unlock();
}

void pump_control_toggle(void)
{
    if (pump_ota_is_active()) {
        ESP_LOGW(TAG, "Toggle ignored: update in progress");
        return;
    }
    if (!pump_pair_is_paired()) {
        ESP_LOGW(TAG, "Toggle ignored: not paired");
        return;
    }
    /* The button handler already clicked. */
    lock();
    set_state(!s_on, false, PUMP_CAUSE_BUTTON);
    unlock();
}

/** Start a fill if a schedule is due now. Switches to its tank first. */
static void start_due_schedule(void)
{
    pump_civil_time_t now;
    if (!pump_clock_now(&now)) {
        return;
    }
    const int slot = pump_sched_take_due(&now);
    if (slot < 0 || s_on) {
        return;
    }
    if ((uint8_t)slot != pump_tanks_active()) {
        if (pump_tanks_select((uint8_t)slot, false) != ESP_OK) {
            ESP_LOGW(TAG, "Schedule slot %d missing", slot);
            return;
        }
        lora_link_on_active_changed();
        gatt_svr_notify_tanks();
        gatt_svr_notify_tank();
        gatt_svr_notify_nodes();
    }
    ESP_LOGI(TAG, "Schedule start %02u:%02u slot %d", now.hour, now.minute, slot);
    pump_control_set(true, PUMP_CAUSE_SCHEDULE);
}

/** Start a fill when the selected tank's almost-empty float drops. */
static void start_due_auto_fill(void)
{
    const uint8_t slot = pump_tanks_active();
    if (slot != s_af_slot) {
        s_af_slot = slot;
        s_af_armed = false;
        s_af_paused = false;
    }
    if (!pump_tanks_auto_fill_on(slot) || !lora_link_tank_online()) {
        s_af_armed = false;
        return;
    }
    if (lora_link_active_tank_full()) {
        s_af_paused = false;
    }
    if (!lora_link_active_tank_low()) {
        s_af_armed = true; /* above the float: the next drop may start a fill */
        return;
    }
    if (!s_af_armed || s_af_paused || s_on || !pump_pair_is_paired()) {
        return;
    }
    if (relay_control_is_blocked() || pump_ota_is_active()) {
        return; /* pairing or an update: wait, still armed */
    }
    if (s_stopped_us != 0 && esp_timer_get_time() - s_stopped_us < AUTO_FILL_COOLDOWN_US) {
        return; /* stays armed: starts once the cooldown is over, if still low */
    }
    s_af_armed = false;
    ESP_LOGI(TAG, "Auto-fill: slot %u is low", slot);
    pump_control_set(true, PUMP_CAUSE_AUTO_FILL);
}

/** Stop the pump once it has run for the active tank's auto-off time. */
static void enforce_auto_off(void)
{
    if (!s_on) {
        return;
    }
    const uint8_t mins = pump_tanks_active_auto_off_min();
    if (pump_control_run_seconds() < (uint32_t)mins * 60u) {
        return;
    }
    ESP_LOGW(TAG, "Auto-off after %u min", mins);
    pump_control_set_silent(false, PUMP_CAUSE_AUTO_OFF);
    if (pump_config_buzzer_on_auto()) {
        buzzer_play(BUZZER_TONE_DOUBLE, false);
    }
}

void pump_control_poll(void)
{
    lock();
    pump_runlog_poll(s_on, pump_control_run_seconds());
    start_due_schedule();
    start_due_auto_fill();
    enforce_auto_off();
    unlock();
}
