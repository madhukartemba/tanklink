/*
 * The pump's BLE GATT service: the characteristic table, the connection
 * table, Pair (the one BLE-only characteristic) and notifications. Every
 * other characteristic is served by pump_api.c, shared with the Wi-Fi
 * transport; docs/PROTOCOL.md describes them all.
 */
#include "gatt_svr.h"

#include <string.h>

#include "esp_log.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "sdkconfig.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "gatt_payloads.h"
#include "pump_alert.h"
#include "pump_api.h"
#include "pump_control.h"
#include "pump_diag.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "pump_wifi_api.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "GATT_SVR"

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
    SUB_WIFI,
    SUB_ALERTS,
    SUB_SETTINGS,
    SUB_COUNT,
} sub_t;

/** The characteristic id (UUID suffix) each subscription notifies. */
static const uint8_t s_sub_chr[SUB_COUNT] = {
    [SUB_STATE] = PUMP_API_CHR_STATE,     [SUB_OTA_STATUS] = PUMP_API_CHR_OTA_STATUS,
    [SUB_TANK] = PUMP_API_CHR_TANK,       [SUB_SCHED] = PUMP_API_CHR_SCHED,
    [SUB_TANKS] = PUMP_API_CHR_TANKS,     [SUB_NODES] = PUMP_API_CHR_NODES,
    [SUB_HISTORY] = PUMP_API_CHR_HISTORY, [SUB_BATTERY] = PUMP_API_CHR_BATTERY,
    [SUB_WIFI] = PUMP_API_CHR_WIFI,
    [SUB_ALERTS] = PUMP_API_CHR_ALERT_LOG,
    [SUB_SETTINGS] = PUMP_API_CHR_SETTINGS,
};

typedef struct {
    bool in_use;
    pump_api_session_t api; /* api.id is the connection handle */
    bool subscribed[SUB_COUNT];
} conn_slot_t;

static conn_slot_t s_conns[TANKLINK_MAX_BLE_CONN];

static uint16_t s_pair_val_handle;
static uint16_t s_val_handle[SUB_COUNT];

static conn_slot_t *slot_find(uint16_t conn_handle)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (s_conns[i].in_use && s_conns[i].api.id == conn_handle) {
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
            pump_api_session_init(&s_conns[i].api, conn_handle);
            return &s_conns[i];
        }
    }
    return NULL;
}

void gatt_svr_sign_out_all(void)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        pump_api_session_sign_out(&s_conns[i].api);
    }
}

void gatt_svr_drop_others(uint16_t keep_id)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (s_conns[i].in_use && s_conns[i].api.id != keep_id && s_conns[i].api.authed) {
            pump_api_session_sign_out(&s_conns[i].api);
            ble_gap_terminate(s_conns[i].api.id, BLE_ERR_REM_USER_CONN_TERM);
        }
    }
}

void gatt_svr_drop(uint16_t conn_handle)
{
    ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
}

/** Send [buf] to every BLE connection subscribed to [sub] and to every
 * Wi-Fi client (signed in, if it needs it). */
