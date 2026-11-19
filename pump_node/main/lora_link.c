#include "lora_link.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "gatt_svr.h"
#include "pump_control.h"
#include "nvs.h"
#include "pump_clock.h"
#include "pump_tanks.h"
#include "pump_battery_log.h"
#include "pump_errors.h"
#include "pump_pair.h"
#include "relay_control.h"
#include "sdkconfig.h"
#include "status_led.h"
#include "sx1278.h"

#define TAG "LORA"
#define NVS_NS "tl_tank"
/* Per sensor, suffixed with the node index: BLE OTA token and last packet. */
#define NVS_KEY_TOKEN "tok"
#define NVS_KEY_LAST "last"
#define LAST_REC_VER 2
/* Save at most once a minute unless the float flags changed. */
#define LAST_SAVE_MIN_US (60LL * 1000000)

#ifndef CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS
#define CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS 60000
#endif

#if !CONFIG_PUMP_ENABLE_LORA

esp_err_t lora_link_init(void)
{
    ESP_LOGI(TAG, "disabled");
    return ESP_OK;
}
bool lora_link_ready(void)
{
    return false;
}
esp_err_t lora_link_start_tank_pair(uint32_t timeout_ms)
{
    (void)timeout_ms;
    return ESP_ERR_NOT_SUPPORTED;
}
void lora_link_stop_tank_pair(void) {}
bool lora_link_tank_pairing_active(void)
{
    return false;
}
esp_err_t lora_link_unpair_node(uint8_t node)
{
    return pump_tanks_node_remove(node, pump_control_is_on());
}
esp_err_t lora_link_unpair_all(void)
{
    return ESP_OK;
}
void lora_link_on_active_changed(void) {}
bool lora_link_node_status(uint8_t node, lora_node_status_t *out)
{
    (void)node;
    (void)out;
    return false;
}
bool lora_link_active_tank_full(void)
{
    return false;
}
bool lora_link_tank_bound(void)
{
    return false;
}
bool lora_link_tank_heard(void)
{
    return false;
}
bool lora_link_tank_online(void)
{
    return false;
}
uint16_t lora_link_tank_age_sec(void)
{
    return 0xFFFF;
}
int16_t lora_link_tank_rssi_dbm(void)
{
    return 0;
}
int8_t lora_link_tank_snr_db(void)
{
    return 0;
}
const uint8_t *lora_link_tank_id(void)
{
    static const uint8_t z[TANKLINK_LORA_TANK_ID_LEN];
    return z;
}
uint8_t lora_link_tank_flags(void)
{
    return 0;
}
uint8_t lora_link_tank_raw_flags(void)
{
    return 0;
}
uint8_t lora_link_tank_battery_pct(void)
{
    return 0;
}
uint8_t lora_link_tank_fw_major(void)
{
    return 0;
}
uint8_t lora_link_tank_fw_minor(void)
{
    return 0;
}
uint8_t lora_link_tank_fw_patch(void)
{
    return 0;
}
uint8_t lora_link_tank_hw_rev(void)
{
    return 0;
}
uint8_t lora_link_tank_fault(void)
{
    return 0;
}
bool lora_link_tank_has_ble_token(void)
{
    return false;
}
const uint8_t *lora_link_tank_ble_token(void)
{
    static const uint8_t z[TANKLINK_LORA_BLE_TOKEN_LEN];
    return z;
}

#else

#ifndef CONFIG_PUMP_TANK_STALE_SEC
#define CONFIG_PUMP_TANK_STALE_SEC 750
#endif

/** Radio-side state of one paired sensor, indexed like pump_tanks nodes. */
typedef struct {
    bool heard;
    bool was_online;
    bool has_token;
    bool last_pending;
    bool last_saved_once;
    int64_t last_rx_us;
    int64_t last_saved_us;
    uint8_t token[TANKLINK_LORA_BLE_TOKEN_LEN];
    uint8_t flags;
    uint8_t bat;
    uint8_t fw[3];
    uint8_t hw_rev;
    uint8_t fault;
    uint8_t last_saved_flags;
    int16_t rssi_dbm;
    int8_t snr_db;
    uint16_t last_seq;
} node_rt_t;

