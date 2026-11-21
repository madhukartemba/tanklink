/*
 * The pump looks for and installs its own firmware over Wi-Fi: when to check,
 * when it is safe to install, and the state the app shows. The network half is
 * pump_update_http.c, the flash half pump_ota.c.
 */
#include "pump_update.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"

#include "gatt_svr.h"
#include "lora_link.h"
#include "pump_api.h"
#include "pump_clock.h"
#include "pump_config.h"
#include "pump_control.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "pump_update_http.h"
#include "pump_wifi.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "UPDATE"
#define NVS_NS "tl_upd"
#define NVS_KEY_AUTO_VER "overnight"

/* ---- When to check ---- */
#define CHECK_EVERY_US (6LL * 3600 * 1000000)
/* The first check after a start: a random minute, so pumps don't all ask at once. */
#define FIRST_CHECK_MIN_S 60
#define FIRST_CHECK_SPAN_S 3600
/* A check that failed is retried after this, doubling up to CHECK_EVERY_US. */
#define CHECK_RETRY_FIRST_US (15LL * 60 * 1000000)
/* A check that fell due while the pump was busy waits this long. */
#define CHECK_DEFER_US (2LL * 60 * 1000000)

/* ---- When it is safe to install by itself (see auto_install_ok) ---- */
#define SCHED_GUARD_MIN 60
#define AUTO_IDLE_US (10LL * 60 * 1000000)
#define AUTO_MIN_UPTIME_US (10LL * 60 * 1000000)
#define AUTO_RETRY_US (6LL * 3600 * 1000000)

/* ---- The download ---- */
/* The TLS handshake and certificate checks run on the job task: measured use is
 * about 3.3 KB, so this leaves plenty of margin. */
#define JOB_STACK 6144
/* A download that can't connect or stalls is tried again this many times. */
#define DOWNLOAD_TRIES 3

#define NEVER_MIN 0xFFFF

typedef enum { JOB_NONE, JOB_CHECK, JOB_INSTALL, JOB_INSTALL_AUTO } job_t;

static volatile job_t s_busy; /* the job the task is running */
static volatile uint8_t s_check_result = TANKLINK_CHECK_NEVER;

/* The newest release the last check found, if it is newer than this firmware. */
static bool s_avail;
static pump_update_offer_t s_offer;

static uint8_t s_auto_version[3]; /* installed by itself, until the app has shown it */

static int64_t s_next_check_us; /* 0 = not scheduled yet */
static int64_t s_retry_us = CHECK_RETRY_FIRST_US;
static int64_t s_last_ok_us; /* the last check that got an answer, 0 = none */
static int64_t s_next_auto_try_us;
static int64_t s_last_on_us; /* last time the pump was seen running */

/* ---------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */

static void changed(void)
{
    gatt_svr_notify_wifi();
}

static bool newer_than_running(const uint8_t v[3])
{
    const uint8_t cur[3] = {TANKLINK_FW_MAJOR, TANKLINK_FW_MINOR, TANKLINK_FW_PATCH};
    for (int i = 0; i < 3; i++) {
        if (v[i] != cur[i]) {
            return v[i] > cur[i];
        }
    }
    return false;
}

static void save_auto_version(const uint8_t v[3])
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    if (v) {
        nvs_set_blob(h, NVS_KEY_AUTO_VER, v, 3);
    } else {
        nvs_erase_key(h, NVS_KEY_AUTO_VER);
    }
    nvs_commit(h);
    nvs_close(h);
}

/** Why a check shouldn't run now, or NULL. A check is a TLS connection: not
 * while the pump runs, an update is being written, or a pairing window is open. */
static const char *check_busy_reason(void)
{
    if (pump_control_is_on()) {
        return "the pump is running";
    }
    if (pump_update_in_progress()) {
        return "an update is running";
    }
    if (pump_pair_pairing_active() || lora_link_tank_pairing_active()) {
        return "pairing is open";
    }
    return NULL;
}