static void notify_all(sub_t sub, const uint8_t *buf, size_t len)
{
    pump_wifi_api_notify(s_sub_chr[sub], buf, len);
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (!s_conns[i].in_use || !s_conns[i].subscribed[sub]) {
            continue;
        }
        if (pump_api_chr_notify_needs_auth(s_sub_chr[sub]) && !s_conns[i].api.authed) {
            continue;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, len);
        if (!om) {
            continue;
        }
        const int rc = ble_gatts_notify_custom(s_conns[i].api.id, s_val_handle[sub], om);
        if (rc != 0) {
            ESP_LOGW(TAG, "notify %d conn=%u rc=%d", sub, s_conns[i].api.id, rc);
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

void gatt_svr_notify_settings(void)
{
    uint8_t buf[GATT_SETTINGS_READ_LEN];
    notify_all(SUB_SETTINGS, buf, gatt_payload_settings(buf));
}

void gatt_svr_notify_alerts(void)
{
    uint8_t buf[PUMP_ALERT_LOG_MAX_LEN];
    notify_all(SUB_ALERTS, buf, pump_alert_log_payload(buf));
}

void gatt_svr_notify_wifi(void)
{
    uint8_t buf[GATT_WIFI_STATUS_MAX_LEN];
    notify_all(SUB_WIFI, buf, gatt_payload_wifi_status(buf));
}

void gatt_svr_notify_ota_status(void)
{
    uint8_t buf[GATT_OTA_STATUS_LEN];
    notify_all(SUB_OTA_STATUS, buf, gatt_payload_ota_status(buf));
}

/* ---------------------------------------------------------------------------
 * Characteristic access: Pair here, everything else through pump_api
 * ------------------------------------------------------------------------- */

static int att_error(pump_api_err_t err, bool is_read)
{
    switch (err) {
    case PUMP_API_OK:
        return 0;
    case PUMP_API_ERR_NOT_AUTH:
        return is_read ? BLE_ATT_ERR_READ_NOT_PERMITTED : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    case PUMP_API_ERR_LEN:
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    case PUMP_API_ERR_NO_MEM:
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

/**
 * Claim the pump while its pairing window is open: makes a token for this
 * phone and notifies it. This is the one time a token goes over the air;
 * after that the phone signs in by answering the Auth challenge. BLE only,
 * so nobody on the Wi-Fi network can claim a pump.
 */
static int on_pair(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
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
    slot->api.authed = true; /* the claiming phone is signed in */
    slot->api.phone = (int8_t)phone;
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

/** Every other characteristic: [arg] is its id. */
static int on_chr(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    const uint8_t chr = (uint8_t)(uintptr_t)arg;
    conn_slot_t *slot = slot_find(conn);
    if (!slot) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        static uint8_t out[PUMP_API_READ_MAX]; /* NimBLE host task only */
        size_t len = 0;
        const pump_api_err_t err = pump_api_read(&slot->api, chr, out, &len);
        if (err != PUMP_API_OK) {
            return att_error(err, true);
        }
        return os_mbuf_append(ctxt->om, out, len) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    static uint8_t in[512]; /* NimBLE host task only: not re-entered */
    const uint16_t n = OS_MBUF_PKTLEN(ctxt->om);
    if (n > sizeof(in)) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (ble_hs_mbuf_to_flat(ctxt->om, in, n, NULL) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    return att_error(pump_api_write(&slot->api, chr, in, n), false);
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
static const ble_uuid128_t uuid_wifi = TANKLINK_CHR_WIFI_INIT;
static const ble_uuid128_t uuid_alert_key = TANKLINK_CHR_ALERT_KEY_INIT;
static const ble_uuid128_t uuid_alert_log = TANKLINK_CHR_ALERT_LOG_INIT;

#define F_R BLE_GATT_CHR_F_READ
#define F_W BLE_GATT_CHR_F_WRITE
#define F_N BLE_GATT_CHR_F_NOTIFY

static const struct ble_gatt_svc_def s_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &uuid_svc.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {.uuid = &uuid_info.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_INFO, .flags = F_R},
            {.uuid = &uuid_pair.u, .access_cb = on_pair, .arg = (void *)(uintptr_t)PUMP_API_CHR_PAIR, .flags = F_W | F_N,
             .val_handle = &s_pair_val_handle},
            {.uuid = &uuid_auth.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_AUTH, .flags = F_R | F_W},
            {.uuid = &uuid_state.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_STATE, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_STATE]},
            {.uuid = &uuid_cmd.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_CMD, .flags = F_W},
            {.uuid = &uuid_settings.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_SETTINGS, .flags = F_R | F_W | F_N,
             .val_handle = &s_val_handle[SUB_SETTINGS]},
            {.uuid = &uuid_ota_ctrl.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_OTA_CTRL, .flags = F_W},
            {.uuid = &uuid_ota_data.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_OTA_DATA,
             .flags = F_W | BLE_GATT_CHR_F_WRITE_NO_RSP},
            {.uuid = &uuid_ota_status.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_OTA_STATUS, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_OTA_STATUS]},
            {.uuid = &uuid_tank.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_TANK, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_TANK]},
            {.uuid = &uuid_sched.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_SCHED, .flags = F_R | F_W | F_N,
             .val_handle = &s_val_handle[SUB_SCHED]},
            {.uuid = &uuid_tanks.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_TANKS, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_TANKS]},
            {.uuid = &uuid_nodes.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_NODES, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_NODES]},
            {.uuid = &uuid_history.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_HISTORY, .flags = F_R | F_W | F_N,
             .val_handle = &s_val_handle[SUB_HISTORY]},
            {.uuid = &uuid_battery.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_BATTERY, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_BATTERY]},
            {.uuid = &uuid_wifi.u, .access_cb = on_chr, .arg = (void *)(uintptr_t)PUMP_API_CHR_WIFI, .flags = F_R | F_W | F_N,
             .val_handle = &s_val_handle[SUB_WIFI]},
            {.uuid = &uuid_alert_key.u, .access_cb = on_chr,
             .arg = (void *)(uintptr_t)PUMP_API_CHR_ALERT_KEY, .flags = F_R},
            {.uuid = &uuid_alert_log.u, .access_cb = on_chr,
             .arg = (void *)(uintptr_t)PUMP_API_CHR_ALERT_LOG, .flags = F_R | F_N,
             .val_handle = &s_val_handle[SUB_ALERTS]},
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
    pump_api_init();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    pump_ota_set_status_cb(gatt_svr_notify_ota_status);
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
    return slot && slot->api.authed;
}