typedef struct {
    uint8_t ver;
    uint8_t tank_id[TANKLINK_LORA_TANK_ID_LEN];
    uint8_t flags;
    uint8_t bat;
    uint8_t fw[3];
    uint8_t hw_rev;
    int8_t snr_db;
    int16_t rssi_dbm;
    int64_t rx_local_unix; /* pump clock (local time) when the packet arrived */
} tank_last_rec_t;

static bool s_ready;
static bool s_pairing;
static int64_t s_pair_deadline_us;
static node_rt_t s_rt[PUMP_NODE_MAX];
static const uint8_t s_zero_token[TANKLINK_LORA_BLE_TOKEN_LEN];

static void node_key(char *buf, size_t cap, const char *base, uint8_t node)
{
    snprintf(buf, cap, "%s%u", base, (unsigned)node);
}

static bool token_nonzero(const uint8_t *tok)
{
    for (int i = 0; i < TANKLINK_LORA_BLE_TOKEN_LEN; i++) {
        if (tok[i] != 0) {
            return true;
        }
    }
    return false;
}

static void rt_reset(uint8_t node)
{
    memset(&s_rt[node], 0, sizeof(s_rt[node]));
    s_rt[node].last_seq = 0xFFFF;
}

static bool node_mac(uint8_t node, uint8_t mac[6])
{
    pump_tank_node_t n;
    if (!pump_tanks_node_get(node, &n)) {
        return false;
    }
    memcpy(mac, n.mac, 6);
    return true;
}

static void save_token(uint8_t node)
{
    char key[12];
    node_key(key, sizeof(key), NVS_KEY_TOKEN, node);
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    esp_err_t err = s_rt[node].has_token
                        ? nvs_set_blob(h, key, s_rt[node].token, sizeof(s_rt[node].token))
                        : nvs_erase_key(h, key);
    if (err == ESP_OK || err == ESP_ERR_NVS_NOT_FOUND) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "save token %u failed: %s", node, esp_err_to_name(err));
    }
}

static void load_token(uint8_t node)
{
    char key[12];
    node_key(key, sizeof(key), NVS_KEY_TOKEN, node);
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    size_t len = sizeof(s_rt[node].token);
    if (nvs_get_blob(h, key, s_rt[node].token, &len) == ESP_OK &&
        len == sizeof(s_rt[node].token) && token_nonzero(s_rt[node].token)) {
        s_rt[node].has_token = true;
    } else {
        memset(s_rt[node].token, 0, sizeof(s_rt[node].token));
    }
    nvs_close(h);
}

static void erase_node_keys(uint8_t node)
{
    char key[12];
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    node_key(key, sizeof(key), NVS_KEY_TOKEN, node);
    (void)nvs_erase_key(h, key);
    node_key(key, sizeof(key), NVS_KEY_LAST, node);
    (void)nvs_erase_key(h, key);
    (void)nvs_commit(h);
    nvs_close(h);
}

static uint16_t node_age_sec(uint8_t node)
{
    const node_rt_t *rt = &s_rt[node];
    if (!rt->heard || rt->last_rx_us == 0) {
        return 0xFFFF;
    }
    int64_t age = (esp_timer_get_time() - rt->last_rx_us) / 1000000LL;
    if (age < 0) {
        age = 0;
    }
    if (age > 65535) {
        age = 65535;
    }
    return (uint16_t)age;
}

static bool node_online(uint8_t node)
{
    if (node >= PUMP_NODE_MAX || !pump_tanks_node_get(node, NULL) || !s_rt[node].heard) {
        return false;
    }
    return node_age_sec(node) <= (uint16_t)CONFIG_PUMP_TANK_STALE_SEC;
}

/** Radio state of the selected tank's sensor, or NULL. */
static const node_rt_t *active_rt(void)
{
    const uint8_t node = pump_tanks_active_node();
    return node == PUMP_NODE_NONE ? NULL : &s_rt[node];
}

