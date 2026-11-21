#include "pump_alert.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

#include "gatt_svr.h"
#include "pump_pair.h"
#include "pump_tanks.h"
#include "tanklink_crypto.h"

#define TAG "ALERT"
#define NVS_NS "tl_alert"
#define NVS_KEY_KEY "key"
#define NVS_KEY_SEQ "seq"

#define HOLD_US (3600LL * 1000000)    /* in the advertisement for an hour */
#define TEST_HOLD_US (120LL * 1000000) /* a test only needs two minutes */
#define BATTERY_LOW_PCT 20
#define BATTERY_OK_PCT 30
#define BATTERY_REPEAT_US (24LL * 3600 * 1000000)

typedef struct {
    uint8_t seq;
    uint8_t type;
    uint8_t arg;
    uint8_t tag[TANKLINK_ALERT_TAG_LEN];
    int64_t raised_us;
    int64_t hold_us;
} alert_t;

static SemaphoreHandle_t s_lock;
static uint8_t s_key[16];
static bool s_have_key;
static uint8_t s_seq;
static alert_t s_current;
static bool s_current_valid;
static alert_t s_log[PUMP_ALERT_LOG_MAX]; /* newest first */
static int s_log_n;
static void (*s_change_cb)(void);

/* Per sensor: low already raised, and when. */
static struct {
    bool low;
    int64_t raised_us;
} s_bat[PUMP_NODE_MAX];

static void save_seq(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    nvs_set_u8(h, NVS_KEY_SEQ, s_seq);
    nvs_commit(h);
    nvs_close(h);
}

static void save_key(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    if (s_have_key) {
        nvs_set_blob(h, NVS_KEY_KEY, s_key, sizeof(s_key));
    } else {
        nvs_erase_key(h, NVS_KEY_KEY);
    }
    nvs_commit(h);
    nvs_close(h);
}

static void changed(void)
{
    gatt_svr_notify_alerts();
    if (s_change_cb) {
        s_change_cb();
    }
}

/** First 4 bytes of HMAC-SHA256(key, device_id || seq || type || arg). */
static void make_tag(uint8_t seq, uint8_t type, uint8_t arg, uint8_t out[TANKLINK_ALERT_TAG_LEN])
{
    const uint8_t tail[3] = {seq, type, arg};
    uint8_t mac[32];
    tl_hmac_sha256(s_key, sizeof(s_key), pump_pair_device_id(), TANKLINK_DEVICE_ID_LEN, tail,
                   sizeof(tail), mac);
    memcpy(out, mac, TANKLINK_ALERT_TAG_LEN);
}

void pump_alert_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t n = sizeof(s_key);
        s_have_key = nvs_get_blob(h, NVS_KEY_KEY, s_key, &n) == ESP_OK && n == sizeof(s_key) &&
                     tl_nonzero(s_key, sizeof(s_key));
        nvs_get_u8(h, NVS_KEY_SEQ, &s_seq);
        nvs_close(h);
    }
    /* A pump that already has phones but no key yet (just updated) makes one now. */
    if (!s_have_key && pump_pair_is_paired()) {
        pump_alert_phone_added();
    }
    ESP_LOGI(TAG, "alerts %s, seq %u", s_have_key ? "on" : "waiting for a phone", s_seq);
}

bool pump_alert_key(uint8_t out[16])
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool ok = s_have_key;
    if (ok) {
        memcpy(out, s_key, sizeof(s_key));
    }
    xSemaphoreGive(s_lock);
    return ok;
}

void pump_alert_phone_added(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_have_key) {
        do {
            esp_fill_random(s_key, sizeof(s_key));
        } while (!tl_nonzero(s_key, sizeof(s_key)));
        s_have_key = true;
        save_key();
        ESP_LOGI(TAG, "alert key made");
    }
    xSemaphoreGive(s_lock);
}

