/*
 * The pump's BLE GATT service: the characteristic table, one access handler
 * per characteristic, the connection table, and notifications.
 *
 * Byte layouts live in gatt_payloads.c and pump behaviour in pump_control.c;
 * this file only moves bytes between them and NimBLE. docs/PROTOCOL.md
 * describes every characteristic.
 */
#include "gatt_svr.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "sdkconfig.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "buzzer.h"
#include "gatt_payloads.h"
#include "lora_link.h"
#include "pump_clock.h"
#include "pump_config.h"
#include "pump_control.h"
#include "pump_diag.h"
#include "pump_factory.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_runlog.h"
#include "pump_sched.h"
#include "pump_tanks.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "GATT_SVR"

#ifndef CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS
#define CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS 60000
#endif

/* ---------------------------------------------------------------------------
 * Connections
 * ------------------------------------------------------------------------- */

/** Which notifications a connection subscribed to. */
typedef enum {
    SUB_STATE,
    SUB_OTA_STATUS,
    SUB_TANK,
    SUB_SCHED,
    SUB_TANKS,
    SUB_NODES,
    SUB_HISTORY,
    SUB_BATTERY,
    SUB_COUNT,
} sub_t;

typedef struct {
    uint16_t conn_handle;
    bool in_use;
    bool authed;
    int8_t phone;                /* pump_pair phone index once authed, else -1 */
    uint8_t history_start;       /* History page a read returns (fill index) */
    uint8_t nonce[TL_NONCE_LEN]; /* Auth challenge, new after every attempt */
    bool subscribed[SUB_COUNT];
} conn_slot_t;

static conn_slot_t s_conns[TANKLINK_MAX_BLE_CONN];

static uint16_t s_pair_val_handle;
static uint16_t s_val_handle[SUB_COUNT];

static conn_slot_t *slot_find(uint16_t conn_handle)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (s_conns[i].in_use && s_conns[i].conn_handle == conn_handle) {
            return &s_conns[i];
        }
    }
    return NULL;
}

static conn_slot_t *slot_alloc(uint16_t conn_handle)
{
    conn_slot_t *existing = slot_find(conn_handle);
    if (existing) {
        return existing;
    }
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (!s_conns[i].in_use) {
            memset(&s_conns[i], 0, sizeof(s_conns[i]));
            s_conns[i].in_use = true;
            s_conns[i].conn_handle = conn_handle;
            s_conns[i].phone = -1;
            esp_fill_random(s_conns[i].nonce, sizeof(s_conns[i].nonce));
            return &s_conns[i];
        }
    }
    return NULL;
}

static void sign_out(conn_slot_t *slot)
{
    slot->authed = false;
    slot->phone = -1;
}

static void clear_all_auth(void)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        sign_out(&s_conns[i]);
    }
}

/** Pump state and OTA progress are public; everything else needs sign-in. */
static bool sub_needs_auth(sub_t sub)
{
    return sub != SUB_STATE && sub != SUB_OTA_STATUS;
}

/** Send [buf] to every connection subscribed to [sub] (signed in, if it needs it). */
static void notify_all(sub_t sub, const uint8_t *buf, size_t len)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (!s_conns[i].in_use || !s_conns[i].subscribed[sub]) {
            continue;
        }
        if (sub_needs_auth(sub) && !s_conns[i].authed) {
            continue;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, len);
        if (!om) {
            continue;
        }
        const int rc = ble_gatts_notify_custom(s_conns[i].conn_handle, s_val_handle[sub], om);
        if (rc != 0) {
            ESP_LOGW(TAG, "notify %d conn=%u rc=%d", sub, s_conns[i].conn_handle, rc);
        }
    }
}

/* ---------------------------------------------------------------------------
 * Notifications
 * ------------------------------------------------------------------------- */

void gatt_svr_notify_state(void)
{
    const uint8_t on = pump_control_is_on() ? 1 : 0;
    notify_all(SUB_STATE, &on, 1);
}

void gatt_svr_notify_tank(void)
{
    uint8_t buf[TANKLINK_TANK_STATUS_LEN];
    notify_all(SUB_TANK, buf, gatt_payload_tank_status(buf));
}

