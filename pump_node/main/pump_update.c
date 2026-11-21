#include "pump_update.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "sdkconfig.h"

#include "gatt_svr.h"
#include "pump_api.h"
#include "pump_clock.h"
#include "pump_config.h"
#include "pump_control.h"
#include "pump_ota.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "lora_link.h"
#include "pump_wifi.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "UPDATE"
#define NVS_NS "tl_upd"
#define NVS_KEY_OVERNIGHT "overnight"

#define CHECK_EVERY_US (24LL * 3600 * 1000000)
#define FIRST_CHECK_MIN_S 60
#define FIRST_CHECK_SPAN_S 3600
/* Automatic install: stay clear of fills (see auto_install_ok). */
#define SCHED_GUARD_MIN 60
#define AUTO_IDLE_US (10LL * 60 * 1000000)
#define AUTO_MIN_UPTIME_US (10LL * 60 * 1000000)
#define AUTO_RETRY_US (6LL * 3600 * 1000000)

/* The TLS handshake and certificate checks run on this task: measured use is
 * about 3.3 KB, so this leaves plenty of margin. */
#define JOB_STACK 6144
/* A download that can't connect or stalls is tried again this many times. */
#define DOWNLOAD_TRIES 3
#define DOWNLOAD_TIMEOUT_MS 10000
#define URL_MAX 320
#define REPLY_MAX 768

typedef enum { JOB_NONE, JOB_CHECK, JOB_INSTALL, JOB_INSTALL_AUTO } job_t;

static volatile job_t s_busy; /* the job the task is running */
static volatile uint8_t s_check_result = TANKLINK_CHECK_NEVER;

/* What the last check found. Written by the job task only while s_busy. */
static bool s_avail;
static uint8_t s_avail_ver[3];
static uint32_t s_size;
static uint8_t s_sha[32];
static char s_url[URL_MAX];

static uint8_t s_overnight[3];
static int64_t s_next_check_us; /* 0 = not scheduled yet */
static int64_t s_next_auto_try_us; /* no automatic install before this */
static int64_t s_last_on_us;       /* last time the pump was seen running */

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

/** Value of "key": "..." in [json] copied to [out] (cap bytes). */
static bool json_str(const char *json, const char *key, char *out, size_t cap)
{
    char pat[24];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) {
        return false;
    }
    p = strchr(p + strlen(pat), ':');
    while (p && *++p == ' ') {
    }
    if (!p || *p != '"') {
        return false;
    }
    const char *e = strchr(++p, '"');
    if (!e || (size_t)(e - p) >= cap) {
        return false;
    }
    memcpy(out, p, (size_t)(e - p));
    out[e - p] = '\0';
    return true;
}

static bool json_uint(const char *json, const char *key, uint32_t *out)
{
    char pat[24];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) {
        return false;
    }
    p = strchr(p + strlen(pat), ':');
    while (p && *++p == ' ') {
    }
    if (!p || *p < '0' || *p > '9') {
        return false;
    }
    *out = (uint32_t)strtoul(p, NULL, 10);
    return true;
}

static bool parse_hex(const char *s, uint8_t *out, size_t n)
{
    if (strlen(s) != n * 2) {
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(&s[i * 2], "%2x", &v) != 1) {
            return false;
        }
        out[i] = (uint8_t)v;
    }
    return true;
}

static bool parse_version(const char *s, uint8_t out[3])
{
    unsigned a, b, c;
    char tail;
    if (sscanf(s, "%u.%u.%u%c", &a, &b, &c, &tail) != 3 || a > 255 || b > 255 || c > 255) {
        return false;
    }
    out[0] = (uint8_t)a;
    out[1] = (uint8_t)b;
    out[2] = (uint8_t)c;
    return true;
}

/* ---------------------------------------------------------------------------
 * Check
 * ------------------------------------------------------------------------- */

