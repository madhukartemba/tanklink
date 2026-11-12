#include "gatt_svr.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "sdkconfig.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "board.h"
#include "buzzer.h"
#include "lora_link.h"
#include "pump_config.h"
#include "pump_errors.h"
#include "pump_factory.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "relay_control.h"
#include "status_led.h"
#include "tanklink_lora_proto.h"
#include "tanklink_uuid.h"

#define TAG "GATT_SVR"

typedef struct {
    uint16_t conn_handle;
    bool in_use;
    bool authed;
    bool state_notify;
    bool ota_status_notify;
    bool tank_notify;
} conn_slot_t;

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

static conn_slot_t s_conns[TANKLINK_MAX_BLE_CONN];
static uint16_t s_pair_val_handle;
static uint16_t s_state_val_handle;
static uint16_t s_ota_status_val_handle;
static uint16_t s_tank_val_handle;
static uint8_t s_pump_on;
static int64_t s_pump_on_since_us;
static uint8_t s_last_error;

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg);

static const struct ble_gatt_svc_def gatt_svr_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &uuid_svc.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &uuid_info.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_READ,
            },
            {
                .uuid = &uuid_pair.u,
                .access_cb = chr_access,
                .val_handle = &s_pair_val_handle,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
            },
            {
                .uuid = &uuid_auth.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &uuid_state.u,
                .access_cb = chr_access,
                .val_handle = &s_state_val_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            {
                .uuid = &uuid_cmd.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &uuid_settings.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &uuid_ota_ctrl.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &uuid_ota_data.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &uuid_ota_status.u,
                .access_cb = chr_access,
                .val_handle = &s_ota_status_val_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            {
                .uuid = &uuid_tank.u,
                .access_cb = chr_access,
                .val_handle = &s_tank_val_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 },
        },
    },
    { 0 },
};

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
            return &s_conns[i];
        }
    }
    return NULL;
}

static void clear_all_auth(void)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        s_conns[i].authed = false;
    }
}

static void append_ota_status(uint8_t *out6)
{
    uint32_t off = pump_ota_offset();
    out6[0] = pump_ota_state();
    out6[1] = pump_ota_last_error();
    out6[2] = (uint8_t)(off & 0xff);
    out6[3] = (uint8_t)((off >> 8) & 0xff);
    out6[4] = (uint8_t)((off >> 16) & 0xff);
    out6[5] = (uint8_t)((off >> 24) & 0xff);
}

static void ota_status_notify(void)
{
    uint8_t buf[6];
    append_ota_status(buf);
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (!s_conns[i].in_use || !s_conns[i].ota_status_notify) {
            continue;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof(buf));
        if (!om) {
            continue;
        }
        int rc = ble_gatts_notify_custom(s_conns[i].conn_handle, s_ota_status_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "ota status notify conn=%u rc=%d", s_conns[i].conn_handle, rc);
        }
    }
}

static int append_info(struct os_mbuf *om, uint16_t conn_handle)
{
    /* paired(1) + device_id(6) + fw\0 + auto_off_min(1) + flags(1) + run_secs(u32 LE) */
    uint8_t paired = pump_pair_is_paired() ? 1 : 0;
    int rc = os_mbuf_append(om, &paired, 1);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, pump_pair_device_id(), TANKLINK_DEVICE_ID_LEN);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, TANKLINK_FW_VERSION, strlen(TANKLINK_FW_VERSION) + 1);
    if (rc != 0) {
        return rc;
    }
    uint8_t auto_off = pump_config_auto_off_min();
    uint8_t flags = 0;
    if (pump_pair_pairing_active()) {
        flags |= 0x01;
    }
    if (gatt_svr_is_authed_conn(conn_handle)) {
        flags |= 0x02;
    }
    rc = os_mbuf_append(om, &auto_off, 1);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, &flags, 1);
    if (rc != 0) {
        return rc;
    }
    uint32_t run = gatt_svr_run_seconds();
    uint8_t run_le[4] = {
        (uint8_t)(run & 0xff),
        (uint8_t)((run >> 8) & 0xff),
        (uint8_t)((run >> 16) & 0xff),
        (uint8_t)((run >> 24) & 0xff),
    };
    return os_mbuf_append(om, run_le, 4);
}

