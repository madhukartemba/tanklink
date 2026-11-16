#include "pump_tanks.h"

#include <string.h>

#include "esp_log.h"
#include "nvs.h"
#include "pump_config.h"
#include "pump_sched.h"
#include "tanklink_lora_proto.h"

#define TAG "TANKS"
#define NVS_NS "tl_tanks"
#define NVS_KEY "slots"
#define TANKS_MAGIC 0x544E4B34u /* 'TNK4' */

typedef struct {
    uint32_t magic;
    uint8_t active;
    pump_tank_slot_t slots[PUMP_TANK_SLOT_MAX];
} tanks_blob_t;

static tanks_blob_t s_blob;

static void set_name(char *dst, const char *src)
{
    memset(dst, 0, PUMP_TANK_NAME_LEN);
    if (!src) {
        return;
    }
    size_t n = strlen(src);
    if (n >= PUMP_TANK_NAME_LEN) {
        n = PUMP_TANK_NAME_LEN - 1;
    }
    memcpy(dst, src, n);
}

static bool name_is_default_single(const char *name)
{
    return name[0] == '\0' || strcmp(name, "Tank") == 0;
}

static esp_err_t save_blob(void)
{
    s_blob.magic = TANKS_MAGIC;
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

static void ensure_slot0(void)
{
    if (!s_blob.slots[0].present) {
        memset(&s_blob.slots[0], 0, sizeof(s_blob.slots[0]));
        s_blob.slots[0].present = 1;
        s_blob.slots[0].sensor = 0;
        set_name(s_blob.slots[0].name, "Tank");
    }
}

static void ensure_slot1(void)
{
    if (!s_blob.slots[1].present) {
        memset(&s_blob.slots[1], 0, sizeof(s_blob.slots[1]));
        s_blob.slots[1].present = 1;
        s_blob.slots[1].sensor = 1;
        memcpy(s_blob.slots[1].node_mac, s_blob.slots[0].node_mac, 6);
        set_name(s_blob.slots[1].name, "Tank 2");
    }
}

esp_err_t pump_tanks_init(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READONLY, &h);
    if (err == ESP_OK) {
        size_t len = sizeof(s_blob);
        err = nvs_get_blob(h, NVS_KEY, &s_blob, &len);
        nvs_close(h);
        if (err != ESP_OK || len != sizeof(s_blob) || s_blob.magic != TANKS_MAGIC) {
            memset(&s_blob, 0, sizeof(s_blob));
        }
    }
    ensure_slot0();
    if (pump_tanks_mode() == PUMP_SENSOR_MODE_TWO) {
        ensure_slot1();
        if (name_is_default_single(s_blob.slots[0].name)) {
            set_name(s_blob.slots[0].name, "Tank 1");
        }
    } else {
        s_blob.slots[1].present = 0;
        s_blob.active = 0;
    }
    if (!s_blob.slots[s_blob.active].present) {
        s_blob.active = 0;
    }
    return save_blob();
}

esp_err_t pump_tanks_clear(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    ensure_slot0();
    return save_blob();
}

void pump_tanks_on_node_bound(const uint8_t mac[6])
{
    if (!mac) {
        return;
    }
    ensure_slot0();
    memcpy(s_blob.slots[0].node_mac, mac, 6);
    if (s_blob.slots[1].present) {
        memcpy(s_blob.slots[1].node_mac, mac, 6);
    }
    (void)save_blob();
}

void pump_tanks_on_node_unpaired(void)
{
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        memset(s_blob.slots[i].node_mac, 0, 6);
    }
    (void)save_blob();
}

uint8_t pump_tanks_mode(void)
{
    uint8_t mode = pump_config_sensor_mode();
    return mode > PUMP_SENSOR_MODE_TWO ? PUMP_SENSOR_MODE_OFF : mode;
}

uint8_t pump_tanks_active(void)
{
    return s_blob.active;
}

