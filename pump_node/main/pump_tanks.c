#include "pump_tanks.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "nvs.h"
#include "pump_config.h"
#include "pump_sched.h"
#include "tanklink_lora_proto.h"

#define TAG "TANKS"
#define NVS_NS "tl_tanks"
#define NVS_KEY "slots"
#define TANKS_MAGIC 0x544E4B36u /* 'TNK6': several sensor nodes */

typedef struct {
    uint32_t magic;
    uint8_t active;
    pump_tank_node_t nodes[PUMP_NODE_MAX];
    pump_tank_slot_t slots[PUMP_TANK_SLOT_MAX];
} tanks_blob_t;

/* Layout up to pump 0.12: one node, its MAC copied into each of 4 slots, and
 * the float mode pump-wide in pump_config. Read once to migrate. */
#define TANKS_MAGIC_V5 0x544E4B35u /* 'TNK5' */
typedef struct {
    uint8_t present;
    uint8_t node_mac[6];
    uint8_t sensor;
    uint8_t auto_off_min;
    char name[PUMP_TANK_NAME_LEN];
} tank_slot_v5_t;
typedef struct {
    uint32_t magic;
    uint8_t active;
    tank_slot_v5_t slots[4];
} tanks_blob_v5_t;

static tanks_blob_t s_blob;

static bool mac_nonzero(const uint8_t *mac)
{
    for (int i = 0; i < 6; i++) {
        if (mac[i] != 0) {
            return true;
        }
    }
    return false;
}

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

static bool node_valid(uint8_t node)
{
    return node < PUMP_NODE_MAX && s_blob.nodes[node].present;
}

static unsigned slot_count(void)
{
    unsigned n = 0;
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        n += s_blob.slots[i].present ? 1 : 0;
    }
    return n;
}

static int find_slot(uint8_t node, uint8_t sensor)
{
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        const pump_tank_slot_t *s = &s_blob.slots[i];
        if (s->present && s->node == node && s->sensor == sensor) {
            return i;
        }
    }
    return -1;
}

/** Delete a slot and any schedule that fills it. */
static void drop_slot(int i)
{
    if (!s_blob.slots[i].present) {
        return;
    }
    ESP_LOGI(TAG, "slot %d removed", i);
    memset(&s_blob.slots[i], 0, sizeof(s_blob.slots[i]));
    (void)pump_sched_drop_slot((uint8_t)i);
}

static int create_slot(uint8_t node, uint8_t sensor, uint8_t auto_off_min)
{
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        if (s_blob.slots[i].present) {
            continue;
        }
        pump_tank_slot_t *s = &s_blob.slots[i];
        memset(s, 0, sizeof(*s));
        s->present = 1;
        s->node = node;
        s->sensor = sensor;
        s->auto_off_min = auto_off_min;
        /* Named in normalize(), once the final slot count is known. */
        /* A schedule left behind by a slot that used this index is stale. */
        (void)pump_sched_drop_slot((uint8_t)i);
        return i;
    }
    return -1;
}

/**
 * Restore the invariants in pump_tanks.h after any change: drop slots whose
 * node is gone (or whose pin the mode no longer uses), add the slots each
 * node needs, fix the active slot, and fill in default names.
 */
