/*
 * Experimental tank firmware update over LoRa, pump side. See lora_ota.h and
 * tanklink_lora_ota.h for the protocol.
 */
#include "lora_ota.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "gatt_svr.h"
#include "lora_link.h"
#include "pump_control.h"
#include "relay_control.h"
#include "sx1278.h"
#include "tanklink_crypto.h"
#include "tanklink_lora_ota.h"

#define TAG "LORA_OTA"

#define MAX_CHUNKS ((TL_OTA_MAX_SIZE + TL_OTA_CHUNK - 1) / TL_OTA_CHUNK)
#define OFFER_TRIES 15
#define OFFER_WAIT_MS 2500 /* the tank erases about 3 s of flash first */
#define POLL_TRIES 4
#define WINDOW_MISSES 3    /* windows with no answer before giving up / slowing down */
#define DONE_TRIES 6
#define DONE_WAIT_MS 4000  /* the tank hashes and checks the whole image */
#define TANK_REVERT_MS 11000 /* the tank goes back to 125 kHz after 10 s quiet */

static volatile uint8_t s_state = LORA_OTA_ST_IDLE;
static volatile uint8_t s_error;
static volatile bool s_cancel;
static uint8_t s_node;
static const esp_partition_t *s_part;
static uint32_t s_size;
static uint16_t s_chunks;
static uint8_t s_sha[32];
static bool s_fast = true;
static bool s_fast_now;
static uint16_t s_done_chunks;
static uint32_t s_session;
static uint8_t s_key[TL_KEY_LEN];
static uint8_t s_mac[TANKLINK_LORA_TANK_ID_LEN];
static uint8_t s_acked[(MAX_CHUNKS + 7) / 8];

static void notify(void)
{
    gatt_svr_notify_tank_ota();
}

static void set_state(uint8_t st, uint8_t err)
{
    s_state = st;
    s_error = err;
    notify();
}

bool lora_ota_busy(void)
{
    const uint8_t st = s_state;
    return st >= LORA_OTA_ST_WAITING && st <= LORA_OTA_ST_FINISHING;
}

bool lora_ota_waiting_for(uint8_t node)
{
    return s_state == LORA_OTA_ST_WAITING && s_node == node;
}

static esp_err_t arm(bool fast)
{
    if (pump_control_is_on()) {
        set_state(LORA_OTA_ST_FAILED, LORA_OTA_ERR_PUMP_ON);
        return ESP_ERR_INVALID_STATE;
    }
    s_fast = fast;
    s_cancel = false;
    s_done_chunks = 0;
    memset(s_acked, 0, sizeof(s_acked));
    relay_control_set_blocked(true); /* the radio will be busy: no fills */
    set_state(LORA_OTA_ST_WAITING, LORA_OTA_ERR_NONE);
    ESP_LOGI(TAG, "waiting for sensor %u to wake (%lu bytes, %u chunks, %s)", s_node,
             (unsigned long)s_size, s_chunks, fast ? "fast" : "slow");
    return ESP_OK;
}

esp_err_t lora_ota_begin(uint8_t node, const esp_partition_t *part, uint32_t size,
                         const uint8_t sha256[32])
{
    if (lora_ota_busy() || !part || size == 0 || size > TL_OTA_MAX_SIZE) {
        return ESP_ERR_INVALID_STATE;
    }
    s_node = node;
    s_part = part;
    s_size = size;
    s_chunks = (uint16_t)((size + TL_OTA_CHUNK - 1) / TL_OTA_CHUNK);
    memcpy(s_sha, sha256, 32);
    return arm(true);
}

esp_err_t lora_ota_retry(bool fast)
{
    if (lora_ota_busy() || !s_part || s_size == 0) {
        return ESP_ERR_INVALID_STATE;
    }
    return arm(fast);
}

void lora_ota_cancel(void)
{
    if (s_state == LORA_OTA_ST_WAITING) {
        relay_control_set_blocked(false);
        set_state(LORA_OTA_ST_FAILED, LORA_OTA_ERR_CANCELLED);
    } else if (lora_ota_busy()) {
        s_cancel = true; /* the transfer loop stops at the next step */
    }
}

size_t lora_ota_status(uint8_t out[LORA_OTA_STATUS_LEN])
{
    out[0] = s_state;
    out[1] = s_node;
    out[2] = s_error;
    out[3] = s_fast_now ? 1 : 0;
    out[4] = (uint8_t)(s_done_chunks & 0xFF);
    out[5] = (uint8_t)(s_done_chunks >> 8);
    out[6] = (uint8_t)(s_chunks & 0xFF);
    out[7] = (uint8_t)(s_chunks >> 8);
    return LORA_OTA_STATUS_LEN;
}

/* ---- radio helpers ---- */

