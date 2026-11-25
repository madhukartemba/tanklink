#include "pump_autofill.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "nvs.h"

#include "gatt_svr.h"
#include "lora_link.h"
#include "pump_clock.h"
#include "pump_control.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_tanks.h"
#include "pump_update.h"
#include "pump_window.h"
#include "relay_control.h"

#define TAG "AUTOFILL"
#define NVS_NS "tl_afill"
#define NVS_KEY "cfg"
#define AF_MAGIC 0x41464C31u /* 'AFL1' */

typedef struct {
    uint8_t enabled;
    uint8_t days;
    uint8_t sh, sm, eh, em;
} af_window_t;

typedef struct {
    uint32_t magic;
    uint8_t flags;
    uint8_t gap_min;
    uint8_t count;
    uint8_t reserved;
    af_window_t win[PUMP_AF_WINDOW_MAX];
} af_cfg_t;

static af_cfg_t s_cfg;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

/* Run state, touched only by the poll and the stop hook (pump_control lock). */
static uint8_t s_slot = 0xFF;
static bool s_armed;
static bool s_paused;
static int64_t s_last_stop_us; /* 0 = no stop since boot */
static volatile bool s_arm_req;

/* What the app last saw. */
static uint8_t s_state = PUMP_AF_OFF;
static uint16_t s_wait = PUMP_AF_WAIT_NONE;
static uint8_t s_sent_state = 0xFF, s_sent_slot = 0xFF;
static uint16_t s_sent_wait;

static void load_defaults(af_cfg_t *c)
{
    memset(c, 0, sizeof(*c));
    c->magic = AF_MAGIC;
    c->gap_min = PUMP_AF_GAP_MIN_DEFAULT;
}

static bool cfg_valid(const af_cfg_t *c)
{
    if ((c->flags & ~(PUMP_AF_F_LIMIT | PUMP_AF_F_STOP_AT_END)) ||
        c->gap_min < PUMP_AF_GAP_MIN_MIN || c->gap_min > PUMP_AF_GAP_MIN_MAX ||
        c->count > PUMP_AF_WINDOW_MAX) {
        return false;
    }
    for (unsigned i = 0; i < c->count; i++) {
        const af_window_t *w = &c->win[i];
        if (w->enabled > 1 || !pump_window_valid(w->days, w->sh, w->sm, w->eh, w->em)) {
            return false;
        }
    }
    return true;
}

static esp_err_t save(const af_cfg_t *c)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY, c, sizeof(*c));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

esp_err_t pump_autofill_init(void)
{
    load_defaults(&s_cfg);
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READONLY, &h);
    if (err == ESP_OK) {
        af_cfg_t c;
        size_t len = sizeof(c);
        err = nvs_get_blob(h, NVS_KEY, &c, &len);
        nvs_close(h);
        if (err == ESP_OK && (len != sizeof(c) || c.magic != AF_MAGIC || !cfg_valid(&c))) {
            err = ESP_ERR_NVS_INVALID_LENGTH;
        }
        if (err == ESP_OK) {
            s_cfg = c;
        }
    }
    if (err == ESP_ERR_NVS_NOT_FOUND || err == ESP_ERR_NVS_INVALID_LENGTH) {
        ESP_LOGW(TAG, "no valid auto-fill settings saved; using defaults");
        load_defaults(&s_cfg);
        err = save(&s_cfg);
    } else if (err != ESP_OK) {
        ESP_LOGE(TAG, "auto-fill settings read failed: %s", esp_err_to_name(err));
        load_defaults(&s_cfg);
    }
    ESP_LOGI(TAG, "flags=0x%02x gap=%u min windows=%u", s_cfg.flags, s_cfg.gap_min,
             s_cfg.count);
    return err;
}

static af_cfg_t snapshot(void)
{
    portENTER_CRITICAL(&s_mux);
    const af_cfg_t c = s_cfg;
    portEXIT_CRITICAL(&s_mux);
    return c;
}

static pump_window_t to_window(const af_window_t *w)
{
    return (pump_window_t){
        .days = w->days,
        .start = (uint16_t)(w->sh * 60 + w->sm),
        .end = (uint16_t)(w->eh * 60 + w->em),
    };
}