static void normalize(void)
{
    unsigned nodes = 0;
    for (int n = 0; n < PUMP_NODE_MAX; n++) {
        pump_tank_node_t *node = &s_blob.nodes[n];
        if (node->present && !mac_nonzero(node->mac)) {
            node->present = 0;
        }
        if (!node->present) {
            memset(node, 0, sizeof(*node));
            continue;
        }
        if (node->mode > PUMP_SENSOR_MODE_TWO) {
            node->mode = PUMP_SENSOR_MODE_OFF;
        }
        nodes++;
    }

    bool kept_orphan = false;
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        pump_tank_slot_t *s = &s_blob.slots[i];
        if (!s->present) {
            continue;
        }
        bool keep;
        if (s->node == PUMP_NODE_NONE) {
            keep = nodes == 0 && !kept_orphan;
            if (keep) {
                kept_orphan = true;
                s->sensor = 0;
            }
        } else {
            keep = node_valid(s->node) && s->sensor <= 1 &&
                   (s->sensor == 0 || s_blob.nodes[s->node].mode == PUMP_SENSOR_MODE_TWO) &&
                   find_slot(s->node, s->sensor) == i; /* first of any duplicates */
        }
        if (!keep) {
            drop_slot(i);
            continue;
        }
        if (s->auto_off_min > PUMP_AUTO_OFF_MAX_MIN) {
            s->auto_off_min = PUMP_AUTO_OFF_MAX_MIN;
        }
        s->name[PUMP_TANK_NAME_LEN - 1] = '\0';
    }

    for (int n = 0; n < PUMP_NODE_MAX; n++) {
        if (!s_blob.nodes[n].present) {
            continue;
        }
        int first = find_slot((uint8_t)n, 0);
        if (first < 0) {
            first = create_slot((uint8_t)n, 0, PUMP_AUTO_OFF_DEFAULT_MIN);
        }
        if (s_blob.nodes[n].mode == PUMP_SENSOR_MODE_TWO && find_slot((uint8_t)n, 1) < 0) {
            const uint8_t mins =
                first >= 0 ? s_blob.slots[first].auto_off_min : PUMP_AUTO_OFF_DEFAULT_MIN;
            (void)create_slot((uint8_t)n, 1, mins);
        }
    }
    if (nodes == 0 && !kept_orphan) {
        (void)create_slot(PUMP_NODE_NONE, 0, PUMP_AUTO_OFF_DEFAULT_MIN);
    }

    if (s_blob.active >= PUMP_TANK_SLOT_MAX || !s_blob.slots[s_blob.active].present) {
        s_blob.active = 0;
        for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
            if (s_blob.slots[i].present) {
                s_blob.active = (uint8_t)i;
                break;
            }
        }
    }

    /* One tank is just "Tank"; with several, each gets a number. */
    const bool several = slot_count() > 1;
    for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
        pump_tank_slot_t *s = &s_blob.slots[i];
        if (!s->present) {
            continue;
        }
        if (s->name[0] == '\0' || (several && strcmp(s->name, "Tank") == 0)) {
            if (several) {
                char buf[PUMP_TANK_NAME_LEN];
                snprintf(buf, sizeof(buf), "Tank %d", i + 1);
                set_name(s->name, buf);
            } else {
                set_name(s->name, "Tank");
            }
        }
    }
}

/** Single-node layout: node 0 gets the MAC and the pump-wide float mode. */
static void migrate_v5(const tanks_blob_v5_t *old)
{
    memset(&s_blob, 0, sizeof(s_blob));
    const uint8_t *mac = NULL;
    for (int i = 0; i < 4; i++) {
        if (old->slots[i].present && mac_nonzero(old->slots[i].node_mac)) {
            mac = old->slots[i].node_mac;
            break;
        }
    }
    if (mac) {
        s_blob.nodes[0].present = 1;
        memcpy(s_blob.nodes[0].mac, mac, 6);
        s_blob.nodes[0].mode = pump_config_sensor_mode();
    }
    for (int i = 0; i < 4; i++) {
        const tank_slot_v5_t *o = &old->slots[i];
        if (!o->present) {
            continue;
        }
        pump_tank_slot_t *s = &s_blob.slots[i];
        s->present = 1;
        s->node = mac ? 0 : PUMP_NODE_NONE;
        s->sensor = o->sensor;
        s->auto_off_min = o->auto_off_min;
        memcpy(s->name, o->name, PUMP_TANK_NAME_LEN);
    }
    s_blob.active = old->active;
    ESP_LOGI(TAG, "migrated single-sensor tank slots (sensor %s)", mac ? "paired" : "none");
}

