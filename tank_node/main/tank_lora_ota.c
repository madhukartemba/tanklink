/*
 * Experimental: receive a firmware update from the pump over LoRa. The pump
 * asks for it in the ACK to a STATUS (TANKLINK_LORA_FLAG_OTA_PENDING); the
 * protocol is in tanklink_lora_ota.h.
 *
 * Chunks are written straight into the spare slot at their offset, in any
 * order. At the end the tank checks the sha256 of what arrived against the
 * offer, then esp_ota_end checks the image and its signature, and only then
 * does it boot it.
 */
#include "tank_lora_ota.h"

#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sx1278.h"
#include "tank_ble_token.h"
#include "tank_led.h"
#include "tank_link.h"
#include "tanklink_crypto.h"
#include "tanklink_lora_ota.h"
#include "tinycrypt/sha256.h"

#define TAG "LORA_OTA"
#define IDLE_GIVE_UP_MS 60000 /* no offer at all: back to sleep */
#define QUIET_REVERT_MS 10000 /* at 500 kHz with no traffic: back to 125 kHz */
#define QUIET_GIVE_UP_MS 90000 /* during an update with no traffic: give up */

typedef struct {
    uint32_t session;
    uint32_t size;
    uint16_t chunks;
    uint16_t have;
    bool fast_asked;
    bool fast_now;
    uint8_t sha[32];
    uint8_t *bits;
    esp_ota_handle_t handle;
    const esp_partition_t *part;
    bool begun;
    bool done;
    uint8_t result; /* DONE_ACK status once checked */
} rx_t;

static bool have(const rx_t *r, uint16_t i)
{
    return (r->bits[i >> 3] >> (i & 7)) & 1;
}

static void send_sealed(uint8_t *buf, size_t body_len)
{
    const size_t len = tl_lora_seal(tank_link_key(), buf, body_len);
    (void)sx1278_send(buf, len, 1500);
    (void)sx1278_start_rx();
}

static void reply_status(const rx_t *r, uint8_t type, uint8_t status)
{
    tl_ota_status_t s;
    uint8_t buf[sizeof(s) + TL_LORA_TAG_LEN];
    tl_ota_hdr_fill(&s.h, type, tank_link_tank_id(), r->session);
    s.status = status;
    memcpy(buf, &s, sizeof(s));
    send_sealed(buf, sizeof(s));
}

static void set_speed(rx_t *r, bool fast)
{
    r->fast_now = fast;
    (void)sx1278_set_bandwidth_khz(fast ? 500 : 125);
    (void)sx1278_start_rx();
}

static void abort_update(rx_t *r)
{
    if (r->begun) {
        esp_ota_abort(r->handle);
        r->begun = false;
    }
    free(r->bits);
    r->bits = NULL;
}

/* A new offer: erase the spare slot. Same session again: just answer. */
static void on_offer(rx_t *r, const tl_ota_offer_t *o)
{
    if (r->begun && o->h.session == r->session) {
        reply_status(r, TANKLINK_LORA_TYPE_OTA_OFFER_ACK, TL_OTA_OK);
        if (r->fast_asked) {
            set_speed(r, true);
        }
        return;
    }
    abort_update(r);
    r->session = o->h.session;
    r->size = o->size;
    r->chunks = o->chunks;
    r->have = 0;
    r->done = false;
    r->fast_asked = o->fast != 0;
    memcpy(r->sha, o->sha256, 32);
    r->part = esp_ota_get_next_update_partition(NULL);
    const uint32_t want_chunks = (o->size + TL_OTA_CHUNK - 1) / TL_OTA_CHUNK;
    if (!r->part || o->size == 0 || o->size > r->part->size || o->chunks != want_chunks) {
        reply_status(r, TANKLINK_LORA_TYPE_OTA_OFFER_ACK, TL_OTA_ERR_SIZE);
        return;
    }
    r->bits = calloc((o->chunks + 7) / 8, 1);
    ESP_LOGI(TAG, "offer: %lu bytes, %u chunks, %s; erasing", (unsigned long)o->size,
             o->chunks, r->fast_asked ? "fast" : "slow");
    /* esp_ota_begin erases what the image needs (a few seconds). */
    if (!r->bits || esp_ota_begin(r->part, o->size, &r->handle) != ESP_OK) {
        free(r->bits);
        r->bits = NULL;
        reply_status(r, TANKLINK_LORA_TYPE_OTA_OFFER_ACK, TL_OTA_ERR_FLASH);
        return;
    }
    r->begun = true;
    reply_status(r, TANKLINK_LORA_TYPE_OTA_OFFER_ACK, TL_OTA_OK);
    if (r->fast_asked) {
        set_speed(r, true);
    }
}