static void fill_tank_status(uint8_t out[TANKLINK_TANK_STATUS_LEN])
{
    memset(out, 0, TANKLINK_TANK_STATUS_LEN);
    out[0] = lora_link_tank_bound() ? 1 : 0;
    out[1] = lora_link_tank_pairing_active() ? 1 : 0;
    memcpy(&out[2], lora_link_tank_id(), TANKLINK_DEVICE_ID_LEN);
    out[8] = lora_link_tank_fw_major();
    out[9] = lora_link_tank_fw_minor();
    out[10] = lora_link_tank_fw_patch();
    out[11] = lora_link_tank_flags();
    out[12] = lora_link_tank_battery_pct();
    out[13] = lora_link_tank_online() ? 1 : 0;
    uint16_t age = lora_link_tank_age_sec();
    out[14] = (uint8_t)(age & 0xff);
    out[15] = (uint8_t)((age >> 8) & 0xff);
    int16_t rssi = lora_link_tank_rssi_dbm();
    if (rssi < -128) {
        rssi = -128;
    }
    if (rssi > 127) {
        rssi = 127;
    }
    out[16] = (uint8_t)(int8_t)rssi;
    out[17] = (uint8_t)lora_link_tank_snr_db();
    out[18] = s_last_error;
    if (lora_link_tank_has_ble_token()) {
        memcpy(&out[19], lora_link_tank_ble_token(), TANKLINK_TOKEN_LEN);
    }
}

static int append_tank_status(struct os_mbuf *om)
{
    uint8_t buf[TANKLINK_TANK_STATUS_LEN];
    fill_tank_status(buf);
    return os_mbuf_append(om, buf, sizeof(buf));
}

static int append_settings(struct os_mbuf *om)
{
    /* auto_off(1)+run(4)+serial(5)+buzz(1)+tone(1)+led(1)+starter(1)+pulse_ms(2 LE) */
    uint8_t auto_off = pump_config_auto_off_min();
    int rc = os_mbuf_append(om, &auto_off, 1);
    if (rc != 0) {
        return rc;
    }
    uint32_t run = gatt_svr_run_seconds();
    uint8_t run_le[4] = {
        (uint8_t)(run & 0xff),
        (uint8_t)((run >> 8) & 0xff),
        (uint8_t)((run >> 16) & 0xff),
        (uint8_t)((run >> 24) & 0xff),
    };
    rc = os_mbuf_append(om, run_le, 4);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, pump_pair_serial(), TANKLINK_SERIAL_LEN + 1);
    if (rc != 0) {
        return rc;
    }
    uint8_t buzz_flags = pump_config_buzzer_flags();
    uint8_t tone = pump_config_buzzer_tone();
    uint8_t led_bri = pump_config_led_brightness();
    uint8_t starter = pump_config_starter_type();
    uint16_t pulse = pump_config_relay_pulse_ms();
    uint8_t pulse_le[2] = {
        (uint8_t)(pulse & 0xff),
        (uint8_t)((pulse >> 8) & 0xff),
    };
    rc = os_mbuf_append(om, &buzz_flags, 1);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, &tone, 1);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, &led_bri, 1);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, &starter, 1);
    if (rc != 0) {
        return rc;
    }
    return os_mbuf_append(om, pulse_le, 2);
}