esp_err_t pump_tanks_init(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        size_t len = 0;
        if (nvs_get_blob(h, NVS_KEY, NULL, &len) == ESP_OK) {
            if (len == sizeof(tanks_blob_t)) {
                if (nvs_get_blob(h, NVS_KEY, &s_blob, &len) != ESP_OK ||
                    s_blob.magic != TANKS_MAGIC) {
                    memset(&s_blob, 0, sizeof(s_blob));
                }
            } else if (len == sizeof(tanks_blob_v5_t)) {
                tanks_blob_v5_t old;
                if (nvs_get_blob(h, NVS_KEY, &old, &len) == ESP_OK &&
                    old.magic == TANKS_MAGIC_V5) {
                    migrate_v5(&old);
                }
            }
        }
        nvs_close(h);
    }
    normalize();
    ESP_LOGI(TAG, "%u sensor(s), %u tank(s), active slot %u", pump_tanks_node_count(),
             pump_tanks_count(), s_blob.active);
    return save_blob();
}

esp_err_t pump_tanks_clear(void)
{
    memset(&s_blob, 0, sizeof(s_blob));
    normalize();
    return save_blob();
}

/* ---- Sensor nodes ---- */

unsigned pump_tanks_node_count(void)
{
    unsigned n = 0;
    for (int i = 0; i < PUMP_NODE_MAX; i++) {
        n += s_blob.nodes[i].present ? 1 : 0;
    }
    return n;
}

bool pump_tanks_node_get(uint8_t node, pump_tank_node_t *out)
{
    if (!node_valid(node)) {
        return false;
    }
    if (out) {
        *out = s_blob.nodes[node];
    }
    return true;
}

int pump_tanks_node_find(const uint8_t mac[6])
{
    if (!mac || !mac_nonzero(mac)) {
        return -1;
    }
    for (int i = 0; i < PUMP_NODE_MAX; i++) {
        if (s_blob.nodes[i].present && memcmp(s_blob.nodes[i].mac, mac, 6) == 0) {
            return i;
        }
    }
    return -1;
}

esp_err_t pump_tanks_node_add(const uint8_t mac[6], uint8_t *index, bool *added)
{
    if (added) {
        *added = false;
    }
    if (!mac || !mac_nonzero(mac)) {
        return ESP_ERR_INVALID_ARG;
    }
    const int found = pump_tanks_node_find(mac);
    if (found >= 0) {
        if (index) {
            *index = (uint8_t)found;
        }
        return ESP_OK;
    }
    int idx = -1;
    for (int i = 0; i < PUMP_NODE_MAX; i++) {
        if (!s_blob.nodes[i].present) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        return ESP_ERR_NO_MEM;
    }
    const bool first = pump_tanks_node_count() == 0;
    pump_tank_node_t *node = &s_blob.nodes[idx];
    memset(node, 0, sizeof(*node));
    node->present = 1;
    memcpy(node->mac, mac, 6);
    node->mode = PUMP_SENSOR_MODE_OFF;
    if (first) {
        /* The no-sensor tank (name, auto-off) becomes this sensor's tank. */
        for (int i = 0; i < PUMP_TANK_SLOT_MAX; i++) {
            if (s_blob.slots[i].present && s_blob.slots[i].node == PUMP_NODE_NONE) {
                s_blob.slots[i].node = (uint8_t)idx;
                s_blob.slots[i].sensor = 0;
                break;
            }
        }
    }
    normalize();
    if (index) {
        *index = (uint8_t)idx;
    }
    if (added) {
        *added = true;
    }
    ESP_LOGI(TAG, "sensor %d added, %u tank(s)", idx, pump_tanks_count());
    return save_blob();
}

esp_err_t pump_tanks_node_remove(uint8_t node, bool pump_running)
{
    if (!node_valid(node)) {
        return ESP_ERR_INVALID_ARG;
    }
    if (pump_running && pump_tanks_active_node() == node) {
        return ESP_ERR_INVALID_STATE;
    }
    if (pump_tanks_node_count() == 1) {
        /* Last sensor: keep its first tank's name and auto-off, sensorless. */
        const int keep = find_slot(node, 0);
        if (keep >= 0) {
            s_blob.slots[keep].node = PUMP_NODE_NONE;
        }
    }
    memset(&s_blob.nodes[node], 0, sizeof(s_blob.nodes[node]));
    normalize();
    ESP_LOGI(TAG, "sensor %u removed, %u tank(s)", node, pump_tanks_count());
    return save_blob();
}