/* Needs a known time: the age is stored as the packet's clock time. */
static void save_last(uint8_t node)
{
    node_rt_t *rt = &s_rt[node];
    int64_t now_unix = 0;
    uint8_t mac[6];
    if (!rt->heard || !node_mac(node, mac) || !pump_clock_unix_now(&now_unix)) {
        return;
    }
    const int64_t age_s = (esp_timer_get_time() - rt->last_rx_us) / 1000000LL;
    tank_last_rec_t rec = {
        .ver = LAST_REC_VER,
        .flags = rt->flags,
        .bat = rt->bat,
        .fw = {rt->fw[0], rt->fw[1], rt->fw[2]},
        .hw_rev = rt->hw_rev,
        .snr_db = rt->snr_db,
        .rssi_dbm = rt->rssi_dbm,
        .rx_local_unix = now_unix - (age_s > 0 ? age_s : 0),
    };
    memcpy(rec.tank_id, mac, sizeof(rec.tank_id));
    char key[12];
    node_key(key, sizeof(key), NVS_KEY_LAST, node);
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    esp_err_t err = nvs_set_blob(h, key, &rec, sizeof(rec));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "save last-seen failed: %s", esp_err_to_name(err));
        return;
    }
    rt->last_pending = false;
    rt->last_saved_us = esp_timer_get_time();
    rt->last_saved_once = true;
    rt->last_saved_flags = rt->flags;
}

/* After each packet: save now if the floats changed, otherwise rate-limit. */
static void note_last_changed(uint8_t node)
{
    node_rt_t *rt = &s_rt[node];
    const bool flags_changed = !rt->last_saved_once || rt->flags != rt->last_saved_flags;
    if (flags_changed || esp_timer_get_time() - rt->last_saved_us >= LAST_SAVE_MIN_US) {
        save_last(node);
    } else {
        rt->last_pending = true;
    }
}

static void poll_last_save(void)
{
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        if (s_rt[n].last_pending &&
            esp_timer_get_time() - s_rt[n].last_saved_us >= LAST_SAVE_MIN_US) {
            save_last(n);
        }
    }
}

/*
 * Restore a sensor's last packet so a restart does not show it as never
 * heard. Only when the clock is known (RTC). The saved "full" flag is honoured
 * while the record is inside the stale window, so the pump still refuses to
 * start into a full tank right after a restart.
 */
static void restore_last(uint8_t node)
{
    uint8_t mac[6];
    if (!node_mac(node, mac)) {
        return;
    }
    int64_t now_unix = 0;
    if (!pump_clock_unix_now(&now_unix)) {
        ESP_LOGI(TAG, "sensor %u last-seen not restored: clock unknown", node);
        return;
    }
    char key[12];
    node_key(key, sizeof(key), NVS_KEY_LAST, node);
    tank_last_rec_t rec;
    size_t len = sizeof(rec);
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    esp_err_t err = nvs_get_blob(h, key, &rec, &len);
    nvs_close(h);
    if (err != ESP_OK || len != sizeof(rec) || rec.ver != LAST_REC_VER ||
        memcmp(rec.tank_id, mac, sizeof(mac)) != 0) {
        return;
    }
    int64_t age = now_unix - rec.rx_local_unix;
    if (age < -120) {
        /* Clock went backwards by more than a little: the record is unusable. */
        ESP_LOGW(TAG, "sensor %u last-seen in the future (%lld s); ignoring", node,
                 (long long)-age);
        return;
    }
    if (age < 0) {
        age = 0;
    }
    node_rt_t *rt = &s_rt[node];
    rt->heard = true;
    rt->last_rx_us = esp_timer_get_time() - age * 1000000LL;
    rt->flags = rec.flags;
    rt->bat = rec.bat;
    memcpy(rt->fw, rec.fw, sizeof(rt->fw));
    rt->hw_rev = rec.hw_rev;
    rt->rssi_dbm = rec.rssi_dbm;
    rt->snr_db = rec.snr_db;
    rt->last_saved_once = true;
    rt->last_saved_flags = rec.flags;
    rt->was_online = node_online(node);
    ESP_LOGI(TAG, "sensor %u last heard %lld s ago (restored, %s) flags=0x%02x", node,
             (long long)age, rt->was_online ? "online" : "stale", rec.flags);
}

static void send_ack(const tanklink_lora_status_t *pkt)
{
    tanklink_lora_status_t ack;
    memset(&ack, 0, sizeof(ack));
    ack.magic0 = TANKLINK_LORA_MAGIC0;
    ack.magic1 = TANKLINK_LORA_MAGIC1;
    ack.ver = TANKLINK_LORA_VER;
    ack.type = TANKLINK_LORA_TYPE_ACK;
    ack.seq = pkt->seq;
    memcpy(ack.tank_id, pkt->tank_id, TANKLINK_LORA_TANK_ID_LEN);
    esp_err_t err = sx1278_send((const uint8_t *)&ack, sizeof(ack), 1500);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "ACK TX failed: %s", esp_err_to_name(err));
    }
    (void)sx1278_start_rx();
}

