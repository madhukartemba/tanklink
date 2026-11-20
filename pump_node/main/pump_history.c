#include "pump_history.h"

#include <string.h>

#include "esp_log.h"
#include "gatt_svr.h"
#include "nvs.h"

#define TAG "HISTORY"
#define NVS_NS "tl_hist"
#define NVS_KEY "fills"
#define HISTORY_MAGIC 0x46494C32u /* 'FIL2': 200 fills */

_Static_assert(PUMP_HISTORY_MAX <= 255, "count and newest are one byte");

typedef struct {
    uint32_t magic;
    uint8_t count;
    uint8_t newest; /* index of the newest entry in the ring */
    uint8_t reserved[2];
    pump_fill_t ring[PUMP_HISTORY_MAX];
} history_blob_t;

static history_blob_t s_blob;

static esp_err_t save(void)
{
    s_blob.magic = HISTORY_MAGIC;
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY, &s_blob, sizeof(s_blob));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

esp_err_t pump_history_init(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t len = sizeof(s_blob);
        if (nvs_get_blob(h, NVS_KEY, &s_blob, &len) != ESP_OK || len != sizeof(s_blob) ||
            s_blob.magic != HISTORY_MAGIC || s_blob.count > PUMP_HISTORY_MAX ||
            s_blob.newest >= PUMP_HISTORY_MAX) {
            memset(&s_blob, 0, sizeof(s_blob));
        }
        nvs_close(h);
    }
    ESP_LOGI(TAG, "%u fills saved", s_blob.count);
    return ESP_OK;
}

esp_err_t pump_history_clear(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    gatt_svr_notify_history();
    return save();
}

void pump_history_add(const pump_fill_t *fill)
{
    if (!fill) {
        return;
    }
    if (s_blob.count > 0) {
        s_blob.newest = (uint8_t)((s_blob.newest + 1) % PUMP_HISTORY_MAX);
    }
    s_blob.ring[s_blob.newest] = *fill;
    s_blob.ring[s_blob.newest].reserved = 0;
    if (s_blob.count < PUMP_HISTORY_MAX) {
        s_blob.count++;
    }
    const esp_err_t err = save();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "save failed: %s", esp_err_to_name(err));
    }
    ESP_LOGI(TAG, "fill slot %u ran %u s, started by %u, stopped by %u", fill->slot,
             (unsigned)fill->ran_sec, fill->started_by, fill->stopped_by);
    gatt_svr_notify_history();
}

unsigned pump_history_count(void)
{
    return s_blob.count;
}

bool pump_history_get(unsigned nth, pump_fill_t *out)
{
    if (nth >= s_blob.count) {
        return false;
    }
    const unsigned i = (s_blob.newest + PUMP_HISTORY_MAX - nth) % PUMP_HISTORY_MAX;
    if (out) {
        *out = s_blob.ring[i];
    }
    return true;
}