void pump_alert_phones_removed(bool some_remain)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_current_valid = false;
    s_log_n = 0;
    memset(s_bat, 0, sizeof(s_bat));
    if (some_remain) {
        do {
            esp_fill_random(s_key, sizeof(s_key));
        } while (!tl_nonzero(s_key, sizeof(s_key)));
        s_have_key = true;
    } else {
        memset(s_key, 0, sizeof(s_key));
        s_have_key = false;
    }
    save_key();
    xSemaphoreGive(s_lock);
    changed();
}

void pump_alert_raise(tl_alert_type_t type, uint8_t arg)
{
    if (!s_lock) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_have_key) {
        xSemaphoreGive(s_lock);
        return;
    }
    s_seq = (uint8_t)(s_seq == 255 ? 1 : s_seq + 1); /* 0 means "none" */
    save_seq();
    alert_t a = {.seq = s_seq, .type = (uint8_t)type, .arg = arg};
    make_tag(a.seq, a.type, a.arg, a.tag);
    a.raised_us = esp_timer_get_time();
    a.hold_us = type == TL_ALERT_TEST ? TEST_HOLD_US : HOLD_US;
    s_current = a;
    s_current_valid = true;
    memmove(&s_log[1], &s_log[0], (PUMP_ALERT_LOG_MAX - 1) * sizeof(s_log[0]));
    s_log[0] = a;
    if (s_log_n < PUMP_ALERT_LOG_MAX) {
        s_log_n++;
    }
    ESP_LOGI(TAG, "alert %u: type %u arg %u", a.seq, a.type, a.arg);
    xSemaphoreGive(s_lock);
    changed();
}

void pump_alert_note_battery(uint8_t sensor, uint8_t pct)
{
    if (sensor >= PUMP_NODE_MAX || pct == 0) {
        return;
    }
    const int64_t now = esp_timer_get_time();
    bool raise = false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (pct <= BATTERY_LOW_PCT &&
        (!s_bat[sensor].low || now - s_bat[sensor].raised_us >= BATTERY_REPEAT_US)) {
        s_bat[sensor].low = true;
        s_bat[sensor].raised_us = now;
        raise = true;
    } else if (pct > BATTERY_OK_PCT) {
        s_bat[sensor].low = false;
    }
    xSemaphoreGive(s_lock);
    if (raise) {
        pump_alert_raise(TL_ALERT_BATTERY_LOW, sensor);
    }
}

void pump_alert_poll(void)
{
    if (!s_lock || !s_current_valid) {
        return;
    }
    bool ended = false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_current_valid && esp_timer_get_time() - s_current.raised_us >= s_current.hold_us) {
        s_current_valid = false;
        ended = true;
    }
    xSemaphoreGive(s_lock);
    if (ended) {
        ESP_LOGI(TAG, "alert out of the advertisement");
        if (s_change_cb) {
            s_change_cb();
        }
    }
}

bool pump_alert_adv_bytes(uint8_t out[7])
{
    memset(out, 0, 7);
    if (!s_lock) {
        return false;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool ok = s_have_key && s_current_valid;
    if (ok) {
        out[0] = s_current.seq;
        out[1] = s_current.type;
        out[2] = s_current.arg;
        memcpy(&out[3], s_current.tag, TANKLINK_ALERT_TAG_LEN);
    }
    xSemaphoreGive(s_lock);
    return ok;
}

size_t pump_alert_log_payload(uint8_t *out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const int64_t now = esp_timer_get_time();
    out[0] = (uint8_t)s_log_n;
    size_t at = 1;
    for (int i = 0; i < s_log_n; i++) {
        int64_t age_min = (now - s_log[i].raised_us) / 60000000LL;
        if (age_min > 0xFFFE) {
            age_min = 0xFFFE;
        }
        out[at++] = s_log[i].seq;
        out[at++] = s_log[i].type;
        out[at++] = s_log[i].arg;
        out[at++] = (uint8_t)(age_min & 0xff);
        out[at++] = (uint8_t)(age_min >> 8);
    }
    xSemaphoreGive(s_lock);
    return at;
}

void pump_alert_set_change_callback(void (*cb)(void))
{
    s_change_cb = cb;
}