uint8_t pump_tanks_node_mode(uint8_t node)
{
    return node_valid(node) ? s_blob.nodes[node].mode : PUMP_SENSOR_MODE_OFF;
}

esp_err_t pump_tanks_set_node_mode(uint8_t node, uint8_t mode, bool pump_running)
{
    if (!node_valid(node) || mode > PUMP_SENSOR_MODE_TWO) {
        return ESP_ERR_INVALID_ARG;
    }
    pump_tank_node_t *n = &s_blob.nodes[node];
    if (n->mode == mode) {
        return ESP_OK;
    }
    if (n->mode == PUMP_SENSOR_MODE_TWO && pump_running) {
        const int second = find_slot(node, 1);
        if (second >= 0 && second == s_blob.active) {
            return ESP_ERR_INVALID_STATE;
        }
    }
    n->mode = mode;
    normalize();
    ESP_LOGI(TAG, "sensor %u float mode %u", node, mode);
    return save_blob();
}

/* ---- Tank slots ---- */

unsigned pump_tanks_count(void)
{
    return slot_count();
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

bool pump_tanks_slot_present(uint8_t slot)
{
    return slot < PUMP_TANK_SLOT_MAX && s_blob.slots[slot].present;
}

uint8_t pump_tanks_active(void)
{
    return s_blob.active;
}

uint8_t pump_tanks_active_node(void)
{
    if (!pump_tanks_slot_present(s_blob.active)) {
        return PUMP_NODE_NONE;
    }
    const uint8_t node = s_blob.slots[s_blob.active].node;
    return node_valid(node) ? node : PUMP_NODE_NONE;
}

uint8_t pump_tanks_mode(void)
{
    return pump_tanks_node_mode(pump_tanks_active_node());
}

esp_err_t pump_tanks_select(uint8_t slot, bool pump_running)
{
    if (!pump_tanks_slot_present(slot)) {
        return ESP_ERR_INVALID_ARG;
    }
    if (slot == s_blob.active) {
        return ESP_OK;
    }
    if (pump_running) {
        return ESP_ERR_INVALID_STATE;
    }
    s_blob.active = slot;
    ESP_LOGI(TAG, "active slot %u", slot);
    return save_blob();
}

esp_err_t pump_tanks_rename(uint8_t slot, const uint8_t *name, size_t len)
{
    if (!pump_tanks_slot_present(slot) || !name || len == 0) {
        return ESP_ERR_INVALID_ARG;
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

esp_err_t pump_tanks_set_auto_off(uint8_t slot, uint8_t minutes)
{
    if (!pump_tanks_slot_present(slot)) {
        return ESP_ERR_INVALID_ARG;
    }
    if (minutes > PUMP_AUTO_OFF_MAX_MIN) {
        minutes = PUMP_AUTO_OFF_MAX_MIN;
    }
    s_blob.slots[slot].auto_off_min = minutes;
    ESP_LOGI(TAG, "slot %u auto-off %u min", slot, minutes);
    return save_blob();
}

uint8_t pump_tanks_active_auto_off_min(void)
{
    if (!pump_tanks_slot_present(s_blob.active)) {
        return PUMP_AUTO_OFF_DEFAULT_MIN;
    }
    return s_blob.slots[s_blob.active].auto_off_min;
}

bool pump_tanks_slot_is_full(uint8_t slot, uint8_t raw_flags)
{
    if (!pump_tanks_slot_present(slot)) {
        return false;
    }
    const pump_tank_slot_t *s = &s_blob.slots[slot];
    if (!node_valid(s->node)) {
        return false;
    }
    if (s->sensor == 1 && s_blob.nodes[s->node].mode == PUMP_SENSOR_MODE_TWO) {
        return (raw_flags & TANKLINK_LORA_FLAG_SENSOR2) != 0;
    }
    return (raw_flags & TANKLINK_LORA_FLAG_SENSOR1) != 0;
}

bool pump_tanks_active_is_full(uint8_t raw_flags)
{
    return pump_tanks_slot_is_full(s_blob.active, raw_flags);
}
