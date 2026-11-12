#include "tank_gatt.h"

#include <string.h>

#include "esp_log.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "tank_ble_token.h"
#include "tank_link.h"
#include "tank_ota.h"
#include "tank_version.h"
#include "tanklink_ble_uuid.h"

#define TAG "TANK_GATT"
#define MAX_CONN 1

typedef struct {
    uint16_t conn_handle;
    bool in_use;
    bool authed;
    bool ota_status_notify;
} conn_slot_t;

static const ble_uuid128_t uuid_svc = TANKLINK_SVC_UUID_INIT;
static const ble_uuid128_t uuid_info = TANKLINK_CHR_INFO_INIT;
static const ble_uuid128_t uuid_auth = TANKLINK_CHR_AUTH_INIT;
static const ble_uuid128_t uuid_ota_ctrl = TANKLINK_CHR_OTA_CTRL_INIT;
static const ble_uuid128_t uuid_ota_data = TANKLINK_CHR_OTA_DATA_INIT;
static const ble_uuid128_t uuid_ota_status = TANKLINK_CHR_OTA_STATUS_INIT;

static conn_slot_t s_conns[MAX_CONN];
static uint16_t s_ota_status_val_handle;

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg);

static const struct ble_gatt_svc_def gatt_svcs[] = {
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
                .uuid = &uuid_auth.u,
                .access_cb = chr_access,
                .flags = BLE_GATT_CHR_F_WRITE,
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

static conn_slot_t *slot_find(uint16_t conn_handle)
{
    for (int i = 0; i < MAX_CONN; i++) {
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
    for (int i = 0; i < MAX_CONN; i++) {
        if (!s_conns[i].in_use) {
            memset(&s_conns[i], 0, sizeof(s_conns[i]));
            s_conns[i].in_use = true;
            s_conns[i].conn_handle = conn_handle;
            return &s_conns[i];
        }
    }
    return NULL;
}

static void append_ota_status(uint8_t *out6)
{
    uint32_t off = tank_ota_offset();
    out6[0] = tank_ota_state();
    out6[1] = tank_ota_last_error();
    out6[2] = (uint8_t)(off & 0xff);
    out6[3] = (uint8_t)((off >> 8) & 0xff);
    out6[4] = (uint8_t)((off >> 16) & 0xff);
    out6[5] = (uint8_t)((off >> 24) & 0xff);
}

static void ota_status_notify(void)
{
    uint8_t buf[6];
    append_ota_status(buf);
    for (int i = 0; i < MAX_CONN; i++) {
        if (!s_conns[i].in_use || !s_conns[i].ota_status_notify) {
            continue;
        }
        struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof(buf));
        if (!om) {
            continue;
        }
        int rc = ble_gatts_notify_custom(s_conns[i].conn_handle, s_ota_status_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "ota notify rc=%d", rc);
        }
    }
}

static int append_info(struct os_mbuf *om)
{
    /* paired(1)=1 + tank_id(6) + fw\0 */
    uint8_t paired = 1;
    int rc = os_mbuf_append(om, &paired, 1);
    if (rc != 0) {
        return rc;
    }
    rc = os_mbuf_append(om, tank_link_tank_id(), TANKLINK_DEVICE_ID_LEN);
    if (rc != 0) {
        return rc;
    }
    return os_mbuf_append(om, TANK_FW_VERSION_STR, strlen(TANK_FW_VERSION_STR) + 1);
}

static int chr_access(uint16_t conn_handle, uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;
    const ble_uuid_t *uuid = ctxt->chr->uuid;

    if (ble_uuid_cmp(uuid, &uuid_info.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        return append_info(ctxt->om) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ble_uuid_cmp(uuid, &uuid_auth.u) == 0) {
        if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint8_t token[TANKLINK_TOKEN_LEN];
        int rc = ble_hs_mbuf_to_flat(ctxt->om, token, sizeof(token), NULL);
        if (rc != 0 || OS_MBUF_PKTLEN(ctxt->om) != TANKLINK_TOKEN_LEN) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        conn_slot_t *slot = slot_find(conn_handle);
        if (!slot) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        slot->authed = tank_ble_token_check(token, sizeof(token));
        ESP_LOGI(TAG, "auth %s", slot->authed ? "ok" : "fail");
        return slot->authed ? 0 : BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
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
            ota_err = tank_ota_start(conn_handle, size, &buf[5]);
        } else if (op == TANKLINK_OTA_OP_ABORT) {
            ota_err = tank_ota_abort_from(conn_handle);
        } else if (op == TANKLINK_OTA_OP_FINISH) {
            ota_err = tank_ota_finish(conn_handle);
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
        if (len < 5 || len > 512) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        uint8_t tmp[512];
        int rc = ble_hs_mbuf_to_flat(ctxt->om, tmp, len, NULL);
        if (rc != 0) {
            return BLE_ATT_ERR_UNLIKELY;
        }
        uint32_t offset = (uint32_t)tmp[0] | ((uint32_t)tmp[1] << 8) |
                          ((uint32_t)tmp[2] << 16) | ((uint32_t)tmp[3] << 24);
        uint8_t ota_err = tank_ota_write(conn_handle, offset, &tmp[4], (uint16_t)(len - 4));
        return ota_err == TANKLINK_OTA_ERR_OK ? 0 : BLE_ATT_ERR_UNLIKELY;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

void tank_gatt_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg)
{
    (void)arg;
    char buf[BLE_UUID_STR_LEN];
    switch (ctxt->op) {
    case BLE_GATT_REGISTER_OP_SVC:
        ESP_LOGI(TAG, "svc %s", ble_uuid_to_str(ctxt->svc.svc_def->uuid, buf));
        break;
    case BLE_GATT_REGISTER_OP_CHR:
        ESP_LOGI(TAG, "chr %s", ble_uuid_to_str(ctxt->chr.chr_def->uuid, buf));
        break;
    default:
        break;
    }
}

esp_err_t tank_gatt_init(void)
{
    memset(s_conns, 0, sizeof(s_conns));
    ble_svc_gap_init();
    ble_svc_gatt_init();
    tank_ota_set_status_cb(ota_status_notify);

    int rc = ble_gatts_count_cfg(gatt_svcs);
    if (rc != 0) {
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(gatt_svcs);
    if (rc != 0) {
        return ESP_FAIL;
    }
    return ESP_OK;
}

void tank_gatt_on_connect(uint16_t conn_handle)
{
    (void)slot_alloc(conn_handle);
}

void tank_gatt_on_disconnect(uint16_t conn_handle)
{
    tank_ota_on_disconnect(conn_handle);
    for (int i = 0; i < MAX_CONN; i++) {
        if (s_conns[i].in_use && s_conns[i].conn_handle == conn_handle) {
            memset(&s_conns[i], 0, sizeof(s_conns[i]));
        }
    }
}

void tank_gatt_on_subscribe(uint16_t conn_handle, uint16_t attr_handle, bool notify)
{
    conn_slot_t *slot = slot_find(conn_handle);
    if (!slot) {
        return;
    }
    if (attr_handle == s_ota_status_val_handle) {
        slot->ota_status_notify = notify;
    }
}

bool tank_gatt_is_authed_conn(uint16_t conn_handle)
{
    conn_slot_t *slot = slot_find(conn_handle);
    return slot && slot->authed;
}

int tank_gatt_conn_count(void)
{
    int n = 0;
    for (int i = 0; i < MAX_CONN; i++) {
        if (s_conns[i].in_use) {
            n++;
        }
    }
    return n;
}