void gatt_svr_notify_tanks(void)
{
    uint8_t buf[GATT_TANKS_MAX_LEN];
    notify_all(SUB_TANKS, buf, gatt_payload_tanks(buf));
}

void gatt_svr_notify_nodes(void)
{
    uint8_t buf[GATT_NODES_MAX_LEN];
    notify_all(SUB_NODES, buf, gatt_payload_nodes(buf));
}

void gatt_svr_notify_history(void)
{
    uint8_t buf[GATT_HISTORY_MAX_LEN];
    notify_all(SUB_HISTORY, buf, gatt_payload_history(buf, 0));
}

void gatt_svr_notify_battery(void)
{
    uint8_t buf[GATT_BATTERY_MAX_LEN];
    notify_all(SUB_BATTERY, buf, gatt_payload_battery(buf));
}

void gatt_svr_notify_sched(void)
{
    uint8_t buf[GATT_SCHED_MAX_LEN];
    notify_all(SUB_SCHED, buf, gatt_payload_sched(buf));
}

static void notify_ota_status(void)
{
    uint8_t buf[GATT_OTA_STATUS_LEN];
    notify_all(SUB_OTA_STATUS, buf, gatt_payload_ota_status(buf));
}

/* ---------------------------------------------------------------------------
 * Access helpers
 * ------------------------------------------------------------------------- */

static bool is_read(const struct ble_gatt_access_ctxt *ctxt)
{
    return ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR;
}

static bool is_write(const struct ble_gatt_access_ctxt *ctxt)
{
    return ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR;
}

static int reply(struct ble_gatt_access_ctxt *ctxt, const uint8_t *buf, size_t len)
{
    return os_mbuf_append(ctxt->om, buf, len) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

/**
 * Copy a write into [buf]. Fails if it is shorter than [min_len] or longer
 * than [cap]. Returns the length in *len.
 */
static int read_write(struct ble_gatt_access_ctxt *ctxt, uint8_t *buf, uint16_t cap,
                      uint16_t min_len, uint16_t *len)
{
    const uint16_t n = OS_MBUF_PKTLEN(ctxt->om);
    if (n < min_len || n > cap) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, n, NULL) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    *len = n;
    return 0;
}

static uint32_t get_u32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
           ((uint32_t)b[3] << 24);
}

/* ---------------------------------------------------------------------------
 * Characteristic handlers
 * ------------------------------------------------------------------------- */

static int on_info(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[TANKLINK_INFO_LEN];
    return reply(ctxt, buf, gatt_payload_info(buf, gatt_svr_is_authed_conn(conn)));
}

/**
 * Claim the pump while its pairing window is open: makes a token for this
 * phone and notifies it. This is the one time a token goes over the air;
 * after that the phone signs in by answering the Auth challenge.
 */