void lora_link_on_active_changed(void)
{
    const uint8_t node = pump_tanks_active_node();
    status_led_set_tank_full(lora_link_active_tank_full());
    /* "Tank out of range" is about the selected tank only. */
    if (pump_control_last_error() == PUMP_ERR_TANK_OFFLINE &&
        (node == PUMP_NODE_NONE || node_online(node))) {
        pump_control_clear_error();
    }
}

static void notify_after_packet(bool active)
{
    if (active) {
        gatt_svr_notify_tank();
    }
    gatt_svr_notify_nodes();
}

static uint8_t packet_fault(const uint8_t *buf, size_t n, uint8_t type)
{
    if (type == TANKLINK_LORA_TYPE_PAIR) {
        return n > TANKLINK_LORA_PAIR_LEN ? buf[TANKLINK_LORA_PAIR_LEN] : 0;
    }
    return n > sizeof(tanklink_lora_status_t) ? buf[sizeof(tanklink_lora_status_t)] : 0;
}

static void apply_tank_packet(uint8_t node, const tanklink_lora_status_t *pkt,
                              int16_t rssi_dbm, int8_t snr_db, uint8_t fault)
{
    node_rt_t *rt = &s_rt[node];
    rt->heard = true;
    rt->last_rx_us = esp_timer_get_time();
    rt->flags = pkt->flags;
    rt->bat = pkt->battery_pct;
    rt->fault = fault;
    rt->fw[0] = pkt->fw_major;
    rt->fw[1] = pkt->fw_minor;
    rt->fw[2] = pkt->fw_patch;
    rt->hw_rev = pkt->hw_rev;
    rt->rssi_dbm = rssi_dbm;
    rt->snr_db = snr_db;
    pump_battery_log_note(node, rt->bat);
    const bool active = node == pump_tanks_active_node();
    bool full = false;
    if (active) {
        full = pump_tanks_active_is_full(pkt->flags);
        status_led_set_tank_full(full);
        /* Only the selected tank stops a fill; other tanks may well be full. */
        if (full && pump_control_is_on()) {
            pump_control_set_silent(false, PUMP_CAUSE_TANK_FULL);
        }
    }
    ESP_LOGI(TAG,
             "sensor %u RX type=%u flags=0x%02x bat=%u%% seq=%u fw=%u.%u.%u%s full=%d "
             "fault=%u rssi=%d snr=%d",
             node, pkt->type, pkt->flags, pkt->battery_pct, pkt->seq, pkt->fw_major,
             pkt->fw_minor, pkt->fw_patch, active ? " (selected)" : "", (int)full,
             fault, (int)rssi_dbm, (int)snr_db);
    note_last_changed(node);
    notify_after_packet(active);
}

/** A packet from a paired sensor: state changes once per seq, signal always. */
static void handle_packet(uint8_t node, const tanklink_lora_status_t *pkt, int16_t rssi,
                          int8_t snr, uint8_t fault)
{
    node_rt_t *rt = &s_rt[node];
    if (pkt->seq != rt->last_seq) {
        rt->last_seq = pkt->seq;
        apply_tank_packet(node, pkt, rssi, snr, fault);
    } else {
        rt->rssi_dbm = rssi;
        rt->snr_db = snr;
        notify_after_packet(node == pump_tanks_active_node());
    }
}

