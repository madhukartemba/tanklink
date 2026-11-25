#include "pump_control.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "board.h"
#include "pump_autofill.h"
#include "pump_buzz.h"
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
#include "pump_update.h"
#include "relay_control.h"
#include "status_led.h"
#include "tanklink_lora_proto.h"

#define TAG "PUMP_CTL"

static bool s_on;
static int64_t s_on_since_us;
/* The running fill, for the history entry written when it stops. */
static uint32_t s_fill_started_local;
static uint8_t s_fill_started_by;
static uint8_t s_last_error;

/* The button task, the BLE host, the LoRa task and the poll task all switch
 * the pump. One lock keeps a start and a stop from interleaving (a fill
 * counted twice, or the relay and s_on disagreeing). Recursive: the poll
 * holds it while it starts or stops a fill. */
static SemaphoreHandle_t s_lock;

static void lock(void)
{
    xSemaphoreTakeRecursive(s_lock, portMAX_DELAY);
}

static void unlock(void)
{
    xSemaphoreGiveRecursive(s_lock);
}

void pump_control_init(void)
{
    s_lock = xSemaphoreCreateRecursiveMutex();
    configASSERT(s_lock);
}

bool pump_control_is_on(void)
{
    return s_on;
}

uint8_t pump_control_started_by(void)
{
    return s_on ? s_fill_started_by : PUMP_CAUSE_UNKNOWN;
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

void pump_control_restore_led(void)
{
    const status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_ERROR || mode == STATUS_LED_HOLD_PROGRESS) {
        return;
    }
    if (pump_update_in_progress()) {
        status_led_set_mode(STATUS_LED_UPDATING); /* back to the update animation */
    } else if (pump_pair_pairing_active()) {
        status_led_set_mode(STATUS_LED_PAIRING);
    } else if (!pump_pair_is_paired()) {
        status_led_set_mode(STATUS_LED_UNPAIRED);
    } else if (s_on) {
        status_led_set_mode(STATUS_LED_PUMP_ON);
    } else {
        status_led_set_mode(STATUS_LED_IDLE);
    }
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

static void deny_start(uint8_t code, pump_cause_t cause)
{
    /* Someone asked from the app: say no out loud. The button already
     * sounded at its 1 s mark, and automatic starts stay quiet. */
    if (cause == PUMP_CAUSE_APP) {
        pump_buzz(PUMP_BUZZ_DENIED);
    }
    if (code == PUMP_ERR_UPDATING) {
        /* Not a fault: keep the update light, no error code, no banner in the
         * app. A soft pulse shows the press was seen. */
        status_led_notify_activity();
        return;
    }
    s_last_error = code;
    status_led_show_error(code);
    gatt_svr_notify_tank();
}

/** Returns the reason the pump may not start now, or PUMP_ERR_NONE. */
static uint8_t start_blocker(void)
{
    if (pump_update_in_progress()) {
        return PUMP_ERR_UPDATING;
    }
    if (relay_control_is_blocked() || pump_ota_is_active()) {
        return PUMP_ERR_BLOCKED;
    }
    /* Only the selected tank counts: with a lever, others may already be full. */
    if (lora_link_active_tank_full()) {
        return PUMP_ERR_TANK_FULL;
    }
    return PUMP_ERR_NONE;
}

uint8_t pump_control_start_blocker(void)
{
    lock();
    const uint8_t blocker = start_blocker();
    unlock();
    return blocker;
}

/* The button sounds by itself (board / main.c), so it has no event here. */
static void buzz_for(bool on, pump_cause_t cause)
{
    switch (cause) {
    case PUMP_CAUSE_BUTTON:
        return;
    case PUMP_CAUSE_SCHEDULE:
        pump_buzz(PUMP_BUZZ_SCHEDULE);
        return;
    case PUMP_CAUSE_AUTO_FILL:
    case PUMP_CAUSE_AUTO_FILL_TIME:
        pump_buzz(PUMP_BUZZ_AUTO_FILL);
        return;
    case PUMP_CAUSE_TANK_FULL:
        pump_buzz(PUMP_BUZZ_TANK_FULL);
        return;
    case PUMP_CAUSE_AUTO_OFF:
        pump_buzz(PUMP_BUZZ_AUTO_OFF);
        return;
    default:
        pump_buzz(on ? PUMP_BUZZ_PUMP_START : PUMP_BUZZ_PUMP_STOP);
        return;
    }
}

static void set_state(bool on, bool beep, pump_cause_t cause)
{
    if (on) {
        const uint8_t blocker = start_blocker();
        if (blocker != PUMP_ERR_NONE) {
            ESP_LOGW(TAG, "Start denied, error %u", blocker);
            deny_start(blocker, cause);
            return;
        }
        /* The relay layer has the last word (a block set from another task). */
        if (!relay_control_start()) {
            deny_start(PUMP_ERR_BLOCKED, cause);
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
        pump_autofill_on_stop(s_fill_started_by, cause);
    }
    if (!on) {
        s_on_since_us = 0;
        pump_runlog_on_stop();
    }
    s_on = on;
    board_set_pump_on(on);
    if (!on) {
        /* Always act on the starter, even if we thought it was already off. */
        relay_control_stop();
    }
    ESP_LOGI(TAG, "Pump %s", on ? "on" : "off");
    if (changed && beep) {
        buzz_for(on, cause);
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

bool pump_control_switch_tank(uint8_t slot)
{
    if (slot == pump_tanks_active()) {
        return true;
    }
    if (s_on || pump_tanks_select(slot, false) != ESP_OK) {
        return false;
    }
    lora_link_on_active_changed();
    gatt_svr_notify_tanks();
    gatt_svr_notify_tank();
    gatt_svr_notify_nodes();
    return true;
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
    if (!pump_control_switch_tank((uint8_t)slot)) {
        ESP_LOGW(TAG, "Schedule slot %d missing", slot);
        return;
    }
    ESP_LOGI(TAG, "Schedule start %02u:%02u slot %d", now.hour, now.minute, slot);
    pump_control_set(true, PUMP_CAUSE_SCHEDULE);
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
    pump_control_set(false, PUMP_CAUSE_AUTO_OFF);
}

void pump_control_poll(void)
{
    lock();
    pump_runlog_poll(s_on, pump_control_run_seconds());
    start_due_schedule();
    pump_autofill_poll();
    enforce_auto_off();
    unlock();
}