static bool acked(uint16_t i)
{
    return (s_acked[i >> 3] >> (i & 7)) & 1;
}

static void mark(uint16_t i)
{
    if (i < s_chunks && !acked(i)) {
        s_acked[i >> 3] |= (uint8_t)(1u << (i & 7));
        s_done_chunks++;
    }
}

static void set_speed(bool fast)
{
    s_fast_now = fast;
    (void)sx1278_set_bandwidth_khz(fast ? 500 : 125);
    (void)sx1278_start_rx();
}

static void send_sealed(uint8_t *buf, size_t body_len)
{
    const size_t len = tl_lora_seal(s_key, buf, body_len);
    (void)sx1278_send(buf, len, 1500);
    (void)sx1278_start_rx();
}

/**
 * Wait up to [ms] for a tagged packet of [type] from our tank in this session.
 * Returns its length (body plus tag) or 0.
 */
static size_t wait_reply(uint8_t type, uint8_t *buf, size_t cap, uint32_t ms)
{
    const int64_t until = esp_timer_get_time() + (int64_t)ms * 1000;
    while (esp_timer_get_time() < until) {
        size_t n = 0;
        if (sx1278_poll_recv(buf, cap, &n) == ESP_OK && n >= sizeof(tl_ota_hdr_t) + TL_LORA_TAG_LEN) {
            const tl_ota_hdr_t *h = (const tl_ota_hdr_t *)buf;
            if (h->magic0 == TANKLINK_LORA_MAGIC0 && h->magic1 == TANKLINK_LORA_MAGIC1 &&
                h->ver == TANKLINK_LORA_VER && h->type == type && h->session == s_session &&
                memcmp(h->tank_id, s_mac, sizeof(s_mac)) == 0 && tl_lora_verify(s_key, buf, n)) {
                return n;
            }
        }
        /* At least one tick (10 ms at 100 Hz): a zero-tick delay never lets
         * the idle task run and trips the task watchdog. */
        vTaskDelay(1);
    }
    return 0;
}

/* OFFER at 125 kHz until the tank answers. Returns TL_OTA_* or -1 for no answer. */
static int offer(void)
{
    tl_ota_offer_t o;
    uint8_t buf[sizeof(o) + TL_LORA_TAG_LEN];
    tl_ota_hdr_fill(&o.h, TANKLINK_LORA_TYPE_OTA_OFFER, s_mac, s_session);
    o.size = s_size;
    o.chunks = s_chunks;
    o.fast = s_fast ? 1 : 0;
    memcpy(o.sha256, s_sha, 32);
    for (int t = 0; t < OFFER_TRIES && !s_cancel; t++) {
        memcpy(buf, &o, sizeof(o));
        send_sealed(buf, sizeof(o));
        uint8_t rx[64];
        if (wait_reply(TANKLINK_LORA_TYPE_OTA_OFFER_ACK, rx, sizeof(rx), OFFER_WAIT_MS)) {
            return ((const tl_ota_status_t *)rx)->status;
        }
    }
    return -1;
}

static void send_chunk(uint16_t index)
{
    tl_ota_data_t d;
    uint8_t buf[sizeof(d) + TL_LORA_TAG_LEN];
    tl_ota_hdr_fill(&d.h, TANKLINK_LORA_TYPE_OTA_DATA, s_mac, s_session);
    d.index = index;
    const uint32_t off = (uint32_t)index * TL_OTA_CHUNK;
    const uint32_t len = s_size - off < TL_OTA_CHUNK ? s_size - off : TL_OTA_CHUNK;
    if (esp_partition_read(s_part, off, d.data, len) != ESP_OK) {
        return;
    }
    const size_t body = offsetof(tl_ota_data_t, data) + len;
    memcpy(buf, &d, body);
    send_sealed(buf, body);
}

/* POLL the window at [base]; true with the tank's bits marked. */
static bool poll_window(uint16_t base)
{
    tl_ota_poll_t p;
    uint8_t buf[sizeof(p) + TL_LORA_TAG_LEN];
    tl_ota_hdr_fill(&p.h, TANKLINK_LORA_TYPE_OTA_POLL, s_mac, s_session);
    p.base = base;
    const uint32_t wait_ms = s_fast_now ? 250 : 700;
    for (int t = 0; t < POLL_TRIES && !s_cancel; t++) {
        memcpy(buf, &p, sizeof(p));
        send_sealed(buf, sizeof(p));
        uint8_t rx[64];
        if (wait_reply(TANKLINK_LORA_TYPE_OTA_WIN_ACK, rx, sizeof(rx), wait_ms)) {
            const tl_ota_win_ack_t *a = (const tl_ota_win_ack_t *)rx;
            if (a->base == base) {
                for (int i = 0; i < TL_OTA_WINDOW; i++) {
                    if ((a->bits >> i) & 1) {
                        mark((uint16_t)(base + i));
                    }
                }
                return true;
            }
        }
    }
    return false;
}