static void on_data(rx_t *r, const tl_ota_data_t *d, size_t body_len)
{
    if (!r->begun || r->done || d->index >= r->chunks || have(r, d->index)) {
        return;
    }
    const uint32_t off = (uint32_t)d->index * TL_OTA_CHUNK;
    const uint32_t want = r->size - off < TL_OTA_CHUNK ? r->size - off : TL_OTA_CHUNK;
    if (body_len != offsetof(tl_ota_data_t, data) + want) {
        return;
    }
    if (esp_ota_write_with_offset(r->handle, d->data, want, off) == ESP_OK) {
        r->bits[d->index >> 3] |= (uint8_t)(1u << (d->index & 7));
        r->have++;
    }
}

static void on_poll(rx_t *r, const tl_ota_poll_t *p)
{
    if (!r->begun) {
        return;
    }
    tl_ota_win_ack_t a;
    uint8_t buf[sizeof(a) + TL_LORA_TAG_LEN];
    tl_ota_hdr_fill(&a.h, TANKLINK_LORA_TYPE_OTA_WIN_ACK, tank_link_tank_id(), r->session);
    a.base = p->base;
    a.bits = 0;
    for (int i = 0; i < TL_OTA_WINDOW; i++) {
        const uint32_t idx = (uint32_t)p->base + i;
        if (idx >= r->chunks || have(r, (uint16_t)idx)) {
            a.bits |= (uint16_t)(1u << i);
        }
    }
    memcpy(buf, &a, sizeof(a));
    send_sealed(buf, sizeof(a));
}

/* sha256 of the first [size] bytes of the slot, as written. */
static bool hash_matches(const rx_t *r)
{
    struct tc_sha256_state_struct st;
    (void)tc_sha256_init(&st);
    uint8_t buf[1024];
    for (uint32_t off = 0; off < r->size; off += sizeof(buf)) {
        const uint32_t n = r->size - off < sizeof(buf) ? r->size - off : sizeof(buf);
        if (esp_partition_read(r->part, off, buf, n) != ESP_OK) {
            return false;
        }
        (void)tc_sha256_update(&st, buf, n);
    }
    uint8_t got[32];
    (void)tc_sha256_final(got, &st);
    return memcmp(got, r->sha, 32) == 0;
}

static uint8_t check(rx_t *r)
{
    if (r->have != r->chunks) {
        return TL_OTA_ERR_MISSING;
    }
    if (!hash_matches(r)) {
        abort_update(r);
        return TL_OTA_ERR_HASH;
    }
    /* Checks the image and, with signed apps, its signature. */
    const esp_err_t err = esp_ota_end(r->handle);
    r->begun = false;
    if (err != ESP_OK || esp_ota_set_boot_partition(r->part) != ESP_OK) {
        ESP_LOGE(TAG, "image refused: %s", esp_err_to_name(err));
        return TL_OTA_ERR_IMAGE;
    }
    return TL_OTA_OK;
}