static void do_check(void)
{
    char url[160];
    snprintf(url, sizeof(url), "%s/v1/firmware/pump/latest?hw=%d&proto=%d",
             CONFIG_PUMP_UPDATE_SERVER, TANKLINK_HW_REV, TANKLINK_PROTO_MAJOR);
    const esp_http_client_config_t cfg = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 10000,
        .buffer_size = 1024,
        .buffer_size_tx = 512,
    };
    esp_http_client_handle_t c = esp_http_client_init(&cfg);
    if (!c) {
        s_check_result = TANKLINK_CHECK_ERROR;
        return;
    }
    char *body = malloc(REPLY_MAX);
    if (!body) {
        esp_http_client_cleanup(c);
        s_check_result = TANKLINK_CHECK_ERROR;
        return;
    }
    int n = -1;
    int status = 0;
    const esp_err_t open_err = esp_http_client_open(c, 0);
    if (open_err != ESP_OK) {
        ESP_LOGW(TAG, "check: can't connect: %s", esp_err_to_name(open_err));
        s_check_result = TANKLINK_CHECK_NO_INTERNET;
        goto out;
    }
    esp_http_client_fetch_headers(c);
    status = esp_http_client_get_status_code(c);
    n = esp_http_client_read_response(c, body, REPLY_MAX - 1);
    esp_http_client_close(c);

    if (status == 404) {
        s_avail = false; /* nothing fits this board */
        s_check_result = TANKLINK_CHECK_OK;
        goto out;
    }
    if (status != 200 || n <= 0) {
        ESP_LOGW(TAG, "check: status %d", status);
        s_check_result = TANKLINK_CHECK_ERROR;
        goto out;
    }
    body[n] = '\0';

    char ver[16], sha[80];
    uint32_t size = 0;
    uint8_t v[3];
    uint8_t digest[32];
    static char url_buf[URL_MAX];
    if (!json_str(body, "version", ver, sizeof(ver)) || !parse_version(ver, v) ||
        !json_str(body, "url", url_buf, sizeof(url_buf)) ||
        !json_str(body, "sha256", sha, sizeof(sha)) || !parse_hex(sha, digest, 32) ||
        !json_uint(body, "size", &size) || size < 1024 || size > 0x1C0000u - 0x20u ||
        strncmp(url_buf, "https://", 8) != 0) {
        ESP_LOGW(TAG, "check: bad reply");
        s_check_result = TANKLINK_CHECK_ERROR;
        goto out;
    }
    if (newer_than_running(v)) {
        memcpy(s_avail_ver, v, 3);
        memcpy(s_sha, digest, 32);
        memcpy(s_url, url_buf, URL_MAX);
        s_size = size;
        s_avail = true;
        ESP_LOGI(TAG, "update available: %u.%u.%u (%u bytes)", v[0], v[1], v[2],
                 (unsigned)size);
    } else {
        s_avail = false;
    }
    s_check_result = TANKLINK_CHECK_OK;
out:
    free(body);
    esp_http_client_cleanup(c);
}

/* ---------------------------------------------------------------------------
 * Install
 * ------------------------------------------------------------------------- */

typedef struct {
    uint32_t offset;
    bool failed;
} download_t;

static esp_err_t on_http(esp_http_client_event_t *evt)
{
    download_t *d = evt->user_data;
    if (evt->event_id != HTTP_EVENT_ON_DATA || d->failed || evt->data_len <= 0) {
        return ESP_OK;
    }
    /* A redirect's own body is not the image. */
    if (esp_http_client_get_status_code(evt->client) != 200) {
        return ESP_OK;
    }
    if (pump_ota_write(PUMP_API_LOCAL_ID, d->offset, evt->data, (uint16_t)evt->data_len) !=
        TANKLINK_OTA_ERR_OK) {
        d->failed = true; /* pump_ota already cleaned up */
        return ESP_OK;
    }
    d->offset += (uint32_t)evt->data_len;
    return ESP_OK;
}

static void save_overnight(const uint8_t v[3])
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    if (v) {
        nvs_set_blob(h, NVS_KEY_OVERNIGHT, v, 3);
    } else {
        nvs_erase_key(h, NVS_KEY_OVERNIGHT);
    }
    nvs_commit(h);
    nvs_close(h);
}