static bool window_done(uint16_t base)
{
    for (int i = 0; i < TL_OTA_WINDOW && base + i < s_chunks; i++) {
        if (!acked((uint16_t)(base + i))) {
            return false;
        }
    }
    return true;
}

static uint8_t finish(void)
{
    tl_ota_hdr_t d;
    uint8_t buf[sizeof(d) + TL_LORA_TAG_LEN];
    tl_ota_hdr_fill(&d, TANKLINK_LORA_TYPE_OTA_DONE, s_mac, s_session);
    for (int t = 0; t < DONE_TRIES && !s_cancel; t++) {
        memcpy(buf, &d, sizeof(d));
        send_sealed(buf, sizeof(d));
        uint8_t rx[64];
        if (wait_reply(TANKLINK_LORA_TYPE_OTA_DONE_ACK, rx, sizeof(rx), DONE_WAIT_MS)) {
            switch (((const tl_ota_status_t *)rx)->status) {
            case TL_OTA_OK: return LORA_OTA_ERR_NONE;
            case TL_OTA_ERR_MISSING: return LORA_OTA_ERR_MISSING;
            default: return LORA_OTA_ERR_IMAGE;
            }
        }
    }
    return s_cancel ? LORA_OTA_ERR_CANCELLED : LORA_OTA_ERR_NO_RESULT;
}

/* ---- the transfer ---- */

static uint8_t transfer(void)
{
    if (!lora_link_node_secrets(s_node, s_key, s_mac)) {
        return LORA_OTA_ERR_NO_KEY;
    }
    esp_fill_random(&s_session, sizeof(s_session));
    set_state(LORA_OTA_ST_OFFERING, LORA_OTA_ERR_NONE);
    int st = offer();
    if (st < 0) {
        return s_cancel ? LORA_OTA_ERR_CANCELLED : LORA_OTA_ERR_NO_ANSWER;
    }
    if (st != TL_OTA_OK) {
        return LORA_OTA_ERR_REFUSED;
    }
    set_speed(s_fast);
    set_state(LORA_OTA_ST_SENDING, LORA_OTA_ERR_NONE);
    const int64_t t0 = esp_timer_get_time();
    int misses = 0;
    for (uint16_t base = 0; base < s_chunks;) {
        if (s_cancel) {
            return LORA_OTA_ERR_CANCELLED;
        }
        for (int i = 0; i < TL_OTA_WINDOW && base + i < s_chunks; i++) {
            if (!acked((uint16_t)(base + i))) {
                send_chunk((uint16_t)(base + i));
            }
        }
        if (poll_window(base)) {
            misses = 0;
            if (window_done(base)) {
                base += TL_OTA_WINDOW;
                notify();
            }
            continue;
        }
        if (++misses < WINDOW_MISSES) {
            continue;
        }
        if (!s_fast_now) {
            return LORA_OTA_ERR_LOST;
        }
        /* Fast mode lost the tank: let it fall back, then carry on at 125 kHz
         * in the same session (it keeps what it already has). */
        ESP_LOGW(TAG, "no answer at 500 kHz; going on at 125 kHz");
        set_speed(false);
        vTaskDelay(pdMS_TO_TICKS(TANK_REVERT_MS));
        st = offer();
        if (st != TL_OTA_OK) {
            return st < 0 ? LORA_OTA_ERR_LOST : LORA_OTA_ERR_REFUSED;
        }
        misses = 0;
    }
    ESP_LOGI(TAG, "all %u chunks sent in %llds (%s)", s_chunks,
             (long long)((esp_timer_get_time() - t0) / 1000000), s_fast_now ? "fast" : "slow");
    /* DONE at 125 kHz: the tank answers at the speed it hears, and falls
     * back to 125 kHz itself after 10 s quiet, well inside DONE's retries. */
    set_speed(false);
    set_state(LORA_OTA_ST_FINISHING, LORA_OTA_ERR_NONE);
    return finish();
}

void lora_ota_run(void)
{
    if (s_state != LORA_OTA_ST_WAITING) {
        return;
    }
    const uint8_t err = transfer();
    set_speed(false);
    relay_control_set_blocked(false);
    if (err == LORA_OTA_ERR_NONE) {
        ESP_LOGI(TAG, "sensor %u updated; it is restarting", s_node);
        set_state(LORA_OTA_ST_DONE, LORA_OTA_ERR_NONE);
    } else {
        ESP_LOGW(TAG, "sensor %u update failed: %u (%u of %u chunks)", s_node, err,
                 s_done_chunks, s_chunks);
        set_state(LORA_OTA_ST_FAILED, err);
    }
}
