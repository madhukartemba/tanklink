#include "pump_wifi_api.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#include "pump_api.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_wifi.h"
#include "tanklink_crypto.h"

#define TAG "WIFI_API"

/* length(2) hdr(6) payload tag(8); the longest payload is an OTA chunk write. */
#define MAX_FRAME_LEN (PUMP_WIFI_API_HDR_LEN + PUMP_API_WRITE_MAX + PUMP_WIFI_API_TAG_LEN)
/* A client's receive buffer starts small (every command, read and setting fits)
 * and grows to MAX_FRAME_LEN only for the frame that needs it (an OTA chunk),
 * then shrinks again: three clients would otherwise hold 3 x 2 KB for nothing. */
#define RX_SMALL 512
/* The longest frame the pump sends: a read result, status byte plus value. */
#define TX_BUF_LEN (2 + PUMP_WIFI_API_HDR_LEN + 1 + PUMP_API_READ_MAX + PUMP_WIFI_API_TAG_LEN)

typedef struct {
    int fd; /* -1 = free */
    pump_api_session_t api;
    uint8_t key[32]; /* session key, once signed in */
    uint32_t rx_counter;
    uint32_t tx_counter;
    uint8_t *rx; /* length field + frame; RX_SMALL + 2 or bigger, see above */
    size_t rx_cap;
    size_t rx_len;
    int64_t connected_ms;
    int64_t last_rx_ms;
} client_t;

static client_t s_clients[PUMP_WIFI_API_MAX_CLIENTS];
static SemaphoreHandle_t s_tx_lock; /* tx buffer, counters and fd writes */
static uint8_t s_tx[TX_BUF_LEN];
static bool s_started;

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000;
}

static void put_u16(uint8_t *o, uint16_t v)
{
    o[0] = (uint8_t)v;
    o[1] = (uint8_t)(v >> 8);
}

static void put_u32(uint8_t *o, uint32_t v)
{
    o[0] = (uint8_t)v;
    o[1] = (uint8_t)(v >> 8);
    o[2] = (uint8_t)(v >> 16);
    o[3] = (uint8_t)(v >> 24);
}

static uint32_t get_u32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
           ((uint32_t)b[3] << 24);
}

static client_t *client_by_id(uint16_t id)
{
    if (id < PUMP_API_TCP_ID_BASE || id >= PUMP_API_TCP_ID_BASE + PUMP_WIFI_API_MAX_CLIENTS) {
        return NULL;
    }
    client_t *c = &s_clients[id - PUMP_API_TCP_ID_BASE];
    return c->fd >= 0 ? c : NULL;
}

/** Tag = HMAC-SHA256(session key, every byte before it), first 8 bytes. */
static void make_tag(const uint8_t key[32], const uint8_t *frame, size_t len, uint8_t *out)
{
    uint8_t mac[32];
    tl_hmac_sha256(key, 32, frame, len, NULL, 0, mac);
    memcpy(out, mac, PUMP_WIFI_API_TAG_LEN);
}

/**
 * Send one frame. Never blocks: a client that can't take it is cut off (a
 * half-written frame would break the framing), and its task notices.
 */
static bool send_frame(client_t *c, uint8_t type, uint8_t chr, const uint8_t *payload,
                       size_t plen, bool tagged)
{
    bool ok = false;
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    if (c->fd >= 0 && 2 + PUMP_WIFI_API_HDR_LEN + plen + PUMP_WIFI_API_TAG_LEN <= TX_BUF_LEN) {
        size_t n = PUMP_WIFI_API_HDR_LEN + plen + (tagged ? PUMP_WIFI_API_TAG_LEN : 0);
        put_u16(s_tx, (uint16_t)n);
        s_tx[2] = type;
        s_tx[3] = chr;
        put_u32(&s_tx[4], ++c->tx_counter);
        if (plen) {
            memcpy(&s_tx[8], payload, plen);
        }
        size_t total = 2 + PUMP_WIFI_API_HDR_LEN + plen;
        if (tagged) {
            make_tag(c->key, s_tx, total, &s_tx[total]);
            total += PUMP_WIFI_API_TAG_LEN;
        }
        const ssize_t w = send(c->fd, s_tx, total, MSG_DONTWAIT);
        ok = w == (ssize_t)total;
        if (!ok) {
            shutdown(c->fd, SHUT_RDWR); /* the client task closes it */
        }
    }
    xSemaphoreGive(s_tx_lock);
    return ok;
}

static void close_client(client_t *c)
{
    pump_ota_on_disconnect(c->api.id);
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    close(c->fd);
    c->fd = -1;
    free(c->rx);
    c->rx = NULL;
    c->rx_cap = 0;
    memset(c->key, 0, sizeof(c->key));
    memset(&c->api, 0, sizeof(c->api));
    xSemaphoreGive(s_tx_lock);
    ESP_LOGI(TAG, "client closed");
}