static void refresh_connected_led(void)
{
    status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_HOLD_PROGRESS || mode == STATUS_LED_PAIRING ||
        mode == STATUS_LED_TANK_PAIRING || mode == STATUS_LED_UNPAIRED ||
        mode == STATUS_LED_PUMP_ON || mode == STATUS_LED_UPDATING ||
        mode == STATUS_LED_UPDATE_OK || mode == STATUS_LED_UPDATE_ERR) {
        return;
    }
    /* Standby always — tank-full color lives in the idle glow; no connected anim. */
    if (!s_pump_on) {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;

    const ble_uuid_t *uuid = ctxt->chr->uuid;
    conn_slot_t *slot = slot_find(conn_handle);

    if (ble_uuid_cmp(uuid, &uuid_info.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return append_info(ctxt->om, conn_handle) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &uuid_pair.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (!pump_pair_is_claimable()) {
            ESP_LOGW(TAG, "Claim rejected — hold Start+Stop 5s to enter pairing");
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        uint8_t token[TANKLINK_TOKEN_LEN];
        if (pump_pair_claim(token) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (slot) {
            slot->authed = true; /* claimer is authenticated for this connection */
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(token, sizeof(token));
        if (!om) {
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        int rc = ble_gatts_notify_custom(conn_handle, s_pair_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "pair notify failed rc=%d", rc);
        }
        return 0;
    }

    if (ble_uuid_cmp(uuid, &uuid_auth.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len != TANKLINK_TOKEN_LEN) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t token[TANKLINK_TOKEN_LEN];
        int rc = ble_hs_mbuf_to_flat(ctxt->om, token, sizeof(token), NULL);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        bool ok = pump_pair_check_token(token, sizeof(token));
        if (slot) {
            slot->authed = ok;
        }
        ESP_LOGI(TAG, "Auth %s conn=%u", ok ? "OK" : "FAILED", conn_handle);
        return ok ? 0 : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    if (ble_uuid_cmp(uuid, &uuid_state.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return os_mbuf_append(ctxt->om, &s_pump_on, 1) == 0 ? 0
                                                            : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &uuid_cmd.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (!gatt_svr_is_authed_conn(conn_handle)) {
            ESP_LOGW(TAG, "Cmd rejected — not authenticated conn=%u", conn_handle);
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len < 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t cmd = 0;
        int rc = ble_hs_mbuf_to_flat(ctxt->om, &cmd, 1, NULL);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (cmd == TANKLINK_CMD_UNPAIR) {
            if (pump_pair_unpair() != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            clear_all_auth();
            gatt_svr_set_pump_state(0);
            return 0;
        }
        if (cmd == TANKLINK_CMD_TEST_BEEP) {
            buzzer_play_user(true);
            return 0;
        }
        if (cmd == TANKLINK_CMD_TANK_PAIR) {
#ifndef CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS
#define CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS 60000
#endif
            if (lora_link_start_tank_pair(CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS) != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            return 0;
        }
        if (cmd == TANKLINK_CMD_TANK_UNPAIR) {
            if (lora_link_unpair_tank() != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            return 0;
        }
        if (cmd == TANKLINK_CMD_FACTORY_RESET) {
            if (pump_factory_reset() != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            return 0;
        }
        if (cmd == TANKLINK_CMD_CLEAR_ERROR) {
            gatt_svr_clear_last_error();
            return 0;
        }
        gatt_svr_set_pump_state(cmd ? 1 : 0);
        return 0;
    }

    if (ble_uuid_cmp(uuid, &uuid_tank.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return append_tank_status(ctxt->om) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &uuid_settings.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            return append_settings(ctxt->om) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (!gatt_svr_is_authed_conn(conn_handle)) {
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len < 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t buf[7] = {0};
        uint16_t copy = len > sizeof(buf) ? sizeof(buf) : len;
        int rc = ble_hs_mbuf_to_flat(ctxt->om, buf, copy, NULL);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (pump_config_set_auto_off_min(buf[0]) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (len >= 3) {
            if (pump_config_set_buzzer(buf[1], buf[2]) != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            ESP_LOGI(TAG, "buzzer flags=0x%02x tone=%u", buf[1], buf[2]);
        }
        if (len >= 4) {
            if (pump_config_set_led_brightness(buf[3]) != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            ESP_LOGI(TAG, "led brightness=%u", buf[3]);
        }
        if (len >= 5) {
            if (pump_config_set_starter_type(buf[4]) != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            ESP_LOGI(TAG, "starter type=%u", buf[4]);
        }
        if (len >= 7) {
            uint16_t pulse = (uint16_t)buf[5] | ((uint16_t)buf[6] << 8);
            if (pump_config_set_relay_pulse_ms(pulse) != ESP_OK) {
                return BLE_ATT_ERR_UNLIKELY;
            }
            ESP_LOGI(TAG, "relay pulse=%ums", (unsigned)pulse);
        }
        ESP_LOGI(TAG, "auto-off set to %u min", buf[0]);
        return 0;
    }

    if (ble_uuid_cmp(uuid, &uuid_ota_status.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint8_t buf[6];
        append_ota_status(buf);
        return os_mbuf_append(ctxt->om, buf, sizeof(buf)) == 0 ? 0
                                                               : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &uuid_ota_ctrl.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len < 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t buf[1 + 4 + 32];
        if (len > sizeof(buf)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        int rc = ble_hs_mbuf_to_flat(ctxt->om, buf, len, NULL);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint8_t op = buf[0];
        uint8_t ota_err = TANKLINK_OTA_ERR_OK;
        if (op == TANKLINK_OTA_OP_START) {
            if (len != 1 + 4 + 32) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            uint32_t size = (uint32_t)buf[1] | ((uint32_t)buf[2] << 8) |
                            ((uint32_t)buf[3] << 16) | ((uint32_t)buf[4] << 24);
            ota_err = pump_ota_start(conn_handle, size, &buf[5]);
        } else if (op == TANKLINK_OTA_OP_ABORT) {
            ota_err = pump_ota_abort_from(conn_handle);
        } else if (op == TANKLINK_OTA_OP_FINISH) {
            ota_err = pump_ota_finish(conn_handle);
        } else {
            return BLE_ATT_ERR_UNLIKELY;
        }
        ota_status_notify();
        return ota_err == TANKLINK_OTA_ERR_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
    }

    if (ble_uuid_cmp(uuid, &uuid_ota_data.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len < 5) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        /* Stack-friendly cap: offset(4) + payload */
        if (len > 512) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t tmp[512];
        int rc = ble_hs_mbuf_to_flat(ctxt->om, tmp, len, NULL);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint32_t offset = (uint32_t)tmp[0] | ((uint32_t)tmp[1] << 8) |
                          ((uint32_t)tmp[2] << 16) | ((uint32_t)tmp[3] << 24);
        uint8_t ota_err = pump_ota_write(conn_handle, offset, &tmp[4], (uint16_t)(len - 4));
        return ota_err == TANKLINK_OTA_ERR_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

void gatt_svr_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg)
{
    (void)arg;
    char buf[BLE_UUID_STR_LEN];
    switch (ctxt->op) {
    case BLE_GATT_REGISTER_OP_SVC:
        ESP_LOGI(TAG, "svc %s handle=%d",
                 ble_uuid_to_str(ctxt->svc.svc_def->uuid, buf), ctxt->svc.handle);
        break;
    case BLE_GATT_REGISTER_OP_CHR:
        ESP_LOGI(TAG, "chr %s val_handle=%d",
                 ble_uuid_to_str(ctxt->chr.chr_def->uuid, buf), ctxt->chr.val_handle);
        break;
    default:
        break;
    }
}

int gatt_svr_init(void)
{
    memset(s_conns, 0, sizeof(s_conns));
    ble_svc_gap_init();
    ble_svc_gatt_init();
    pump_ota_set_status_cb(ota_status_notify);

    int rc = ble_gatts_count_cfg(gatt_svr_svcs);
    if (rc != 0) {
        return rc;
    }
    return ble_gatts_add_svcs(gatt_svr_svcs);
}

void gatt_svr_on_connect(uint16_t conn_handle)
{
    conn_slot_t *slot = slot_alloc(conn_handle);
    if (!slot) {
        ESP_LOGW(TAG, "conn table full — rejecting handle=%u", conn_handle);
        ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        return;
    }
    const int count = gatt_svr_conn_count();
    ESP_LOGI(TAG, "conn add handle=%u count=%d", conn_handle, count);
    if (count == 1) {
        /* First phone link: short accent pulse on standby, then stay idle. */
        status_led_notify_ble_connect();
    }
    refresh_connected_led();
}

void gatt_svr_on_disconnect(uint16_t conn_handle)
{
    pump_ota_on_disconnect(conn_handle);
    conn_slot_t *slot = slot_find(conn_handle);
    if (slot) {
        memset(slot, 0, sizeof(*slot));
    }
    ESP_LOGI(TAG, "conn drop handle=%u count=%d", conn_handle, gatt_svr_conn_count());
    refresh_connected_led();
}

int gatt_svr_conn_count(void)
{
    int n = 0;
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (s_conns[i].in_use) {
            n++;
        }
    }
    return n;
}

bool gatt_svr_is_authed_conn(uint16_t conn_handle)
{
    conn_slot_t *slot = slot_find(conn_handle);
    return slot && slot->authed;
}

bool gatt_svr_is_authed(void)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (s_conns[i].in_use && s_conns[i].authed) {
            return true;
        }
    }
    return false;
}

bool gatt_svr_is_connected(void)
{
    return gatt_svr_conn_count() > 0;
}

uint8_t gatt_svr_pump_state(void)
{
    return s_pump_on;
}

uint32_t gatt_svr_run_seconds(void)
{
    if (!s_pump_on || s_pump_on_since_us == 0) {
        return 0;
    }
    int64_t elapsed = (esp_timer_get_time() - s_pump_on_since_us) / 1000000LL;
    if (elapsed < 0) {
        return 0;
    }
    return (uint32_t)elapsed;
}

static void report_start_denied(uint8_t code)
{
    s_last_error = code;
    status_led_show_error(code);
    gatt_svr_notify_tank_if_subscribed();
}

static void set_pump_state_internal(uint8_t on, bool allow_pump_buzz)
{
    uint8_t next = on ? 1 : 0;
    if (next && (relay_control_is_blocked() || pump_ota_is_active())) {
        ESP_LOGW(TAG, "Pump ON denied — blocked/OTA");
        report_start_denied(PUMP_ERR_BLOCKED);
        return;
    }
    if (next && lora_link_tank_bound() && lora_link_tank_online() &&
        ((lora_link_tank_flags() & TANKLINK_LORA_FLAG_FULL) != 0 ||
         status_led_get_tank_full())) {
        ESP_LOGW(TAG, "Pump ON denied — tank full");
        report_start_denied(PUMP_ERR_TANK_FULL);
        return;
    }
    bool changed = next != s_pump_on;
    if (next && !s_pump_on) {
        s_pump_on_since_us = esp_timer_get_time();
        s_last_error = PUMP_ERR_NONE;
        gatt_svr_notify_tank_if_subscribed();
    }
    if (!next) {
        s_pump_on_since_us = 0;
    }
    s_pump_on = next;
    board_set_pump_on(s_pump_on != 0);
    if (s_pump_on) {
        relay_control_set_running(true);
    } else {
        /* Prefer force_off so Stop is always pulsed for safety. */
        relay_control_force_off();
    }
    ESP_LOGI(TAG, "Pump state -> %u", s_pump_on);
    if (changed && allow_pump_buzz && pump_config_buzzer_on_pump()) {
        buzzer_play(next ? BUZZER_TONE_SHARP : BUZZER_TONE_CLICK, false);
    }
    if (!s_pump_on) {
        refresh_connected_led();
    }
    gatt_svr_notify_state_if_subscribed();
}

void gatt_svr_set_last_error(uint8_t code)
{
    s_last_error = code;
    gatt_svr_notify_tank_if_subscribed();
}

void gatt_svr_clear_last_error(void)
{
    if (s_last_error == PUMP_ERR_NONE) {
        return;
    }
    s_last_error = PUMP_ERR_NONE;
    gatt_svr_notify_tank_if_subscribed();
}

uint8_t gatt_svr_last_error(void)
{
    return s_last_error;
}

void gatt_svr_set_pump_state(uint8_t on)
{
    set_pump_state_internal(on, true);
}

void gatt_svr_set_pump_state_silent(uint8_t on)
{
    set_pump_state_internal(on, false);
}

void gatt_svr_toggle_pump(void)
{
    if (pump_ota_is_active()) {
        ESP_LOGW(TAG, "Toggle ignored — OTA in progress");
        return;
    }
    if (!pump_pair_is_paired()) {
        ESP_LOGW(TAG, "Toggle ignored — not paired");
        return;
    }
    /* Button click sound is handled by the caller when configured. */
    gatt_svr_set_pump_state_silent(s_pump_on ? 0 : 1);
}

void gatt_svr_poll(void)
{
    if (!s_pump_on) {
        return;
    }
    uint8_t mins = pump_config_auto_off_min();
    if (mins == 0) {
        return;
    }
    uint32_t limit = (uint32_t)mins * 60u;
    if (gatt_svr_run_seconds() >= limit) {
        ESP_LOGW(TAG, "Auto-off after %u min", mins);
        gatt_svr_set_pump_state_silent(0);
        if (pump_config_buzzer_on_auto()) {
            buzzer_play(BUZZER_TONE_DOUBLE, false);
        }
    }
}

void gatt_svr_notify_state_if_subscribed(void)
{
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (!s_conns[i].in_use || !s_conns[i].state_notify) {
            continue;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(&s_pump_on, 1);
        if (!om) {
            continue;
        }
        int rc = ble_gatts_notify_custom(s_conns[i].conn_handle, s_state_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "state notify conn=%u rc=%d", s_conns[i].conn_handle, rc);
        }
    }
}

void gatt_svr_notify_tank_if_subscribed(void)
{
    uint8_t buf[TANKLINK_TANK_STATUS_LEN];
    fill_tank_status(buf);
    for (int i = 0; i < TANKLINK_MAX_BLE_CONN; i++) {
        if (!s_conns[i].in_use || !s_conns[i].tank_notify) {
            continue;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof(buf));
        if (!om) {
            continue;
        }
        int rc = ble_gatts_notify_custom(s_conns[i].conn_handle, s_tank_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "tank notify conn=%u rc=%d", s_conns[i].conn_handle, rc);
        }
    }
}

uint16_t gatt_svr_pair_val_handle(void)
{
    return s_pair_val_handle;
}

uint16_t gatt_svr_state_val_handle(void)
{
    return s_state_val_handle;
}

void gatt_svr_on_subscribe(uint16_t conn_handle, uint16_t attr_handle, bool notify_enabled)
{
    conn_slot_t *slot = slot_find(conn_handle);
    if (!slot) {
        return;
    }
    if (attr_handle == s_state_val_handle) {
        slot->state_notify = notify_enabled;
    }
    if (attr_handle == s_ota_status_val_handle) {
        slot->ota_status_notify = notify_enabled;
    }
    if (attr_handle == s_tank_val_handle) {
        slot->tank_notify = notify_enabled;
    }
}
