#include "pump_update_http.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "sdkconfig.h"

#include "tanklink_uuid.h"

#define TAG "UPDATE_HTTP"

#define REPLY_MAX 768
/* A download that can't connect must fail fast: pump_ota drops a session that
 * is silent for 60 s. */
#define DOWNLOAD_TIMEOUT_MS 10000
#define IMAGE_MAX (0x1C0000u - 0x20u) /* the OTA slot minus the image header */

/* ---------------------------------------------------------------------------
 * The server's small JSON answer: {"version","url","size","sha256"}
 * ------------------------------------------------------------------------- */

static const char *json_value(const char *json, const char *key)
{
    char pat[24];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    p = p ? strchr(p + strlen(pat), ':') : NULL;
    while (p && *++p == ' ') {
    }
    return p;
}

static bool json_str(const char *json, const char *key, char *out, size_t cap)
{
    const char *p = json_value(json, key);
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
    const char *p = json_value(json, key);
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

static bool parse_offer(const char *body, pump_update_offer_t *out)
{
    char ver[16], sha[80];
    return json_str(body, "version", ver, sizeof(ver)) && parse_version(ver, out->version) &&
           json_str(body, "url", out->url, sizeof(out->url)) &&
           strncmp(out->url, "https://", 8) == 0 &&
           json_str(body, "sha256", sha, sizeof(sha)) && parse_hex(sha, out->sha256, 32) &&
           json_uint(body, "size", &out->size) && out->size >= 1024 && out->size <= IMAGE_MAX;
}

/* ---------------------------------------------------------------------------
 * Latest release
 * ------------------------------------------------------------------------- */

pump_update_fetch_t pump_update_http_latest(pump_update_offer_t *out)
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
    char *body = malloc(REPLY_MAX);
    if (!c || !body) {
        free(body);
        if (c) {
            esp_http_client_cleanup(c);
        }
        return PUMP_UPDATE_FETCH_ERROR;
    }

    pump_update_fetch_t result = PUMP_UPDATE_FETCH_ERROR;
    const esp_err_t open_err = esp_http_client_open(c, 0);
    if (open_err != ESP_OK) {
        ESP_LOGW(TAG, "can't connect: %s", esp_err_to_name(open_err));
        result = PUMP_UPDATE_FETCH_NO_INTERNET;
    } else {
        esp_http_client_fetch_headers(c);
        const int status = esp_http_client_get_status_code(c);
        const int n = esp_http_client_read_response(c, body, REPLY_MAX - 1);
        esp_http_client_close(c);
        if (status == 404) {
            result = PUMP_UPDATE_FETCH_NONE;
        } else if (status == 200 && n > 0) {
            body[n] = '\0';
            if (parse_offer(body, out)) {
                result = PUMP_UPDATE_FETCH_OFFER;
            } else {
                ESP_LOGW(TAG, "bad reply");
            }
        } else {
            ESP_LOGW(TAG, "status %d", status);
        }
    }
    free(body);
    esp_http_client_cleanup(c);
    return result;
}

/* ---------------------------------------------------------------------------
 * Image download
 * ------------------------------------------------------------------------- */

typedef struct {
    pump_update_sink_t sink;
    void *arg;
    uint32_t got;
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
    if (!d->sink(evt->data, (size_t)evt->data_len, d->arg)) {
        d->failed = true;
        return ESP_OK;
    }
    d->got += (uint32_t)evt->data_len;
    return ESP_OK;
}

bool pump_update_http_download(const pump_update_offer_t *offer, pump_update_sink_t sink,
                               void *arg, uint32_t *got)
{
    download_t d = {.sink = sink, .arg = arg};
    const esp_http_client_config_t cfg = {
        .url = offer->url,
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
    *got = d.got;
    const bool ok = err == ESP_OK && status == 200 && !d.failed && d.got == offer->size;
    if (!ok) {
        ESP_LOGW(TAG, "download failed: err=%s status=%d got=%u of %u", esp_err_to_name(err),
                 status, (unsigned)d.got, (unsigned)offer->size);
    }
    return ok;
}
