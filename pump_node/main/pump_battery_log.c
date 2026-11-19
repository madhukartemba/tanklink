#include "pump_battery_log.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "gatt_svr.h"
#include "nvs.h"
#include "pump_clock.h"
#include "pump_tanks.h"

#define TAG "BATLOG"
#define NVS_NS "tl_bat"
#define BATLOG_MAGIC 0x42415431u /* 'BAT1' */

typedef struct {
    uint32_t magic;
    uint8_t count;
    uint8_t reserved[3];
    pump_batlog_day_t days[PUMP_BATLOG_DAYS]; /* oldest first */
} batlog_t;

static batlog_t s_log[PUMP_NODE_MAX];

static void key_for(uint8_t node, char *buf, size_t cap)
{
    snprintf(buf, cap, "b%u", (unsigned)node);
}

static void save(uint8_t node)
{
    char key[8];
    key_for(node, key, sizeof(key));
    s_log[node].magic = BATLOG_MAGIC;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    esp_err_t err = s_log[node].count == 0
                        ? nvs_erase_key(h, key)
                        : nvs_set_blob(h, key, &s_log[node], sizeof(s_log[node]));
    if (err == ESP_OK || err == ESP_ERR_NVS_NOT_FOUND) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "save %u failed: %s", node, esp_err_to_name(err));
    }
}

esp_err_t pump_battery_log_init(void)
{
    memset(s_log, 0, sizeof(s_log));
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return ESP_OK;
    }
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        char key[8];
        key_for(n, key, sizeof(key));
        size_t len = sizeof(s_log[n]);
        if (nvs_get_blob(h, key, &s_log[n], &len) != ESP_OK || len != sizeof(s_log[n]) ||
            s_log[n].magic != BATLOG_MAGIC || s_log[n].count > PUMP_BATLOG_DAYS) {
            memset(&s_log[n], 0, sizeof(s_log[n]));
        }
    }
    nvs_close(h);
    return ESP_OK;
}

void pump_battery_log_note(uint8_t node, uint8_t pct)
{
    int64_t now = 0;
    if (node >= PUMP_NODE_MAX || pct == 0 || !pump_clock_unix_now(&now) || now < 0) {
        return;
    }
    const uint16_t day = (uint16_t)(now / 86400);
    batlog_t *log = &s_log[node];
    pump_batlog_day_t *last = log->count ? &log->days[log->count - 1] : NULL;
    if (last && last->day == day) {
        if (pct >= last->min_pct && pct <= last->max_pct) {
            return; /* nothing new today */
        }
        if (pct < last->min_pct) {
            last->min_pct = pct;
        }
        if (pct > last->max_pct) {
            last->max_pct = pct;
        }
    } else if (last && day < last->day) {
        return; /* clock went back a day: keep the log as it is */
    } else {
        if (log->count == PUMP_BATLOG_DAYS) {
            memmove(&log->days[0], &log->days[1],
                    (PUMP_BATLOG_DAYS - 1) * sizeof(log->days[0]));
            log->count--;
        }
        log->days[log->count++] = (pump_batlog_day_t){.day = day, .min_pct = pct, .max_pct = pct};
    }
    save(node);
    gatt_svr_notify_battery();
}

void pump_battery_log_clear(uint8_t node)
{
    if (node >= PUMP_NODE_MAX || s_log[node].count == 0) {
        return;
    }
    memset(&s_log[node], 0, sizeof(s_log[node]));
    save(node);
    gatt_svr_notify_battery();
}

void pump_battery_log_clear_all(void)
{
    memset(s_log, 0, sizeof(s_log));
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        (void)nvs_erase_all(h);
        (void)nvs_commit(h);
        nvs_close(h);
    }
    gatt_svr_notify_battery();
}

unsigned pump_battery_log_get(uint8_t node, pump_batlog_day_t out[PUMP_BATLOG_DAYS])
{
    if (node >= PUMP_NODE_MAX) {
        return 0;
    }
    memcpy(out, s_log[node].days, s_log[node].count * sizeof(out[0]));
    return s_log[node].count;
}