/** One try: start the OTA session and download into it. True when all bytes arrived. */
static bool download_once(void)
{
    if (pump_ota_start(PUMP_API_LOCAL_ID, s_size, s_sha) != TANKLINK_OTA_ERR_OK) {
        ESP_LOGW(TAG, "install: OTA refused to start");
        return false;
    }
    gatt_svr_notify_ota_status();

    download_t d = {0};
    /* GitHub redirects to its download host with a long signed address. A short
     * timeout, because the pump_ota session times out after 60 s of silence. */
    const esp_http_client_config_t cfg = {
        .url = s_url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = DOWNLOAD_TIMEOUT_MS,
        .buffer_size = 4096,
        .buffer_size_tx = 1024,
        .max_redirection_count = 5,
        .event_handler = on_http,
        .user_data = &d,
    };
    esp_http_client_handle_t c = esp_http_client_init(&cfg);
    const esp_err_t err = c ? esp_http_client_perform(c) : ESP_FAIL;
    const int status = c ? esp_http_client_get_status_code(c) : 0;
    if (c) {
        esp_http_client_cleanup(c);
    }
    const bool ok = err == ESP_OK && status == 200 && !d.failed && d.offset == s_size;
    if (!ok) {
        ESP_LOGW(TAG, "download failed: err=%s status=%d got=%u of %u", esp_err_to_name(err),
                 status, (unsigned)d.offset, (unsigned)s_size);
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
    /* The download host sometimes doesn't answer (a busy CDN address, or one
     * this network drops): try again, a new connection may use another one. */
    bool ok = false;
    for (int attempt = 1; attempt <= DOWNLOAD_TRIES && !ok; attempt++) {
        if (attempt > 1) {
            ESP_LOGI(TAG, "download try %d of %d", attempt, DOWNLOAD_TRIES);
            vTaskDelay(pdMS_TO_TICKS(3000));
            if (pump_control_is_on()) {
                return; /* someone started the pump meanwhile */
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
        save_overnight(s_avail_ver); /* shown once after the restart */
    }
    const uint8_t r = pump_ota_finish(PUMP_API_LOCAL_ID);
    gatt_svr_notify_ota_status();
    if (r != TANKLINK_OTA_ERR_OK) {
        ESP_LOGW(TAG, "image refused (hash or signature), err=%u", r);
        save_overnight(NULL);
    }
}

/* ---------------------------------------------------------------------------
 * Job task
 * ------------------------------------------------------------------------- */

static void job_task(void *arg)
{
    const job_t job = (job_t)(uintptr_t)arg;
    changed();
    if (job == JOB_CHECK) {
        do_check();
        s_next_check_us = esp_timer_get_time() + CHECK_EVERY_US;
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
        memcpy(out, s_avail_ver, 3);
    } else {
        memset(out, 0, 3);
    }
}

void pump_update_overnight_version(uint8_t out[3])
{
    memcpy(out, s_overnight, 3);
}

void pump_update_dismiss_overnight(void)
{
    memset(s_overnight, 0, sizeof(s_overnight));
    save_overnight(NULL);
}

void pump_update_init(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    uint8_t v[3];
    size_t n = sizeof(v);
    const bool have = nvs_get_blob(h, NVS_KEY_OVERNIGHT, v, &n) == ESP_OK && n == 3;
    nvs_close(h);
    if (!have) {
        return;
    }
    if (v[0] == TANKLINK_FW_MAJOR && v[1] == TANKLINK_FW_MINOR && v[2] == TANKLINK_FW_PATCH) {
        memcpy(s_overnight, v, 3); /* it really did update: tell the app once */
    } else {
        save_overnight(NULL); /* the install never completed */
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
    const uint8_t slot = pump_tanks_active();
    if (pump_tanks_auto_fill_on(slot) && lora_link_active_tank_low()) {
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
        /* A random minute, so pumps don't all ask at once. */
        s_next_check_us = t + (int64_t)(FIRST_CHECK_MIN_S + esp_random() % FIRST_CHECK_SPAN_S) *
                                  1000000;
    }
    if (t >= s_next_check_us) {
        if (start_job(JOB_CHECK) != ESP_OK) {
            s_next_check_us = t + 60LL * 1000000; /* try again soon */
        }
        return;
    }
    if (auto_install_ok(t)) {
        s_next_auto_try_us = t + AUTO_RETRY_US;
        ESP_LOGI(TAG, "installing %u.%u.%u automatically (pump idle, no fill planned)",
                 s_avail_ver[0], s_avail_ver[1], s_avail_ver[2]);
        start_job(JOB_INSTALL_AUTO);
    }
}