static bool any_open(const af_cfg_t *c, const pump_civil_time_t *now)
{
    for (unsigned i = 0; i < c->count; i++) {
        const pump_window_t w = to_window(&c->win[i]);
        if (c->win[i].enabled && pump_window_open(&w, now)) {
            return true;
        }
    }
    return false;
}

static uint16_t minutes_to_next(const af_cfg_t *c, const pump_civil_time_t *now)
{
    uint32_t best = PUMP_WINDOW_NEVER;
    for (unsigned i = 0; i < c->count; i++) {
        if (!c->win[i].enabled) {
            continue;
        }
        const pump_window_t w = to_window(&c->win[i]);
        const uint32_t m = pump_window_minutes_until(&w, now);
        if (m < best) {
            best = m;
        }
    }
    return best == PUMP_WINDOW_NEVER ? PUMP_AF_WAIT_NONE
                                     : (uint16_t)(best < 0xFFFE ? best : 0xFFFE);
}

/** The state to show, and starts or stops the pump when it is time. */
static pump_af_state_t step(uint16_t *wait)
{
    *wait = PUMP_AF_WAIT_NONE;
    const af_cfg_t c = snapshot();
    /* Only while the auto-fill tank is selected: the selection is the user
     * saying where the valve or lever points. */
    const uint8_t slot = pump_tanks_auto_fill_slot();
    const bool selected = slot == pump_tanks_active();
    if (slot != s_slot || !selected) {
        s_slot = slot;
        s_armed = false;
        s_paused = false;
    }
    if (s_arm_req) {
        s_arm_req = false;
        s_armed = true;
        s_paused = false;
    }
    if (!pump_tanks_auto_fill_on(slot)) {
        s_armed = false;
        s_paused = false;
        return PUMP_AF_OFF;
    }
    if (!selected) {
        return PUMP_AF_NOT_SELECTED; /* armed afresh once it is selected */
    }

    const bool limited = (c.flags & PUMP_AF_F_LIMIT) != 0;
    pump_civil_time_t now;
    const bool have_time = pump_clock_now(&now);

    if (pump_control_is_on()) {
        if (pump_control_started_by() != PUMP_CAUSE_AUTO_FILL) {
            return lora_link_slot_low(slot) ? PUMP_AF_PUMP_ON : PUMP_AF_WATCHING;
        }
        if (limited && (c.flags & PUMP_AF_F_STOP_AT_END) && have_time && !any_open(&c, &now)) {
            ESP_LOGI(TAG, "Allowed time over: stopping");
            pump_control_set(false, PUMP_CAUSE_AUTO_FILL_TIME);
            *wait = minutes_to_next(&c, &now);
            return PUMP_AF_WAIT_TIME;
        }
        return PUMP_AF_FILLING;
    }

    if (!lora_link_slot_online(slot)) {
        return PUMP_AF_OFFLINE;
    }
    if (lora_link_slot_full(slot)) {
        s_paused = false;
    }
    /* Arm and start only on what the tank said since this boot. */
    if (!lora_link_slot_fresh(slot)) {
        return PUMP_AF_WATCHING;
    }
    if (!lora_link_slot_low(slot)) {
        s_armed = true; /* above its low mark: the next drop may start a fill */
        return PUMP_AF_WATCHING;
    }
    if (s_paused) {
        return PUMP_AF_PAUSED;
    }
    if (!s_armed) {
        return PUMP_AF_WAIT_ARM;
    }
    if (!pump_pair_is_paired() || relay_control_is_blocked() || pump_ota_is_active() ||
        pump_update_in_progress()) {
        return PUMP_AF_BUSY; /* still armed: starts once it is over, if still low */
    }
    /* Outside the allowed times first: that is usually the longer wait. */
    if (limited) {
        if (!have_time) {
            return PUMP_AF_NO_CLOCK;
        }
        if (!any_open(&c, &now)) {
            *wait = minutes_to_next(&c, &now);
            return PUMP_AF_WAIT_TIME;
        }
    }
    if (s_last_stop_us != 0) {
        const int64_t gap_us = (int64_t)c.gap_min * 60 * 1000000;
        const int64_t left = gap_us - (esp_timer_get_time() - s_last_stop_us);
        if (left > 0) {
            *wait = (uint16_t)((left + 59999999) / 60000000);
            return PUMP_AF_COOLDOWN;
        }
    }
    ESP_LOGI(TAG, "slot %u is low: starting", slot);
    s_armed = false;
    pump_control_set(true, PUMP_CAUSE_AUTO_FILL);
    return pump_control_is_on() ? PUMP_AF_FILLING : PUMP_AF_WATCHING;
}