static void on_done(rx_t *r)
{
    if (!r->done) {
        r->done = true;
        set_speed(r, false); /* the pump goes back to 125 kHz for DONE too */
        r->result = r->begun || r->have == r->chunks ? check(r) : TL_OTA_ERR_MISSING;
        ESP_LOGI(TAG, "update %s (%u)", r->result == TL_OTA_OK ? "OK" : "failed", r->result);
        if (r->result == TL_OTA_ERR_MISSING) {
            r->done = false; /* the pump may send the rest */
        }
    }
    /* Answer every DONE: the pump may not have heard the first answer. */
    for (int i = 0; i < 2; i++) {
        reply_status(r, TANKLINK_LORA_TYPE_OTA_DONE_ACK, r->result);
    }
}

void tank_lora_ota_run(void)
{
    rx_t r;
    memset(&r, 0, sizeof(r));
    ESP_LOGI(TAG, "pump has an update; staying awake");
    tank_led_ota_pulse_start();
    (void)sx1278_start_rx();
    int64_t last = esp_timer_get_time();
    uint8_t buf[256];
    for (;;) {
        const int64_t quiet_ms = (esp_timer_get_time() - last) / 1000;
        if (!r.begun && quiet_ms > IDLE_GIVE_UP_MS) {
            ESP_LOGW(TAG, "no offer; back to sleep");
            break;
        }
        if (r.begun && quiet_ms > QUIET_GIVE_UP_MS) {
            ESP_LOGW(TAG, "pump went quiet at %u of %u chunks", r.have, r.chunks);
            break;
        }
        if (r.fast_now && quiet_ms > QUIET_REVERT_MS) {
            ESP_LOGW(TAG, "quiet at 500 kHz; listening at 125 kHz");
            set_speed(&r, false);
        }
        size_t n = 0;
        if (sx1278_poll_recv(buf, sizeof(buf), &n) != ESP_OK ||
            n < sizeof(tl_ota_hdr_t) + TL_LORA_TAG_LEN) {
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }
        const tl_ota_hdr_t *h = (const tl_ota_hdr_t *)buf;
        if (h->magic0 != TANKLINK_LORA_MAGIC0 || h->magic1 != TANKLINK_LORA_MAGIC1 ||
            h->ver != TANKLINK_LORA_VER ||
            memcmp(h->tank_id, tank_link_tank_id(), TANKLINK_LORA_TANK_ID_LEN) != 0 ||
            !tl_lora_verify(tank_link_key(), buf, n)) {
            continue;
        }
        const size_t body = n - TL_LORA_TAG_LEN;
        if (h->type == TANKLINK_LORA_TYPE_OTA_OFFER && body >= sizeof(tl_ota_offer_t)) {
            last = esp_timer_get_time();
            on_offer(&r, (const tl_ota_offer_t *)buf);
            continue;
        }
        if (!r.begun && !r.done) {
            continue; /* everything else needs an offer first */
        }
        if (h->session != r.session) {
            continue;
        }
        last = esp_timer_get_time();
        if (h->type == TANKLINK_LORA_TYPE_OTA_DATA && body > offsetof(tl_ota_data_t, data)) {
            on_data(&r, (const tl_ota_data_t *)buf, body);
        } else if (h->type == TANKLINK_LORA_TYPE_OTA_POLL && body >= sizeof(tl_ota_poll_t)) {
            on_poll(&r, (const tl_ota_poll_t *)buf);
        } else if (h->type == TANKLINK_LORA_TYPE_OTA_DONE) {
            on_done(&r);
            if (r.result == TL_OTA_OK && r.done) {
                tank_led_ota_pulse_stop();
                tank_led_success();
                ESP_LOGI(TAG, "booting the new firmware");
                vTaskDelay(pdMS_TO_TICKS(300));
                esp_restart();
            }
            if (r.done) {
                break; /* checked and refused: nothing more to do */
            }
        }
    }
    abort_update(&r);
    (void)sx1278_set_bandwidth_khz(125);
    tank_led_ota_pulse_stop();
    tank_led_show_error(3);
}
