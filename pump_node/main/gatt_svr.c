#include "gatt_svr.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "host/ble_uuid.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "board.h"
#include "buzzer.h"
#include "pump_config.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "relay_control.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "GATT_SVR"

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

static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_pair_val_handle;
static uint16_t s_state_val_handle;
static uint16_t s_ota_status_val_handle;
static bool s_authed;
static bool s_state_notify;
static bool s_ota_status_notify;
static uint8_t s_pump_on;
static int64_t s_pump_on_since_us;

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
            { 0 },
        },
    },
    { 0 },
};

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
    if (!s_ota_status_notify || s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    uint8_t buf[6];
    append_ota_status(buf);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof(buf));
    if (!om) {
        return;
    }
    int rc = ble_gatts_notify_custom(s_conn_handle, s_ota_status_val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "ota status notify rc=%d", rc);
    }
}

static int append_info(struct os_mbuf *om)
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
    if (s_authed) {
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

static int append_settings(struct os_mbuf *om)
{
    /* auto_off(1) + run_secs(u32 LE) + serial(5) + buzz_flags(1) + tone(1) */
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
    rc = os_mbuf_append(om, &buzz_flags, 1);
    if (rc != 0) {
        return rc;
    }
    return os_mbuf_append(om, &tone, 1);
}

static void refresh_connected_led(void)
{
    status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_HOLD_PROGRESS || mode == STATUS_LED_PAIRING ||
        mode == STATUS_LED_UNPAIRED || mode == STATUS_LED_PUMP_ON ||
        mode == STATUS_LED_UPDATING) {
        return;
    }
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE && !s_pump_on) {
        status_led_set_mode(STATUS_LED_CONNECTED);
    } else if (!s_pump_on) {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    const ble_uuid_t *uuid = ctxt->chr->uuid;

    if (ble_uuid_cmp(uuid, &uuid_info.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return append_info(ctxt->om) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &uuid_pair.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (!pump_pair_is_claimable()) {
            ESP_LOGW(TAG, "Claim rejected — hold button 5s to enter pairing");
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        uint8_t token[TANKLINK_TOKEN_LEN];
        if (pump_pair_claim(token) != ESP_OK) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        s_authed = true; /* claimer is authenticated for this connection */
        struct os_mbuf *om = ble_hs_mbuf_from_flat(token, sizeof(token));
        if (!om) {
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        int rc = ble_gatts_notify_custom(s_conn_handle, s_pair_val_handle, om);
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
        s_authed = pump_pair_check_token(token, sizeof(token));
        ESP_LOGI(TAG, "Auth %s", s_authed ? "OK" : "FAILED");
        return s_authed ? 0 : BLE_ATT_ERR_WRITE_NOT_PERMITTED;
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
        if (!s_authed) {
            ESP_LOGW(TAG, "Cmd rejected — not authenticated");
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
            s_authed = false;
            gatt_svr_set_pump_state(0);
            return 0;
        }
        if (cmd == TANKLINK_CMD_TEST_BEEP) {
            buzzer_play_user(true);
            return 0;
        }
        gatt_svr_set_pump_state(cmd ? 1 : 0);
        return 0;
    }

    if (ble_uuid_cmp(uuid, &uuid_settings.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            return append_settings(ctxt->om) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        if (!s_authed) {
            return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        }
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len < 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t buf[4] = {0};
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
            ota_err = pump_ota_start(size, &buf[5]);
        } else if (op == TANKLINK_OTA_OP_ABORT) {
            ota_err = pump_ota_abort();
        } else if (op == TANKLINK_OTA_OP_FINISH) {
            ota_err = pump_ota_finish();
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
        uint8_t ota_err = pump_ota_write(offset, &tmp[4], (uint16_t)(len - 4));
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
    ble_svc_gap_init();
    ble_svc_gatt_init();
    pump_ota_set_status_cb(ota_status_notify);

    int rc = ble_gatts_count_cfg(gatt_svr_svcs);
    if (rc != 0) {
        return rc;
    }
    return ble_gatts_add_svcs(gatt_svr_svcs);
}

void gatt_svr_set_conn(uint16_t conn_handle)
{
    s_conn_handle = conn_handle;
    refresh_connected_led();
}

void gatt_svr_clear_session(void)
{
    if (pump_ota_is_active()) {
        pump_ota_abort();
    }
    s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    s_authed = false;
    s_state_notify = false;
    s_ota_status_notify = false;
    refresh_connected_led();
}

bool gatt_svr_is_authed(void)
{
    return s_authed;
}

bool gatt_svr_is_connected(void)
{
    return s_conn_handle != BLE_HS_CONN_HANDLE_NONE;
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

static void set_pump_state_internal(uint8_t on, bool allow_pump_buzz)
{
    uint8_t next = on ? 1 : 0;
    bool changed = next != s_pump_on;
    if (next && !s_pump_on) {
        s_pump_on_since_us = esp_timer_get_time();
    }
    if (!next) {
        s_pump_on_since_us = 0;
    }
    s_pump_on = next;
    board_set_pump_on(s_pump_on != 0);
    relay_control_set_running(s_pump_on != 0);
    ESP_LOGI(TAG, "Pump state -> %u", s_pump_on);
    if (changed && allow_pump_buzz && pump_config_buzzer_on_pump()) {
        buzzer_play(next ? BUZZER_TONE_SHARP : BUZZER_TONE_CLICK, false);
    }
    if (!s_pump_on) {
        refresh_connected_led();
    }
    gatt_svr_notify_state_if_subscribed();
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
    if (!s_state_notify || s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(&s_pump_on, 1);
    if (!om) {
        return;
    }
    int rc = ble_gatts_notify_custom(s_conn_handle, s_state_val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "state notify rc=%d", rc);
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

void gatt_svr_on_subscribe(uint16_t attr_handle, bool notify_enabled)
{
    if (attr_handle == s_state_val_handle) {
        s_state_notify = notify_enabled;
    }
    if (attr_handle == s_ota_status_val_handle) {
        s_ota_status_notify = notify_enabled;
    }
}