void pump_autofill_poll(void)
{
    uint16_t wait;
    s_state = (uint8_t)step(&wait);
    s_wait = wait;
    if (s_state != s_sent_state || s_slot != s_sent_slot || s_wait != s_sent_wait) {
        s_sent_state = s_state;
        s_sent_slot = s_slot;
        s_sent_wait = s_wait;
        gatt_svr_notify_autofill();
    }
}

void pump_autofill_on_stop(uint8_t started_by, pump_cause_t cause)
{
    s_last_stop_us = esp_timer_get_time();
    if (started_by != PUMP_CAUSE_AUTO_FILL) {
        return;
    }
    switch (cause) {
    case PUMP_CAUSE_TANK_FULL:
        break; /* re-arms once it is seen above the low mark */
    case PUMP_CAUSE_AUTO_FILL_TIME:
    case PUMP_CAUSE_SYSTEM:
        s_armed = true; /* not the tank's fault: carry on when allowed */
        break;
    default:
        s_paused = true;
        ESP_LOGW(TAG, "paused until the tank is full (stopped by %d)", cause);
        break;
    }
}

void pump_autofill_arm(void)
{
    s_arm_req = true;
}

size_t pump_autofill_payload(uint8_t out[PUMP_AF_PAYLOAD_MAX])
{
    const af_cfg_t c = snapshot();
    out[0] = s_state;
    out[1] = pump_tanks_auto_fill_slot();
    out[2] = (uint8_t)(s_wait & 0xFF);
    out[3] = (uint8_t)(s_wait >> 8);
    out[4] = c.flags;
    out[5] = c.gap_min;
    out[6] = c.count;
    size_t o = 7;
    for (unsigned i = 0; i < c.count; i++) {
        const af_window_t *w = &c.win[i];
        out[o++] = w->enabled;
        out[o++] = w->days;
        out[o++] = w->sh;
        out[o++] = w->sm;
        out[o++] = w->eh;
        out[o++] = w->em;
    }
    return o;
}

esp_err_t pump_autofill_write(const uint8_t *d, size_t len)
{
    if (len < 1) {
        return ESP_ERR_INVALID_SIZE;
    }
    if (d[0] == 0x02) {
        if (len != 1) {
            return ESP_ERR_INVALID_SIZE;
        }
        pump_autofill_arm();
        ESP_LOGI(TAG, "armed by the app");
        return ESP_OK;
    }
    if (d[0] != 0x01 || len < 4 || len != 4u + d[3] * PUMP_AF_WINDOW_LEN) {
        return ESP_ERR_INVALID_SIZE;
    }
    af_cfg_t c = snapshot();
    c.flags = d[1];
    c.gap_min = d[2];
    c.count = d[3];
    memset(c.win, 0, sizeof(c.win));
    if (c.count > PUMP_AF_WINDOW_MAX) {
        return ESP_ERR_INVALID_ARG;
    }
    for (unsigned i = 0; i < c.count; i++) {
        const uint8_t *p = &d[4 + i * PUMP_AF_WINDOW_LEN];
        c.win[i] = (af_window_t){p[0], p[1], p[2], p[3], p[4], p[5]};
    }
    if (!cfg_valid(&c)) {
        return ESP_ERR_INVALID_ARG;
    }
    const esp_err_t err = save(&c);
    if (err != ESP_OK) {
        return err;
    }
    portENTER_CRITICAL(&s_mux);
    s_cfg = c;
    portEXIT_CRITICAL(&s_mux);
    ESP_LOGI(TAG, "saved flags=0x%02x gap=%u windows=%u", c.flags, c.gap_min, c.count);
    return ESP_OK;
}