/* ---------------------------------------------------------------------------
 * Check
 * ------------------------------------------------------------------------- */

static void do_check(void)
{
    pump_update_offer_t offer;
    switch (pump_update_http_latest(&offer)) {
    case PUMP_UPDATE_FETCH_OFFER:
        s_avail = newer_than_running(offer.version);
        if (s_avail) {
            s_offer = offer;
            ESP_LOGI(TAG, "update available: %u.%u.%u (%u bytes)", offer.version[0],
                     offer.version[1], offer.version[2], (unsigned)offer.size);
        }
        s_check_result = TANKLINK_CHECK_OK;
        break;
    case PUMP_UPDATE_FETCH_NONE:
        s_avail = false; /* nothing fits this board */
        s_check_result = TANKLINK_CHECK_OK;
        break;
    case PUMP_UPDATE_FETCH_NO_INTERNET:
        s_check_result = TANKLINK_CHECK_NO_INTERNET;
        break;
    default:
        s_check_result = TANKLINK_CHECK_ERROR;
        break;
    }

    /* The next check: a normal gap after an answer, a growing retry after a failure. */
    const int64_t now = esp_timer_get_time();
    if (s_check_result == TANKLINK_CHECK_OK) {
        s_last_ok_us = now;
        s_retry_us = CHECK_RETRY_FIRST_US;
        s_next_check_us = now + CHECK_EVERY_US;
    } else {
        s_next_check_us = now + s_retry_us;
        s_retry_us = s_retry_us * 2 > CHECK_EVERY_US ? CHECK_EVERY_US : s_retry_us * 2;
    }
}

/* ---------------------------------------------------------------------------
 * Install
 * ------------------------------------------------------------------------- */

typedef struct {
    uint32_t offset;
} ota_feed_t;

/** The download's sink: each chunk goes to the OTA session, in order. */
static bool feed_ota(const uint8_t *data, size_t len, void *arg)
{
    ota_feed_t *f = arg;
    if (pump_ota_write(PUMP_API_LOCAL_ID, f->offset, data, (uint16_t)len) != TANKLINK_OTA_ERR_OK) {
        return false; /* pump_ota has already cleaned up */
    }
    f->offset += (uint32_t)len;
    return true;
}

/** One try: start the OTA session and download into it. True when all bytes arrived. */
static bool download_once(void)
{
    if (pump_ota_start(PUMP_API_LOCAL_ID, s_offer.size, s_offer.sha256) != TANKLINK_OTA_ERR_OK) {
        ESP_LOGW(TAG, "install: OTA refused to start");
        return false;
    }
    gatt_svr_notify_ota_status();

    ota_feed_t feed = {0};
    uint32_t got = 0;
    const bool ok = pump_update_http_download(&s_offer, feed_ota, &feed, &got);
    if (!ok) {
        if (pump_ota_is_active()) {
            pump_ota_abort_from(PUMP_API_LOCAL_ID);
        }
        gatt_svr_notify_ota_status();
    }
    return ok;
}

static void do_install(bool automatic)
{
    if (pump_control_is_on() || pump_ota_is_active()) {
        ESP_LOGW(TAG, "install refused: pump busy");
        return;
    }
    /* Show the update animation for the whole install, including the TLS setup
     * and the pauses between tries, and don't flash red on a failed try. */
    if (status_led_get_mode() == STATUS_LED_IDLE) {
        status_led_set_mode(STATUS_LED_UPDATING);
    }
    pump_ota_set_led_hold(true);

    /* The download host sometimes doesn't answer: try again, a new connection
     * may reach another address. */
    bool ok = false;
    for (int attempt = 1; attempt <= DOWNLOAD_TRIES && !ok; attempt++) {
        if (attempt > 1) {
            ESP_LOGI(TAG, "download try %d of %d", attempt, DOWNLOAD_TRIES);
            vTaskDelay(pdMS_TO_TICKS(3000));
            if (pump_control_is_on()) {
                break; /* someone started the pump meanwhile */
            }
        }
        ok = download_once();
    }
    pump_ota_set_led_hold(false);
    if (!ok) {
        /* Failed for good: the light goes back to normal. */
        if (status_led_get_mode() == STATUS_LED_UPDATING) {
            pump_control_restore_led();
        }
        return;
    }

    if (automatic) {
        save_auto_version(s_offer.version); /* shown once after the restart */
    }
    const uint8_t r = pump_ota_finish(PUMP_API_LOCAL_ID);
    gatt_svr_notify_ota_status();
    if (r != TANKLINK_OTA_ERR_OK) {
        ESP_LOGW(TAG, "image refused (hash or signature), err=%u", r);
        save_auto_version(NULL);
    }
}

