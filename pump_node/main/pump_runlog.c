#include "pump_runlog.h"

#include <string.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "pump_clock.h"

#define TAG "RUNLOG"
#define NVS_NS "tl_run"
#define NVS_KEY_RUN "run"
#define NVS_KEY_EVENT "event"
#define REC_VER 1
/* How often the running record is refreshed. Bounds the "ran for" error. */
#define REFRESH_US (60LL * 1000000)

typedef struct {
    uint8_t ver;
    uint8_t reserved[3];
    uint32_t started_local;
    uint32_t last_seen_local;
    uint32_t run_sec;
} run_rec_t;

typedef struct {
    uint8_t ver;
    pump_runlog_event_t ev;
} event_rec_t;

static SemaphoreHandle_t s_mu;
static bool s_active;
static run_rec_t s_run;
static int64_t s_last_refresh_us;
static bool s_has_event;
static pump_runlog_event_t s_event;

static uint32_t local_now(void)
{
    int64_t t = 0;
    if (!pump_clock_unix_now(&t) || t <= 0 || t > UINT32_MAX) {
        return 0;
    }
    return (uint32_t)t;
}

static void lock(void)
{
    if (s_mu) {
        xSemaphoreTake(s_mu, portMAX_DELAY);
    }
}

static void unlock(void)
{
    if (s_mu) {
        xSemaphoreGive(s_mu);
    }
}

static void nvs_put(const char *key, const void *data, size_t len)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    esp_err_t err = data ? nvs_set_blob(h, key, data, len) : nvs_erase_key(h, key);
    if (err == ESP_OK || err == ESP_ERR_NVS_NOT_FOUND) {
        nvs_commit(h);
    } else {
        ESP_LOGW(TAG, "nvs %s: %s", key, esp_err_to_name(err));
    }
    nvs_close(h);
}

static bool nvs_get(const char *key, void *data, size_t len)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return false;
    }
    size_t got = len;
    esp_err_t err = nvs_get_blob(h, key, data, &got);
    nvs_close(h);
    return err == ESP_OK && got == len;
}

static void save_event(void)
{
    event_rec_t rec = {.ver = REC_VER, .ev = s_event};
    nvs_put(NVS_KEY_EVENT, &rec, sizeof(rec));
}

static uint8_t reason_from_reset(void)
{
    switch (esp_reset_reason()) {
    case ESP_RST_POWERON:
        return PUMP_RUNLOG_POWER_LOST;
    case ESP_RST_BROWNOUT:
        return PUMP_RUNLOG_BROWNOUT;
    default:
        return PUMP_RUNLOG_RESTARTED;
    }
}

void pump_runlog_init(void)
{
    s_mu = xSemaphoreCreateMutex();

    event_rec_t ev_rec;
    if (nvs_get(NVS_KEY_EVENT, &ev_rec, sizeof(ev_rec)) && ev_rec.ver == REC_VER &&
        ev_rec.ev.reason != PUMP_RUNLOG_NONE) {
        s_event = ev_rec.ev;
        s_has_event = true;
    }

    run_rec_t run;
    if (!nvs_get(NVS_KEY_RUN, &run, sizeof(run)) || run.ver != REC_VER) {
        if (s_has_event) {
            ESP_LOGI(TAG,
                     "earlier interrupted fill waiting to be dismissed: reason %u, ran ~%u s, "
                     "started %u, last seen %u, back %u (pump-local s)",
                     (unsigned)s_event.reason, (unsigned)s_event.ran_sec,
                     (unsigned)s_event.started_local, (unsigned)s_event.last_seen_local,
                     (unsigned)s_event.back_local);
        }
        return;
    }
    /* The pump was running when the board went down. */
    memset(&s_event, 0, sizeof(s_event));
    s_event.reason = reason_from_reset();
    s_event.started_local = run.started_local;
    s_event.last_seen_local = run.last_seen_local;
    s_event.back_local = local_now();
    s_event.ran_sec = run.run_sec;
    s_has_event = true;
    save_event();
    nvs_put(NVS_KEY_RUN, NULL, 0);
    ESP_LOGW(TAG, "fill interrupted (reason %u) after ~%u s; pump stays off",
             (unsigned)s_event.reason, (unsigned)s_event.ran_sec);
}

void pump_runlog_on_start(void)
{
    lock();
    const uint32_t now = local_now();
    s_run = (run_rec_t){
        .ver = REC_VER,
        .started_local = now,
        .last_seen_local = now,
        .run_sec = 0,
    };
    s_active = true;
    s_last_refresh_us = esp_timer_get_time();
    run_rec_t copy = s_run;
    unlock();
    nvs_put(NVS_KEY_RUN, &copy, sizeof(copy));
}

void pump_runlog_on_stop(void)
{
    lock();
    const bool was = s_active;
    s_active = false;
    unlock();
    if (was) {
        nvs_put(NVS_KEY_RUN, NULL, 0);
    }
}

void pump_runlog_poll(bool running, uint32_t run_sec)
{
    lock();
    bool save_run = false;
    run_rec_t copy;
    if (running && s_active && esp_timer_get_time() - s_last_refresh_us >= REFRESH_US) {
        s_last_refresh_us = esp_timer_get_time();
        const uint32_t now = local_now();
        if (s_run.started_local == 0 && now != 0) {
            /* Clock arrived mid-run (phone sync): back-date the start. */
            s_run.started_local = now > run_sec ? now - run_sec : 0;
        }
        s_run.last_seen_local = now;
        s_run.run_sec = run_sec;
        copy = s_run;
        save_run = true;
    }
    bool save_ev = false;
    if (s_has_event && s_event.back_local == 0) {
        /* Clock became known after boot: work out when the board came back. */
        const uint32_t now = local_now();
        const uint32_t up = (uint32_t)(esp_timer_get_time() / 1000000LL);
        if (now > up) {
            s_event.back_local = now - up;
            save_ev = true;
        }
    }
    unlock();
    if (save_run) {
        nvs_put(NVS_KEY_RUN, &copy, sizeof(copy));
    }
    if (save_ev) {
        save_event();
    }
}

const pump_runlog_event_t *pump_runlog_event(void)
{
    return s_has_event ? &s_event : NULL;
}

void pump_runlog_clear_event(void)
{
    lock();
    const bool had = s_has_event;
    s_has_event = false;
    memset(&s_event, 0, sizeof(s_event));
    unlock();
    if (had) {
        nvs_put(NVS_KEY_EVENT, NULL, 0);
        ESP_LOGI(TAG, "interrupted-fill notice dismissed");
    }
}