static void restore_led_after_tank_pair(void)
{
    if (status_led_get_mode() != STATUS_LED_TANK_PAIRING) {
        return;
    }
    if (pump_pair_pairing_active()) {
        status_led_set_mode(STATUS_LED_PAIRING);
    } else if (!pump_pair_is_paired()) {
        status_led_set_mode(STATUS_LED_UNPAIRED);
    } else if (pump_control_is_on()) {
        status_led_set_mode(STATUS_LED_PUMP_ON);
    } else {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

static bool pairing_window_open(void)
{
    if (!s_pairing) {
        return false;
    }
    if (esp_timer_get_time() >= s_pair_deadline_us) {
        s_pairing = false;
        ESP_LOGI(TAG, "tank pair window closed");
        restore_led_after_tank_pair();
        gatt_svr_notify_tank();
        return false;
    }
    return true;
}

static void on_pair_packet(const uint8_t *buf, size_t n, int16_t rssi, int8_t snr)
{
    const tanklink_lora_status_t *pkt = (const tanklink_lora_status_t *)buf;
    if (n < TANKLINK_LORA_PAIR_LEN) {
        ESP_LOGW(TAG, "PAIR ignored — %u bytes, no token", (unsigned)n);
        return;
    }
    if (!pairing_window_open()) {
        ESP_LOGW(TAG, "PAIR ignored — window closed");
        return;
    }
    uint8_t node = 0;
    bool added = false;
    const esp_err_t err = pump_tanks_node_add(pkt->tank_id, &node, &added);
    if (err == ESP_ERR_NO_MEM) {
        ESP_LOGW(TAG, "PAIR ignored — %d sensors already paired", PUMP_NODE_MAX);
        return;
    }
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "PAIR ignored — %s", esp_err_to_name(err));
        return;
    }
    if (added) {
        rt_reset(node);
        erase_node_keys(node);
        pump_battery_log_clear(node);
    }
    node_rt_t *rt = &s_rt[node];
    memcpy(rt->token, buf + sizeof(tanklink_lora_status_t), TANKLINK_LORA_BLE_TOKEN_LEN);
    rt->has_token = token_nonzero(rt->token);
    save_token(node);
    s_pairing = false;
    restore_led_after_tank_pair();
    send_ack(pkt);
    ESP_LOGI(TAG, "sensor %u %s %02x:%02x:%02x:%02x:%02x:%02x", node,
             added ? "paired" : "re-paired", pkt->tank_id[0], pkt->tank_id[1],
             pkt->tank_id[2], pkt->tank_id[3], pkt->tank_id[4], pkt->tank_id[5]);
    handle_packet(node, pkt, rssi, snr, packet_fault(buf, n, pkt->type));
    /* A first sensor becomes the selected tank's sensor; slots may have changed. */
    lora_link_on_active_changed();
    gatt_svr_notify_tank();
    gatt_svr_notify_tanks();
    gatt_svr_notify_nodes();
}

static void on_status_packet(const uint8_t *buf, size_t n, int16_t rssi, int8_t snr)
{
    const tanklink_lora_status_t *pkt = (const tanklink_lora_status_t *)buf;
    const int node = pump_tanks_node_find(pkt->tank_id);
    if (node < 0) {
        ESP_LOGW(TAG, "STATUS ignored — sensor %02x%02x not paired", pkt->tank_id[4],
                 pkt->tank_id[5]);
        return;
    }
    send_ack(pkt);
    handle_packet((uint8_t)node, pkt, rssi, snr, packet_fault(buf, n, pkt->type));
}

/** Notice sensors dropping out of range (and coming back). */
static void poll_online(void)
{
    const uint8_t active = pump_tanks_active_node();
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        if (!pump_tanks_node_get(n, NULL)) {
            continue;
        }
        node_rt_t *rt = &s_rt[n];
        const bool online = node_online(n);
        if (rt->was_online && !online) {
            rt->was_online = false;
            ESP_LOGW(TAG, "sensor %u went offline (no packet ≥%ds)", n,
                     CONFIG_PUMP_TANK_STALE_SEC);
            if (n == active) {
                pump_control_set_error(PUMP_ERR_TANK_OFFLINE);
            }
            gatt_svr_notify_nodes();
        } else if (online && !rt->was_online) {
            rt->was_online = true;
            if (n == active && pump_control_last_error() == PUMP_ERR_TANK_OFFLINE) {
                pump_control_clear_error();
            }
        }
    }
}