/* ---------------------------------------------------------------------------
 * Jobs: one at a time, on a short-lived task
 * ------------------------------------------------------------------------- */

static void job_task(void *arg)
{
    const job_t job = (job_t)(uintptr_t)arg;
    changed();
    if (job == JOB_CHECK) {
        do_check();
    } else {
        do_install(job == JOB_INSTALL_AUTO);
    }
    s_busy = JOB_NONE;
    changed();
    vTaskDelete(NULL);
}

static esp_err_t start_job(job_t job)
{
    if (s_busy != JOB_NONE || pump_wifi_state() != PUMP_WIFI_CONNECTED) {
        return ESP_ERR_INVALID_STATE;
    }
    s_busy = job;
    if (xTaskCreate(job_task, "pump_update", JOB_STACK, (void *)(uintptr_t)job, 3, NULL) != pdPASS) {
        s_busy = JOB_NONE;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

esp_err_t pump_update_request_check(void)
{
    if (pump_wifi_state() != PUMP_WIFI_CONNECTED) {
        s_check_result = TANKLINK_CHECK_NO_INTERNET;
        changed();
        return ESP_ERR_INVALID_STATE;
    }
    const char *why = check_busy_reason();
    if (why) {
        ESP_LOGI(TAG, "check refused: %s", why);
        return ESP_ERR_INVALID_STATE;
    }
    return start_job(JOB_CHECK);
}

esp_err_t pump_update_request_install(void)
{
    if (!s_avail || pump_control_is_on() || pump_ota_is_active()) {
        return ESP_ERR_INVALID_STATE;
    }
    return start_job(JOB_INSTALL);
}

/* ---------------------------------------------------------------------------
 * Status
 * ------------------------------------------------------------------------- */

bool pump_update_in_progress(void)
{
    return s_busy == JOB_INSTALL || s_busy == JOB_INSTALL_AUTO || pump_ota_is_active();
}

uint8_t pump_update_state(void)
{
    switch (s_busy) {
    case JOB_CHECK:
        return TANKLINK_UPDATE_CHECKING;
    case JOB_INSTALL:
    case JOB_INSTALL_AUTO:
        return TANKLINK_UPDATE_INSTALLING;
    default:
        return s_avail ? TANKLINK_UPDATE_AVAILABLE : TANKLINK_UPDATE_NONE;
    }
}

uint8_t pump_update_check_result(void)
{
    return s_check_result;
}

void pump_update_available_version(uint8_t out[3])
{
    if (s_avail) {
        memcpy(out, s_offer.version, 3);
    } else {
        memset(out, 0, 3);
    }
}

uint32_t pump_update_available_size(void)
{
    return s_avail ? s_offer.size : 0;
}

uint16_t pump_update_last_check_age_min(void)
{
    if (s_last_ok_us == 0) {
        return NEVER_MIN;
    }
    const int64_t min = (esp_timer_get_time() - s_last_ok_us) / 60000000LL;
    return (uint16_t)(min > NEVER_MIN - 1 ? NEVER_MIN - 1 : min);
}

void pump_update_overnight_version(uint8_t out[3])
{
    memcpy(out, s_auto_version, 3);
}

void pump_update_dismiss_overnight(void)
{
    memset(s_auto_version, 0, sizeof(s_auto_version));
    save_auto_version(NULL);
}

void pump_update_init(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    uint8_t v[3];
    size_t n = sizeof(v);
    const bool have = nvs_get_blob(h, NVS_KEY_AUTO_VER, v, &n) == ESP_OK && n == 3;
    nvs_close(h);
    if (!have) {
        return;
    }
    if (v[0] == TANKLINK_FW_MAJOR && v[1] == TANKLINK_FW_MINOR && v[2] == TANKLINK_FW_PATCH) {
        memcpy(s_auto_version, v, 3); /* it really did update: tell the app once */
    } else {
        save_auto_version(NULL); /* the install never completed */
    }
}

/* ---------------------------------------------------------------------------
 * Poll
 * ------------------------------------------------------------------------- */

/** True if a fill schedule is due within [minutes] of [now]. */
static bool schedule_within(const pump_civil_time_t *now, int minutes)
{
    const int m = (int)now->hour * 60 + (int)now->minute;
    const pump_sched_entry_t *e = pump_sched_entries();
    for (unsigned i = 0; i < pump_sched_count(); i++) {
        if (!e[i].enabled) {
            continue;
        }
        const int d = ((int)e[i].hour * 60 + (int)e[i].minute - m + 1440) % 1440;
        if (d < minutes) {
            return true;
        }
    }
    return false;
}

/**
 * Automatic install, whenever it is least likely to get in the way:
 *  - the pump is off, and has been for a while (someone may start it again);
 *  - no fill schedule is due within the next SCHED_GUARD_MIN minutes. With
 *    schedules set the clock must be known, or the pump can't tell;
 *  - a tank that fills by itself is not low, so auto-fill isn't about to start;
 *  - the pump has been up for a while (not straight after a restart).
 * A failed try waits AUTO_RETRY_US before the next.
 */
static bool auto_install_ok(int64_t t)
{
    if (!pump_config_auto_update() || !s_avail || t < s_next_auto_try_us ||
        t < AUTO_MIN_UPTIME_US) {
        return false;
    }
    if (pump_control_is_on() || pump_ota_is_active()) {
        return false;
    }
    if (s_last_on_us != 0 && t - s_last_on_us < AUTO_IDLE_US) {
        return false;
    }
    if (pump_sched_count() > 0) {
        pump_civil_time_t now;
        if (!pump_clock_now(&now) || schedule_within(&now, SCHED_GUARD_MIN)) {
            return false;
        }
    }
    if (pump_tanks_auto_fill_on(pump_tanks_active()) && lora_link_active_tank_low()) {
        return false;
    }
    return true;
}

void pump_update_poll(void)
{
    const int64_t t = esp_timer_get_time();
    if (pump_control_is_on()) {
        s_last_on_us = t;
    }
    if (s_busy != JOB_NONE || pump_wifi_state() != PUMP_WIFI_CONNECTED) {
        return;
    }
    if (s_next_check_us == 0) {
        s_next_check_us =
            t + (int64_t)(FIRST_CHECK_MIN_S + esp_random() % FIRST_CHECK_SPAN_S) * 1000000;
    }
    if (t >= s_next_check_us) {
        if (check_busy_reason()) {
            s_next_check_us = t + CHECK_DEFER_US; /* not now: not a failure */
        } else if (start_job(JOB_CHECK) != ESP_OK) {
            s_next_check_us = t + CHECK_DEFER_US;
        }
        return;
    }
    if (auto_install_ok(t)) {
        s_next_auto_try_us = t + AUTO_RETRY_US;
        ESP_LOGI(TAG, "installing %u.%u.%u automatically (pump idle, no fill planned)",
                 s_offer.version[0], s_offer.version[1], s_offer.version[2]);
        start_job(JOB_INSTALL_AUTO);
    }
}