uint8_t pump_tanks_active_sensor(void)
{
    if (pump_tanks_mode() != PUMP_SENSOR_MODE_TWO) {
        return 0;
    }
    if (s_blob.active >= PUMP_TANK_SLOT_MAX || !s_blob.slots[s_blob.active].present) {
        return 0;
    }
    return s_blob.slots[s_blob.active].sensor ? 1 : 0;
}

unsigned pump_tanks_count(void)
{
    unsigned n = 0;
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        if (s_blob.slots[i].present) {
            n++;
        }
    }
    return n;
}

bool pump_tanks_slot_at(unsigned nth, uint8_t *index, pump_tank_slot_t *out)
{
    unsigned seen = 0;
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        if (!s_blob.slots[i].present) {
            continue;
        }
        if (seen == nth) {
            if (index) {
                *index = (uint8_t)i;
            }
            if (out) {
                *out = s_blob.slots[i];
            }
            return true;
        }
        seen++;
    }
    return false;
}

esp_err_t pump_tanks_set_mode(uint8_t mode, bool pump_running)
{
    if (mode > PUMP_SENSOR_MODE_TWO) {
        return ESP_ERR_INVALID_ARG;
    }
    const uint8_t old = pump_tanks_mode();
    if (old == PUMP_SENSOR_MODE_TWO && mode != PUMP_SENSOR_MODE_TWO) {
        if (pump_running) {
            return ESP_ERR_INVALID_STATE;
        }
        (void)pump_sched_drop_slot(1);
        memset(&s_blob.slots[1], 0, sizeof(s_blob.slots[1]));
        s_blob.active = 0;
    }
    if (mode == PUMP_SENSOR_MODE_TWO && old != PUMP_SENSOR_MODE_TWO) {
        ensure_slot0();
        if (name_is_default_single(s_blob.slots[0].name)) {
            set_name(s_blob.slots[0].name, "Tank 1");
        }
        ensure_slot1();
    }
    if (mode != PUMP_SENSOR_MODE_TWO) {
        s_blob.active = 0;
    }
    esp_err_t err = pump_config_set_sensor_mode(mode);
    if (err != ESP_OK) {
        return err;
    }
    err = save_blob();
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "sensor mode %u", mode);
    }
    return err;
}

esp_err_t pump_tanks_select(uint8_t slot, bool pump_running)
{
    if (slot >= PUMP_TANK_SLOT_MAX || !s_blob.slots[slot].present) {
        return ESP_ERR_INVALID_ARG;
    }
    if (pump_tanks_mode() != PUMP_SENSOR_MODE_TWO && slot != 0) {
        return ESP_ERR_INVALID_STATE;
    }
    if (pump_running && slot != s_blob.active) {
        return ESP_ERR_INVALID_STATE;
    }
    s_blob.active = slot;
    return save_blob();
}

esp_err_t pump_tanks_rename(uint8_t slot, const uint8_t *name, size_t len)
{
    if (slot >= PUMP_TANK_SLOT_MAX || !s_blob.slots[slot].present || !name || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    if (len >= PUMP_TANK_NAME_LEN) {
        len = PUMP_TANK_NAME_LEN - 1;
    }
    char tmp[PUMP_TANK_NAME_LEN];
    memset(tmp, 0, sizeof(tmp));
    size_t n = 0;
    for (size_t i = 0; i < len && n + 1 < PUMP_TANK_NAME_LEN; i++) {
        const uint8_t c = name[i];
        if (c < 0x20 || c > 0x7e) {
            continue;
        }
        tmp[n++] = (char)c;
    }
    if (n == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    set_name(s_blob.slots[slot].name, tmp);
    return save_blob();
}

bool pump_tanks_active_is_full(uint8_t raw_flags)
{
    const bool s1 = (raw_flags & TANKLINK_LORA_FLAG_SENSOR1) != 0;
    const bool s2 = (raw_flags & TANKLINK_LORA_FLAG_SENSOR2) != 0;
    if (pump_tanks_mode() == PUMP_SENSOR_MODE_TWO && pump_tanks_active_sensor() == 1) {
        return s2;
    }
    return s1;
}