/** Derive the session key once Auth has passed (the AUTH frame itself is untagged). */
static bool derive_key(client_t *c)
{
    uint8_t token[TANKLINK_TOKEN_LEN];
    if (!pump_pair_phone_token(c->api.phone, token)) {
        return false;
    }
    tl_hmac_sha256(token, sizeof(token), c->api.auth_nonce, sizeof(c->api.auth_nonce),
                   (const uint8_t *)"tcp", 3, c->key);
    memset(token, 0, sizeof(token));
    return true;
}

/** Handle one whole frame. [f] points at the type byte; [n] is the length after the length field. */
static bool handle_frame(client_t *c, const uint8_t *f, size_t n)
{
    const uint8_t type = f[0];
    const uint8_t chr = f[1];
    const uint32_t counter = get_u32(&f[2]);
    const bool signed_in = c->api.authed;

    size_t plen = n - PUMP_WIFI_API_HDR_LEN;
    if (signed_in) {
        if (plen < PUMP_WIFI_API_TAG_LEN) {
            return false;
        }
        uint8_t want[PUMP_WIFI_API_TAG_LEN];
        make_tag(c->key, f - 2, 2 + n - PUMP_WIFI_API_TAG_LEN, want);
        if (!tl_ct_equal(want, &f[n - PUMP_WIFI_API_TAG_LEN], PUMP_WIFI_API_TAG_LEN)) {
            ESP_LOGW(TAG, "bad tag");
            return false;
        }
        plen -= PUMP_WIFI_API_TAG_LEN;
        if (counter <= c->rx_counter) {
            ESP_LOGW(TAG, "counter went back");
            return false;
        }
    }
    c->rx_counter = counter;
    const uint8_t *payload = &f[PUMP_WIFI_API_HDR_LEN];
    static uint8_t out[1 + PUMP_API_READ_MAX]; /* this task only */

    if (!signed_in) {
        /* Before sign-in only AUTH and a read of Info. */
        if (type == PUMP_WIFI_API_AUTH) {
            const pump_api_err_t err = pump_api_write(&c->api, PUMP_API_CHR_AUTH, payload, plen);
            if (err != PUMP_API_OK || !derive_key(c)) {
                send_frame(c, PUMP_WIFI_API_RESULT, PUMP_API_CHR_AUTH, (uint8_t[]){PUMP_API_ERR_NOT_AUTH},
                           1, false);
                return false;
            }
            out[0] = PUMP_API_OK;
            return send_frame(c, PUMP_WIFI_API_RESULT, PUMP_API_CHR_AUTH, out, 1, true);
        }
        if (type == PUMP_WIFI_API_READ && chr == PUMP_API_CHR_INFO) {
            size_t len = 0;
            out[0] = (uint8_t)pump_api_read(&c->api, chr, &out[1], &len);
            return send_frame(c, PUMP_WIFI_API_RESULT, chr, out, 1 + len, false);
        }
        return false;
    }

    switch (type) {
    case PUMP_WIFI_API_READ: {
        size_t len = 0;
        const pump_api_err_t err = pump_api_read(&c->api, chr, &out[1], &len);
        out[0] = (uint8_t)err;
        return send_frame(c, PUMP_WIFI_API_RESULT, chr, out, err == PUMP_API_OK ? 1 + len : 1,
                          true);
    }
    case PUMP_WIFI_API_WRITE: {
        const pump_api_err_t err = pump_api_write(&c->api, chr, payload, plen);
        out[0] = (uint8_t)err;
        /* A signed-out session (unpair) can't tag any more: just close. */
        return c->api.authed && send_frame(c, PUMP_WIFI_API_RESULT, chr, out, 1, true);
    }
    default:
        return false;
    }
}

/** Process every whole frame in the buffer. False = close the client. */
static bool resize_rx(client_t *c, size_t cap)
{
    uint8_t *p = realloc(c->rx, cap);
    if (!p) {
        return false;
    }
    c->rx = p;
    c->rx_cap = cap;
    return true;
}

static bool process_rx(client_t *c)
{
    while (c->rx_len >= 2) {
        const size_t n = (size_t)c->rx[0] | ((size_t)c->rx[1] << 8);
        if (n < PUMP_WIFI_API_HDR_LEN || n > MAX_FRAME_LEN) {
            return false;
        }
        if (c->rx_cap < 2 + n && !resize_rx(c, 2 + n)) {
            ESP_LOGW(TAG, "no memory for a %u byte frame", (unsigned)n);
            return false;
        }
        if (c->rx_len < 2 + n) {
            return true;
        }
        if (!handle_frame(c, &c->rx[2], n)) {
            return false;
        }
        c->rx_len -= 2 + n;
        memmove(c->rx, &c->rx[2 + n], c->rx_len);
    }
    if (c->rx_cap > RX_SMALL + 2 && c->rx_len <= RX_SMALL + 2) {
        resize_rx(c, RX_SMALL + 2); /* shrinking can't fail meaningfully; keep the old one if it does */
    }
    return true;
}