static int on_pair(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    conn_slot_t *slot = slot_find(conn);
    if (!slot) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (!pump_pair_is_claimable()) {
        ESP_LOGW(TAG, "Claim rejected: hold the button 5 s to open pairing");
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    uint8_t token[TANKLINK_TOKEN_LEN];
    int phone = -1;
    const esp_err_t err = pump_pair_claim(token, &phone);
    if (err == ESP_ERR_NO_MEM) {
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (err != ESP_OK) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    slot->authed = true; /* the claiming phone is signed in */
    slot->phone = (int8_t)phone;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(token, sizeof(token));
    memset(token, 0, sizeof(token));
    if (!om) {
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    const int rc = ble_gatts_notify_custom(conn, s_pair_val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "pair notify failed rc=%d", rc);
    }
    return 0;
}

/**
 * Read: this connection's 16-byte nonce. Write: the phone's answer,
 * HMAC-SHA256(token, "TLauth" || nonce) first 16 bytes. The nonce changes
 * after every write, so a recorded answer is useless.
 */
static int on_auth(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    conn_slot_t *slot = slot_find(conn);
    if (!slot) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (is_read(ctxt)) {
        return reply(ctxt, slot->nonce, sizeof(slot->nonce));
    }
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t resp[TL_AUTH_RESP_LEN];
    uint16_t len = 0;
    const int rc = read_write(ctxt, resp, sizeof(resp), sizeof(resp), &len);
    if (rc != 0) {
        return rc;
    }
    const int phone = pump_pair_check_response(slot->nonce, resp);
    esp_fill_random(slot->nonce, sizeof(slot->nonce));
    slot->authed = phone >= 0;
    slot->phone = (int8_t)phone;
    ESP_LOGI(TAG, "Auth %s conn=%u phone=%d", phone >= 0 ? "OK" : "FAILED", conn, phone);
    return phone >= 0 ? 0 : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
}

static int on_state(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    const uint8_t on = pump_control_is_on() ? 1 : 0;
    return reply(ctxt, &on, 1);
}

/** Everything the app shows about tanks, after a sensor or slot change. */
static void notify_tank_change(void)
{
    lora_link_on_active_changed();
    gatt_svr_notify_tank();
    gatt_svr_notify_tanks();
    gatt_svr_notify_nodes();
}

/** Sensor index for a sensor_id(6) in a command, or -1. */
static int node_from_id(const uint8_t *body, uint16_t len, uint16_t at)
{
    if (len < at + TANKLINK_DEVICE_ID_LEN) {
        return -1;
    }
    return pump_tanks_node_find(&body[at]);
}

/** Runs one Cmd opcode from [slot]. [body] is the whole write, [len] at least 1. */
static int run_command(conn_slot_t *slot, const uint8_t *body, uint16_t len)
{
    status_led_notify_activity();
    switch (body[0]) {
    case TANKLINK_CMD_OFF:
    case TANKLINK_CMD_ON:
        pump_control_set(body[0] == TANKLINK_CMD_ON, PUMP_CAUSE_APP);
        return 0;

    case TANKLINK_CMD_UNPAIR:
        if (pump_pair_unpair() != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        clear_all_auth();
        pump_control_set(false, PUMP_CAUSE_SYSTEM);
        return 0;

    case TANKLINK_CMD_PAIRING_OPEN:
        /* The window switches the pump off; don't stop a fill from afar. */
        if (pump_control_is_on() || pump_ota_is_active()) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return pump_pair_enter_pairing_mode() == ESP_OK ? 0 : BLE_ATT_ERR_UNLIKELY;

    case TANKLINK_CMD_PAIRING_CLOSE:
        pump_pair_exit_pairing_mode();
        return 0;

    case TANKLINK_CMD_FORGET_OTHER_PHONES:
        if (pump_pair_forget_others(slot->phone) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
            if (s_conns[i].in_use && &s_conns[i] != slot && s_conns[i].authed) {
                sign_out(&s_conns[i]);
                ble_gap_terminate(s_conns[i].conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            }
        }
        return 0;

    case TANKLINK_CMD_TEST_BEEP:
        buzzer_play_user(true);
        return 0;

    case TANKLINK_CMD_TANK_PAIR:
        return lora_link_start_tank_pair(CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS) == ESP_OK
                   ? 0
                   : BLE_ATT_ERR_UNLIKELY;

    case TANKLINK_CMD_TANK_UNPAIR: {
        /* Refused while the pump fills one of that sensor's tanks. */
        const int node = node_from_id(body, len, 1);
        if (node < 0) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        return lora_link_unpair_node((uint8_t)node) == ESP_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
    }

    case TANKLINK_CMD_SENSOR_MODE: {
        const int node = node_from_id(body, len, 1);
        if (node < 0 || len < 1 + TANKLINK_DEVICE_ID_LEN + 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (pump_tanks_set_node_mode((uint8_t)node, body[1 + TANKLINK_DEVICE_ID_LEN],
                                     pump_control_is_on()) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        notify_tank_change();
        gatt_svr_notify_sched();
        return 0;
    }

    case TANKLINK_CMD_FACTORY_RESET:
        return pump_factory_reset() == ESP_OK ? 0 : BLE_ATT_ERR_UNLIKELY;

    case TANKLINK_CMD_CLEAR_ERROR:
        pump_control_clear_error();
        return 0;

    case TANKLINK_CMD_DISMISS_INTERRUPT:
        pump_runlog_clear_event();
        gatt_svr_notify_tank();
        return 0;

    case TANKLINK_CMD_TANK_SELECT:
        if (len < 2) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (pump_tanks_select(body[1], pump_control_is_on()) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        notify_tank_change();
        return 0;

    case TANKLINK_CMD_TANK_RENAME:
        if (len < 3) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (pump_tanks_rename(body[1], &body[2], len - 2) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        gatt_svr_notify_tanks();
        return 0;

    case TANKLINK_CMD_TANK_AUTO_FILL:
        if (len < 3) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (pump_tanks_set_auto_fill(body[1], body[2] != 0) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        gatt_svr_notify_tanks();
        return 0;

    case TANKLINK_CMD_USAGE: {
        if (len < 1 + TANKLINK_USAGE_LEN) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        pump_usage_t u;
        memset(&u, 0, sizeof(u));
        u.flow_dlpm = (uint16_t)(body[1] | (body[2] << 8));
        u.watts = (uint16_t)(body[3] | (body[4] << 8));
        u.price_centi = (uint16_t)(body[5] | (body[6] << 8));
        memcpy(u.currency, &body[7], PUMP_USAGE_CURRENCY_LEN);
        return pump_config_set_usage(&u) == ESP_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
    }

    case TANKLINK_CMD_TANK_AUTO_OFF:
        if (len < 3) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        if (pump_tanks_set_auto_off(body[1], body[2]) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        gatt_svr_notify_tanks();
        return 0;

    default:
        ESP_LOGW(TAG, "Unknown command 0x%02x", body[0]);
        return BLE_ATT_ERR_UNLIKELY;
    }
}

static int on_cmd(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    conn_slot_t *slot = slot_find(conn);
    if (!slot || !slot->authed) {
        ESP_LOGW(TAG, "Cmd rejected: conn=%u not signed in", conn);
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    /* Longest command: rename = opcode + slot + name (sensor mode is 8). */
    uint8_t body[1 + 1 + PUMP_TANK_NAME_LEN];
    _Static_assert(sizeof(body) >= 1 + TANKLINK_DEVICE_ID_LEN + 1, "Cmd buffer");
    uint16_t len = 0;
    const int rc = read_write(ctxt, body, sizeof(body), 1, &len);
    return rc != 0 ? rc : run_command(slot, body, len);
}

static int on_settings(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                       void *arg)
{
    if (is_read(ctxt)) {
        uint8_t buf[GATT_SETTINGS_READ_LEN];
        return reply(ctxt, buf, gatt_payload_settings(buf));
    }
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (!gatt_svr_is_authed_conn(conn)) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    /* buzzer_flags tone led starter pulse_ms(u16). A newer app may append
     * fields (protocol minor); they are ignored. */
    uint8_t buf[TANKLINK_SETTINGS_WRITE_LEN + 16];
    uint16_t len = 0;
    const int rc = read_write(ctxt, buf, sizeof(buf), TANKLINK_SETTINGS_WRITE_LEN, &len);
    if (rc != 0) {
        return rc;
    }
    const uint16_t pulse = (uint16_t)buf[4] | ((uint16_t)buf[5] << 8);
    if (pump_config_set_buzzer(buf[0], buf[1]) != ESP_OK ||
        pump_config_set_led_brightness(buf[2]) != ESP_OK ||
        pump_config_set_starter_type(buf[3]) != ESP_OK ||
        pump_config_set_relay_pulse_ms(pulse) != ESP_OK) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    ESP_LOGI(TAG, "settings buzz=0x%02x tone=%u led=%u starter=%u pulse=%ums", buf[0],
             buf[1], buf[2], buf[3], (unsigned)pulse);
    return 0;
}

static int on_tank(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    /* Carries the selected sensor's BLE OTA token: signed-in phones only. */
    if (!gatt_svr_is_authed_conn(conn)) {
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[TANKLINK_TANK_STATUS_LEN];
    return reply(ctxt, buf, gatt_payload_tank_status(buf));
}

/** Set-clock write: year(u16) month day hour minute second. */
static int set_clock(const uint8_t *buf, uint16_t len)
{
    if (len < 8) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    const int year = (int)buf[1] | ((int)buf[2] << 8);
    int64_t before = 0;
    const bool had_time = pump_clock_unix_now(&before);
    if (pump_clock_set(year, buf[3], buf[4], buf[5], buf[6], buf[7]) != ESP_OK) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    /* The app re-syncs every 15 min. Keep "already started today" marks
     * across small corrections, or a sync inside a schedule's minute would
     * start the pump again. Clear them on a real jump. */
    int64_t after = 0;
    (void)pump_clock_unix_now(&after);
    const int64_t delta = after - before;
    if (!had_time || delta > 300 || delta < -300) {
        pump_sched_clear_fired();
    }
    ESP_LOGI(TAG, "clock set %04d-%02u-%02u %02u:%02u:%02u", year, buf[3], buf[4], buf[5],
             buf[6], buf[7]);
    return 0;
}

/** Replace-list write: count, then count × (enabled hour minute slot). */
static int set_schedules(const uint8_t *buf, uint16_t len)
{
    if (len < 2) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    const unsigned count = buf[1];
    if (count > PUMP_SCHED_MAX || len < 2 + count * 4) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    pump_sched_entry_t entries[PUMP_SCHED_MAX];
    memset(entries, 0, sizeof(entries));
    const uint8_t *e = &buf[2];
    for (unsigned i = 0; i < count; i++, e += 4) {
        entries[i].enabled = e[0] ? 1 : 0;
        entries[i].hour = e[1];
        entries[i].minute = e[2];
        entries[i].slot = e[3];
    }
    return pump_sched_set(entries, count) == ESP_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
}

static int on_sched(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!gatt_svr_is_authed_conn(conn)) {
        return is_read(ctxt) ? BLE_ATT_ERR_READ_NOT_PERMITTED : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    if (is_read(ctxt)) {
        uint8_t buf[GATT_SCHED_MAX_LEN];
        return reply(ctxt, buf, gatt_payload_sched(buf));
    }
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[2 + PUMP_SCHED_MAX * 4];
    uint16_t len = 0;
    int rc = read_write(ctxt, buf, sizeof(buf), 1, &len);
    if (rc != 0) {
        return rc;
    }
    switch (buf[0]) {
    case TANKLINK_SCHED_OP_SET_CLOCK:
        rc = set_clock(buf, len);
        break;
    case TANKLINK_SCHED_OP_SET_LIST:
        rc = set_schedules(buf, len);
        break;
    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (rc == 0) {
        gatt_svr_notify_sched();
    }
    return rc;
}

static int on_tanks(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!gatt_svr_is_authed_conn(conn)) {
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[GATT_TANKS_MAX_LEN];
    return reply(ctxt, buf, gatt_payload_tanks(buf));
}

static int on_nodes(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!gatt_svr_is_authed_conn(conn)) {
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[GATT_NODES_MAX_LEN];
    return reply(ctxt, buf, gatt_payload_nodes(buf));
}

/** Read: one page of fills from this connection's start. Write: start(1). */
static int on_history(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                      void *arg)
{
    conn_slot_t *slot = slot_find(conn);
    if (!slot || !slot->authed) {
        return is_read(ctxt) ? BLE_ATT_ERR_READ_NOT_PERMITTED : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }
    if (is_write(ctxt)) {
        uint8_t start = 0;
        uint16_t len = 0;
        const int rc = read_write(ctxt, &start, 1, 1, &len);
        if (rc != 0) {
            return rc;
        }
        slot->history_start = start;
        return 0;
    }
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[GATT_HISTORY_MAX_LEN];
    return reply(ctxt, buf, gatt_payload_history(buf, slot->history_start));
}

static int on_battery(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                      void *arg)
{
    if (!gatt_svr_is_authed_conn(conn)) {
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[GATT_BATTERY_MAX_LEN];
    return reply(ctxt, buf, gatt_payload_battery(buf));
}

static int on_ota_status(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                         void *arg)
{
    if (!is_read(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[GATT_OTA_STATUS_LEN];
    return reply(ctxt, buf, gatt_payload_ota_status(buf));
}

/** OtaCtrl: start(size, sha256) / abort / finish. Frozen layout. */
static int on_ota_ctrl(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                       void *arg)
{
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    uint8_t buf[1 + 4 + 32];
    uint16_t len = 0;
    const int rc = read_write(ctxt, buf, sizeof(buf), 1, &len);
    if (rc != 0) {
        return rc;
    }
    uint8_t err;
    switch (buf[0]) {
    case TANKLINK_OTA_OP_START:
        if (len != sizeof(buf)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        err = pump_ota_start(conn, get_u32(&buf[1]), &buf[5]);
        break;
    case TANKLINK_OTA_OP_ABORT:
        err = pump_ota_abort_from(conn);
        break;
    case TANKLINK_OTA_OP_FINISH:
        err = pump_ota_finish(conn);
        break;
    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
    notify_ota_status();
    return err == TANKLINK_OTA_ERR_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
}

/** OtaData: offset(u32) + payload, 512 bytes at most. Frozen layout. */
static int on_ota_data(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt,
                       void *arg)
{
    if (!is_write(ctxt)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    static uint8_t buf[512]; /* NimBLE host task only: not re-entered */
    uint16_t len = 0;
    const int rc = read_write(ctxt, buf, sizeof(buf), 5, &len);
    if (rc != 0) {
        return rc;
    }
    const uint8_t err = pump_ota_write(conn, get_u32(buf), &buf[4], (uint16_t)(len - 4));
    return err == TANKLINK_OTA_ERR_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
}

/* ---------------------------------------------------------------------------
 * Service table
 * ------------------------------------------------------------------------- */

static const ble_uuid128_t uuid_svc = TANKLINK_SVC_UUID_INIT;
static const ble_uuid128_t uuid_info = TANKLINK_CHR_INFO_INIT;
static const ble_uuid128_t uuid_pair = TANKLINK_CHR_PAIR_INIT;
static const ble_uuid128_t uuid_auth = TANKLINK_CHR_AUTH_INIT;
static const ble_uuid128_t uuid_state = TANKLINK_CHR_STATE_INIT;
static const ble_uuid128_t uuid_cmd = TANKLINK_CHR_CMD_INIT;
static const ble_uuid128_t uuid_settings = TANKLINK_CHR_SETTINGS_INIT;
static const ble_uuid128_t uuid_ota_ctrl = TANKLINK_CHR_OTA_CTRL_INIT;
static const ble_uuid128_t uuid_ota_data = TANKLINK_CHR_OTA_DATA_INIT;
static const ble_uuid128_t uuid_ota_status = TANKLINK_CHR_OTA_STATUS_INIT;
static const ble_uuid128_t uuid_tank = TANKLINK_CHR_TANK_INIT;
static const ble_uuid128_t uuid_sched = TANKLINK_CHR_SCHED_INIT;
static const ble_uuid128_t uuid_tanks = TANKLINK_CHR_TANKS_INIT;
static const ble_uuid128_t uuid_nodes = TANKLINK_CHR_NODES_INIT;
static const ble_uuid128_t uuid_history = TANKLINK_CHR_HISTORY_INIT;
static const ble_uuid128_t uuid_battery = TANKLINK_CHR_BATTERY_INIT;

#define F_R BLE_GATT_CHR_F_READ
#define F_W BLE_GATT_CHR_F_WRITE
#define F_N BLE_GATT_CHR_F_NOTIFY

static const struct ble_gatt_svc_def s_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &uuid_svc.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {.uuid = &uuid_info.u, .access_cb = on_info, .flags = F_R},
            {.uuid = &uuid_pair.u, .access_cb = on_pair, .flags = F_W | F_N,
             .val_handle = &s_pair_val_handle},
            {.uuid = &uuid_auth.u, .access_cb = on_auth, .flags = F_R | F_W},
            {.uuid = &uuid_state.u, .access_cb = on_state, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_STATE]},
            {.uuid = &uuid_cmd.u, .access_cb = on_cmd, .flags = F_W},
            {.uuid = &uuid_settings.u, .access_cb = on_settings, .flags = F_R | F_W},
            {.uuid = &uuid_ota_ctrl.u, .access_cb = on_ota_ctrl, .flags = F_W},
            {.uuid = &uuid_ota_data.u, .access_cb = on_ota_data,
             .flags = F_W | BLE_GATT_CHR_F_WRITE_NO_RSP},
            {.uuid = &uuid_ota_status.u, .access_cb = on_ota_status, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_OTA_STATUS]},
            {.uuid = &uuid_tank.u, .access_cb = on_tank, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_TANK]},
            {.uuid = &uuid_sched.u, .access_cb = on_sched, .flags = F_R | F_W | F_N,
             .val_handle = &s_val_handle[SUB_SCHED]},
            {.uuid = &uuid_tanks.u, .access_cb = on_tanks, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_TANKS]},
            {.uuid = &uuid_nodes.u, .access_cb = on_nodes, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_NODES]},
            {.uuid = &uuid_history.u, .access_cb = on_history, .flags = F_R | F_W | F_N,
             .val_handle = &s_val_handle[SUB_HISTORY]},
            {.uuid = &uuid_battery.u, .access_cb = on_battery, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_BATTERY]},
            {0},
        },
    },
    {0},
};

/* ---------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */

void gatt_svr_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg)
{
    char buf[BLE_UUID_STR_LEN];
    if (ctxt->op == BLE_GATT_REGISTER_OP_SVC) {
        ESP_LOGI(TAG, "svc %s handle=%d", ble_uuid_to_str(ctxt->svc.svc_def->uuid, buf),
                 ctxt->svc.handle);
    } else if (ctxt->op == BLE_GATT_REGISTER_OP_CHR) {
        ESP_LOGI(TAG, "chr %s val_handle=%d", ble_uuid_to_str(ctxt->chr.chr_def->uuid, buf),
                 ctxt->chr.val_handle);
    }
}

int gatt_svr_init(void)
{
    memset(s_conns, 0, sizeof(s_conns));
    ble_svc_gap_init();
    ble_svc_gatt_init();
    pump_ota_set_status_cb(notify_ota_status);
    const int rc = ble_gatts_count_cfg(s_services);
    return rc != 0 ? rc : ble_gatts_add_svcs(s_services);
}

void gatt_svr_on_connect(uint16_t conn_handle)
{
    if (!slot_alloc(conn_handle)) {
        ESP_LOGW(TAG, "conn table full, rejecting handle=%u", conn_handle);
        ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        return;
    }
    const int count = gatt_svr_conn_count();
    ESP_LOGI(TAG, "conn add handle=%u count=%d", conn_handle, count);
    if (count == 1) {
        /* First phone: a short accent pulse, then back to idle. */
        status_led_notify_ble_connect();
    }
    pump_control_refresh_idle_led();
}

void gatt_svr_on_disconnect(uint16_t conn_handle)
{
    pump_ota_on_disconnect(conn_handle);
    conn_slot_t *slot = slot_find(conn_handle);
    if (slot) {
        memset(slot, 0, sizeof(*slot));
    }
    ESP_LOGI(TAG, "conn drop handle=%u count=%d", conn_handle, gatt_svr_conn_count());
    pump_diag_request();
    pump_control_refresh_idle_led();
}

void gatt_svr_on_subscribe(uint16_t conn_handle, uint16_t attr_handle, bool notify_enabled)
{
    conn_slot_t *slot = slot_find(conn_handle);
    if (!slot) {
        return;
    }
    for (int s = 0; s < SUB_COUNT; s++) {
        if (attr_handle == s_val_handle[s]) {
            slot->subscribed[s] = notify_enabled;
        }
    }
}

int gatt_svr_conn_count(void)
{
    int n = 0;
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        n += s_conns[i].in_use ? 1 : 0;
    }
    return n;
}

bool gatt_svr_is_authed_conn(uint16_t conn_handle)
{
    const conn_slot_t *slot = slot_find(conn_handle);
    return slot && slot->authed;
}