static void lora_task(void *arg)
{
    (void)arg;
    uint8_t buf[64];
    while (true) {
        (void)pairing_window_open();
        poll_last_save();
        poll_online();
        size_t n = 0;
        int16_t rssi = 0;
        int8_t snr = 0;
        esp_err_t err = sx1278_poll_recv_ex(buf, sizeof(buf), &n, &rssi, &snr);
        if (err == ESP_OK && n >= sizeof(tanklink_lora_status_t)) {
            const tanklink_lora_status_t *pkt = (const tanklink_lora_status_t *)buf;
            if (pkt->magic0 != TANKLINK_LORA_MAGIC0 ||
                pkt->magic1 != TANKLINK_LORA_MAGIC1 ||
                pkt->ver != TANKLINK_LORA_VER) {
                vTaskDelay(pdMS_TO_TICKS(15));
                continue;
            }
            if (pkt->type == TANKLINK_LORA_TYPE_PAIR) {
                on_pair_packet(buf, n, rssi, snr);
            } else if (pkt->type == TANKLINK_LORA_TYPE_STATUS) {
                on_status_packet(buf, n, rssi, snr);
            }
        } else if (err != ESP_ERR_NOT_FOUND && err != ESP_ERR_INVALID_CRC) {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        vTaskDelay(pdMS_TO_TICKS(15));
    }
}

esp_err_t lora_link_init(void)
{
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        rt_reset(n);
    }
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        if (!pump_tanks_node_get(n, NULL)) {
            continue;
        }
        load_token(n);
        restore_last(n);
        uint8_t mac[6];
        (void)node_mac(n, mac);
        ESP_LOGI(TAG, "sensor %u %02x:%02x:%02x:%02x:%02x:%02x ble_tok=%d", n, mac[0], mac[1],
                 mac[2], mac[3], mac[4], mac[5], (int)s_rt[n].has_token);
    }
    lora_link_on_active_changed();

    sx1278_config_t cfg = {
        .pin_sck = CONFIG_PUMP_LORA_SCK_GPIO,
        .pin_miso = CONFIG_PUMP_LORA_MISO_GPIO,
        .pin_mosi = CONFIG_PUMP_LORA_MOSI_GPIO,
        .pin_cs = CONFIG_PUMP_LORA_CS_GPIO,
        .pin_rst = CONFIG_PUMP_LORA_RST_GPIO,
        .pin_dio0 = CONFIG_PUMP_LORA_DIO0_GPIO,
        .freq_hz = (uint32_t)CONFIG_PUMP_LORA_FREQ_HZ,
    };
    esp_err_t err = sx1278_init(&cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "RA-02 not ready (%s) — continuing without LoRa",
                 esp_err_to_name(err));
        s_ready = false;
        return err;
    }
    err = sx1278_start_rx();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "RX start failed: %s", esp_err_to_name(err));
        s_ready = false;
        return err;
    }
    s_ready = true;
    if (xTaskCreate(lora_task, "lora_rx", 4096, NULL, 5, NULL) != pdPASS) {
        ESP_LOGW(TAG, "lora_rx task failed");
        s_ready = false;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "listening for tank sensors @ %u Hz", (unsigned)CONFIG_PUMP_LORA_FREQ_HZ);
    return ESP_OK;
}

bool lora_link_ready(void)
{
    return s_ready;
}

esp_err_t lora_link_start_tank_pair(uint32_t timeout_ms)
{
    if (!s_ready) {
        return ESP_ERR_INVALID_STATE;
    }
    if (timeout_ms < 5000) {
        timeout_ms = CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS;
    }
    s_pairing = true;
    s_pair_deadline_us = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    status_led_set_mode(STATUS_LED_TANK_PAIRING);
    ESP_LOGI(TAG, "tank pair window open (%u ms)", (unsigned)timeout_ms);
    gatt_svr_notify_tank();
    return ESP_OK;
}

void lora_link_stop_tank_pair(void)
{
    if (s_pairing) {
        s_pairing = false;
        ESP_LOGI(TAG, "tank pair window stopped");
        restore_led_after_tank_pair();
        gatt_svr_notify_tank();
    }
}

bool lora_link_tank_pairing_active(void)
{
    return pairing_window_open();
}

esp_err_t lora_link_unpair_node(uint8_t node)
{
    const esp_err_t err = pump_tanks_node_remove(node, pump_control_is_on());
    if (err != ESP_OK) {
        return err;
    }
    rt_reset(node);
    erase_node_keys(node);
    pump_battery_log_clear(node);
    ESP_LOGI(TAG, "sensor %u unpaired", node);
    lora_link_on_active_changed();
    gatt_svr_notify_tank();
    gatt_svr_notify_tanks();
    gatt_svr_notify_nodes();
    gatt_svr_notify_sched();
    return ESP_OK;
}

esp_err_t lora_link_unpair_all(void)
{
    for (uint8_t n = 0; n < PUMP_NODE_MAX; n++) {
        if (pump_tanks_node_get(n, NULL)) {
            (void)pump_tanks_node_remove(n, false);
        }
        rt_reset(n);
    }
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err == ESP_OK) {
        err = nvs_erase_all(h);
        if (err == ESP_OK) {
            err = nvs_commit(h);
        }
        nvs_close(h);
    }
    pump_battery_log_clear_all();
    status_led_set_tank_full(false);
    ESP_LOGI(TAG, "all sensors unpaired");
    gatt_svr_notify_tank();
    gatt_svr_notify_tanks();
    gatt_svr_notify_nodes();
    return err;
}