static void accept_client(int listener)
{
    const int fd = accept(listener, NULL, NULL);
    if (fd < 0) {
        return;
    }
    client_t *c = NULL;
    for (int i = 0; i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
        if (s_clients[i].fd < 0) {
            c = &s_clients[i];
            c->api.id = (uint16_t)(PUMP_API_TCP_ID_BASE + i);
            break;
        }
    }
    uint8_t *rx = c ? malloc(RX_SMALL + 2) : NULL;
    if (!c || !rx) {
        close(fd);
        ESP_LOGW(TAG, "refused a client (%s)", c ? "memory" : "full");
        return;
    }
    const int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    const uint16_t id = c->api.id;
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    c->rx = rx;
    c->rx_cap = RX_SMALL + 2;
    c->rx_len = 0;
    c->rx_counter = 0;
    c->tx_counter = 0;
    c->connected_ms = c->last_rx_ms = now_ms();
    pump_api_session_init(&c->api, id);
    c->fd = fd;
    xSemaphoreGive(s_tx_lock);

    /* HELLO: this connection's nonce, then the Info payload. */
    uint8_t hello[TL_NONCE_LEN + PUMP_API_READ_MAX];
    size_t len = 0;
    memcpy(hello, c->api.nonce, TL_NONCE_LEN);
    pump_api_read(&c->api, PUMP_API_CHR_INFO, &hello[TL_NONCE_LEN], &len);
    send_frame(c, PUMP_WIFI_API_HELLO, 0, hello, TL_NONCE_LEN + len, false);
    ESP_LOGI(TAG, "client %u connected", id);
}

static void server_task(void *arg)
{
    (void)arg;
    const int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(PUMP_API_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    const int one = 1;
    if (listener < 0 || setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0 ||
        bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listener, PUMP_WIFI_API_MAX_CLIENTS) != 0) {
        ESP_LOGE(TAG, "listen failed errno=%d", errno);
        s_started = false;
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "listening on port %d", PUMP_API_PORT);

    while (1) {
        fd_set rd;
        FD_ZERO(&rd);
        FD_SET(listener, &rd);
        int maxfd = listener;
        for (int i = 0; i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
            if (s_clients[i].fd >= 0) {
                FD_SET(s_clients[i].fd, &rd);
                maxfd = s_clients[i].fd > maxfd ? s_clients[i].fd : maxfd;
            }
        }
        struct timeval tv = {.tv_sec = 1};
        if (select(maxfd + 1, &rd, NULL, NULL, &tv) < 0) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        if (FD_ISSET(listener, &rd)) {
            accept_client(listener);
        }
        const int64_t t = now_ms();
        for (int i = 0; i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
            client_t *c = &s_clients[i];
            if (c->fd < 0) {
                continue;
            }
            bool keep = true;
            if (FD_ISSET(c->fd, &rd)) {
                const ssize_t r = recv(c->fd, c->rx + c->rx_len, c->rx_cap - c->rx_len, 0);
                if (r <= 0) {
                    keep = false;
                } else {
                    c->rx_len += (size_t)r;
                    c->last_rx_ms = t;
                    keep = process_rx(c);
                }
            }
            if (keep) {
                const int64_t limit = c->api.authed ? PUMP_WIFI_API_IDLE_MS : PUMP_WIFI_API_AUTH_MS;
                keep = t - c->last_rx_ms < limit;
            }
            if (!keep) {
                close_client(c);
            }
        }
    }
}

void pump_wifi_api_start(void)
{
    if (s_started) {
        return;
    }
    if (!s_tx_lock) {
        s_tx_lock = xSemaphoreCreateMutex();
        for (int i = 0; i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
            s_clients[i].fd = -1;
        }
    }
    s_started = xTaskCreate(server_task, "wifi_api", 6144, NULL, 4, NULL) == pdPASS;
}

void pump_wifi_api_notify(uint8_t chr, const uint8_t *buf, size_t len)
{
    if (!s_started) {
        return;
    }
    for (int i = 0; i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
        client_t *c = &s_clients[i];
        if (c->fd >= 0 && c->api.authed) {
            send_frame(c, PUMP_WIFI_API_NOTIFY, chr, buf, len, true);
        }
    }
}

bool pump_wifi_api_is_authed(uint16_t id)
{
    const client_t *c = s_started ? client_by_id(id) : NULL;
    return c && c->api.authed;
}

void pump_wifi_api_drop(uint16_t id)
{
    client_t *c = s_started ? client_by_id(id) : NULL;
    if (c) {
        shutdown(c->fd, SHUT_RDWR);
    }
}

void pump_wifi_api_sign_out_all(void)
{
    /* The key is useless without the session: cut every client. */
    for (int i = 0; s_started && i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
        if (s_clients[i].fd >= 0) {
            pump_api_session_sign_out(&s_clients[i].api);
            shutdown(s_clients[i].fd, SHUT_RDWR);
        }
    }
}

void pump_wifi_api_drop_others(uint16_t keep_id)
{
    for (int i = 0; s_started && i < PUMP_WIFI_API_MAX_CLIENTS; i++) {
        client_t *c = &s_clients[i];
        if (c->fd >= 0 && c->api.id != keep_id) {
            pump_api_session_sign_out(&c->api);
            shutdown(c->fd, SHUT_RDWR);
        }
    }
}
