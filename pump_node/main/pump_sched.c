#include "pump_sched.h"

#include <string.h>

#include "esp_log.h"
#include "nvs.h"

#define TAG "SCHED"
#define NVS_NS "tl_sched"
#define NVS_KEY "list"
#define SCHED_MAGIC 0x53434835u /* 'SCH5' — entries include a tank slot */

typedef struct {
    uint32_t magic;
    uint8_t count;
    pump_sched_entry_t entries[PUMP_SCHED_MAX];
} sched_blob_t;

static sched_blob_t s_blob;
static int s_fired_year[PUMP_SCHED_MAX];
static unsigned s_fired_month[PUMP_SCHED_MAX];
static unsigned s_fired_day[PUMP_SCHED_MAX];

static esp_err_t save_blob(void)
{
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

static bool same_minute(const pump_sched_entry_t *a, const pump_sched_entry_t *b)
{
    return a->hour == b->hour && a->minute == b->minute;
}

esp_err_t pump_sched_init(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    memset(s_fired_year, 0, sizeof(s_fired_year));
    s_blob.magic = SCHED_MAGIC;
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK;
    }
    if (err != ESP_OK) {
        return err;
    }
    size_t len = sizeof(s_blob);
    err = nvs_get_blob(h, NVS_KEY, &s_blob, &len);
    nvs_close(h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        s_blob.magic = SCHED_MAGIC;
        s_blob.count = 0;
        return ESP_OK;
    }
    if (err != ESP_OK) {
        return err;
    }
    if (len != sizeof(s_blob) || s_blob.magic != SCHED_MAGIC || s_blob.count > PUMP_SCHED_MAX) {
        ESP_LOGW(TAG, "schedule blob invalid — clearing");
        memset(&s_blob, 0, sizeof(s_blob));
        s_blob.magic = SCHED_MAGIC;
    }
    ESP_LOGI(TAG, "loaded %u schedules", s_blob.count);
    return ESP_OK;
}

esp_err_t pump_sched_clear(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    s_blob.magic = SCHED_MAGIC;
    pump_sched_clear_fired();
    return save_blob();
}

unsigned pump_sched_count(void)
{
    return s_blob.count;
}

const pump_sched_entry_t *pump_sched_entries(void)
{
    return s_blob.entries;
}

esp_err_t pump_sched_set(const pump_sched_entry_t *entries, unsigned count)
{
    if (count > PUMP_SCHED_MAX || (count > 0 && entries == NULL)) {
        return ESP_ERR_INVALID_ARG;
    }
    for (unsigned i = 0; i < count; i++) {
        if (entries[i].hour > 23 || entries[i].minute > 59 || entries[i].slot > 3) {
            return ESP_ERR_INVALID_ARG;
        }
        for (unsigned j = 0; j < i; j++) {
            if (same_minute(&entries[i], &entries[j])) {
                return ESP_ERR_INVALID_ARG;
            }
        }
    }
    memset(s_blob.entries, 0, sizeof(s_blob.entries));
    s_blob.magic = SCHED_MAGIC;
    s_blob.count = (uint8_t)count;
    if (count > 0) {
        memcpy(s_blob.entries, entries, count * sizeof(pump_sched_entry_t));
    }
    pump_sched_clear_fired();
    esp_err_t err = save_blob();
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "saved %u schedules", count);
    }
    return err;
}

void pump_sched_clear_fired(void)
{
    memset(s_fired_year, 0, sizeof(s_fired_year));
    memset(s_fired_month, 0, sizeof(s_fired_month));
    memset(s_fired_day, 0, sizeof(s_fired_day));
}

esp_err_t pump_sched_drop_slot(uint8_t slot)
{
    unsigned w = 0;
    for (unsigned i = 0; i < s_blob.count; i++) {
        if (s_blob.entries[i].slot == slot) {
            continue;
        }
        s_blob.entries[w++] = s_blob.entries[i];
    }
    if (w == s_blob.count) {
        return ESP_OK;
    }
    memset(&s_blob.entries[w], 0, (PUMP_SCHED_MAX - w) * sizeof(pump_sched_entry_t));
    s_blob.count = (uint8_t)w;
    pump_sched_clear_fired();
    return save_blob();
}

void pump_sched_skip_minute(const pump_civil_time_t *now)
{
    if (!now) {
        return;
    }
    for (unsigned i = 0; i < s_blob.count; i++) {
        const pump_sched_entry_t *e = &s_blob.entries[i];
        if (e->hour == now->hour && e->minute == now->minute) {
            s_fired_year[i] = now->year;
            s_fired_month[i] = now->month;
            s_fired_day[i] = now->day;
            ESP_LOGI(TAG, "skip %02u:%02u after restart", e->hour, e->minute);
        }
    }
}

int pump_sched_take_due(const pump_civil_time_t *now)
{
    if (!now) {
        return -1;
    }
    for (unsigned i = 0; i < s_blob.count; i++) {
        const pump_sched_entry_t *e = &s_blob.entries[i];
        if (!e->enabled) {
            continue;
        }
        if (e->hour != now->hour || e->minute != now->minute) {
            continue;
        }
        if (s_fired_year[i] == now->year && s_fired_month[i] == now->month &&
            s_fired_day[i] == now->day) {
            continue;
        }
        s_fired_year[i] = now->year;
        s_fired_month[i] = now->month;
        s_fired_day[i] = now->day;
        ESP_LOGI(TAG, "due %02u:%02u slot %u", e->hour, e->minute, e->slot);
        return (int)e->slot;
    }
    return -1;
}