bool lora_link_node_status(uint8_t node, lora_node_status_t *out)
{
    if (node >= PUMP_NODE_MAX || !pump_tanks_node_get(node, NULL)) {
        return false;
    }
    if (!out) {
        return true;
    }
    const node_rt_t *rt = &s_rt[node];
    memset(out, 0, sizeof(*out));
    out->heard = rt->heard;
    out->online = node_online(node);
    out->age_sec = node_age_sec(node);
    out->raw_flags = rt->flags;
    out->battery_pct = rt->bat;
    memcpy(out->fw, rt->fw, sizeof(out->fw));
    out->hw_rev = rt->hw_rev;
    out->fault = rt->fault;
    out->rssi_dbm = rt->heard ? rt->rssi_dbm : 0;
    out->snr_db = rt->heard ? rt->snr_db : 0;
    out->has_ble_token = rt->has_token;
    memcpy(out->ble_token, rt->token, sizeof(out->ble_token));
    return true;
}

bool lora_link_active_tank_full(void)
{
    const uint8_t node = pump_tanks_active_node();
    return node != PUMP_NODE_NONE && node_online(node) &&
           pump_tanks_active_is_full(s_rt[node].flags);
}

bool lora_link_tank_bound(void)
{
    return pump_tanks_active_node() != PUMP_NODE_NONE;
}
bool lora_link_tank_heard(void)
{
    const node_rt_t *rt = active_rt();
    return rt && rt->heard;
}
bool lora_link_tank_online(void)
{
    return node_online(pump_tanks_active_node());
}
uint16_t lora_link_tank_age_sec(void)
{
    const uint8_t node = pump_tanks_active_node();
    return node == PUMP_NODE_NONE ? 0xFFFF : node_age_sec(node);
}
int16_t lora_link_tank_rssi_dbm(void)
{
    const node_rt_t *rt = active_rt();
    return rt && rt->heard ? rt->rssi_dbm : 0;
}
int8_t lora_link_tank_snr_db(void)
{
    const node_rt_t *rt = active_rt();
    return rt && rt->heard ? rt->snr_db : 0;
}
const uint8_t *lora_link_tank_id(void)
{
    static uint8_t id[TANKLINK_LORA_TANK_ID_LEN];
    if (!node_mac(pump_tanks_active_node(), id)) {
        memset(id, 0, sizeof(id));
    }
    return id;
}
bool lora_link_tank_has_ble_token(void)
{
    const node_rt_t *rt = active_rt();
    return rt && rt->has_token;
}
const uint8_t *lora_link_tank_ble_token(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->token : s_zero_token;
}
uint8_t lora_link_tank_raw_flags(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->flags : 0;
}
uint8_t lora_link_tank_flags(void)
{
    /* Bit 0 is "selected tank is full" and bit 1 is "almost empty". */
    const uint8_t raw = lora_link_tank_raw_flags();
    uint8_t out = raw & (uint8_t)(TANKLINK_LORA_FLAG_BTN | TANKLINK_LORA_FLAG_PAIRING);
    if (!lora_link_tank_bound()) {
        return out;
    }
    if (pump_tanks_active_is_full(raw)) {
        out |= TANKLINK_LORA_FLAG_SENSOR1;
    }
    if (pump_tanks_mode() == PUMP_SENSOR_MODE_EMPTY && !(raw & TANKLINK_LORA_FLAG_SENSOR2)) {
        out |= TANKLINK_LORA_FLAG_SENSOR2;
    }
    return out;
}
uint8_t lora_link_tank_battery_pct(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->bat : 0;
}
uint8_t lora_link_tank_fw_major(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->fw[0] : 0;
}
uint8_t lora_link_tank_fw_minor(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->fw[1] : 0;
}
uint8_t lora_link_tank_fw_patch(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->fw[2] : 0;
}
uint8_t lora_link_tank_hw_rev(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->hw_rev : 0;
}
uint8_t lora_link_tank_fault(void)
{
    const node_rt_t *rt = active_rt();
    return rt ? rt->fault : 0;
}

#endif /* CONFIG_PUMP_ENABLE_LORA */
