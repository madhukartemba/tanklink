#include "tank_ble.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_att.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"

#include "sdkconfig.h"
#include "tank_board.h"
#include "tank_gatt.h"
#include "tank_led.h"
#include "tank_link.h"
#include "tank_ota.h"
#include "tanklink_ble_uuid.h"

#ifndef CONFIG_TANK_BUTTON_HOLD_MS
#define CONFIG_TANK_BUTTON_HOLD_MS 3000
#endif

#define TAG "TANK_BLE"

static uint8_t s_own_addr_type;
static bool s_nimble_ready;
static bool s_window_active;
static bool s_connected;
static int64_t s_window_deadline_us;
static char s_adv_name[TANKLINK_ADV_NAME_MAX];
static const ble_uuid128_t s_svc_uuid = TANKLINK_SVC_UUID_INIT;

static void advertise(void);
static int gap_event(struct ble_gap_event *event, void *arg);

static void ble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static void on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "infer addr rc=%d", rc);
        return;
    }
    s_nimble_ready = true;
    ESP_LOGI(TAG, "nimble sync ok");
}

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "nimble reset reason=%d", reason);
    s_nimble_ready = false;
}

static void build_adv_name(void)
{
    const uint8_t *id = tank_link_tank_id();
    snprintf(s_adv_name, sizeof(s_adv_name), "%s%02X%02X", TANKLINK_TANK_ADV_PREFIX, id[4],
             id[5]);
}

static void advertise(void)
{
    build_adv_name();
    ble_svc_gap_device_name_set(s_adv_name);

    /* mfg: company(2 LE) + tank_id(6) */
    uint8_t mfg[2 + TANKLINK_DEVICE_ID_LEN];
    mfg[0] = (uint8_t)(TANKLINK_MFG_COMPANY_ID & 0xff);
    mfg[1] = (uint8_t)((TANKLINK_MFG_COMPANY_ID >> 8) & 0xff);
    memcpy(&mfg[2], tank_link_tank_id(), TANKLINK_DEVICE_ID_LEN);

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)s_adv_name;
    fields.name_len = strlen(s_adv_name);
    fields.name_is_complete = 1;
    fields.mfg_data = mfg;
    fields.mfg_data_len = sizeof(mfg);

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv fields fallback rc=%d", rc);
        memset(&fields, 0, sizeof(fields));
        fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
        fields.name = (uint8_t *)s_adv_name;
        fields.name_len = strlen(s_adv_name);
        fields.name_is_complete = 1;
        rc = ble_gap_adv_set_fields(&fields);
        if (rc != 0) {
            ESP_LOGE(TAG, "adv set fields failed rc=%d", rc);
            return;
        }
        struct ble_hs_adv_fields rsp;
        memset(&rsp, 0, sizeof(rsp));
        rsp.uuids128 = (ble_uuid128_t *)&s_svc_uuid;
        rsp.num_uuids128 = 1;
        rsp.uuids128_is_complete = 1;
        (void)ble_gap_adv_rsp_set_fields(&rsp);
    }

    struct ble_gap_adv_params adv;
    memset(&adv, 0, sizeof(adv));
    adv.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv, gap_event, NULL);
    if (rc == BLE_HS_EALREADY) {
        return;
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "adv start failed rc=%d", rc);
        return;
    }
    ESP_LOGI(TAG, "advertising as %s for OTA", s_adv_name);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            s_connected = false;
            if (s_window_active) {
                advertise();
            }
        } else {
            s_connected = true;
            tank_gatt_on_connect(event->connect.conn_handle);
            ble_att_set_preferred_mtu(512);
            ble_gattc_exchange_mtu(event->connect.conn_handle, NULL, NULL);
            ESP_LOGI(TAG, "connected");
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnect reason=%d", event->disconnect.reason);
        tank_gatt_on_disconnect(event->disconnect.conn.conn_handle);
        s_connected = false;
        if (s_window_active && !tank_ota_is_active()) {
            advertise();
        }
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (s_window_active && !s_connected) {
            advertise();
        }
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        tank_gatt_on_subscribe(event->subscribe.conn_handle, event->subscribe.attr_handle,
                               event->subscribe.cur_notify != 0);
        break;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "mtu=%d", event->mtu.value);
        break;
    default:
        break;
    }
    return 0;
}

esp_err_t tank_ble_init(void)
{
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init: %s", esp_err_to_name(err));
        return err;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.gatts_register_cb = tank_gatt_register_cb;

    err = tank_gatt_init();
    if (err != ESP_OK) {
        return err;
    }
    err = tank_ota_init();
    if (err != ESP_OK) {
        return err;
    }
    nimble_port_freertos_init(ble_host_task);

    /* Wait briefly for sync. */
    for (int i = 0; i < 50 && !s_nimble_ready; i++) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!s_nimble_ready) {
        ESP_LOGW(TAG, "nimble not synced yet");
    }
    return ESP_OK;
}

bool tank_ble_ota_busy(void)
{
    return tank_ota_is_active();
}

void tank_ble_stop(void)
{
    s_window_active = false;
    ble_gap_adv_stop();
    tank_ota_abort();
}

esp_err_t tank_ble_start_ota_window(uint32_t timeout_ms)
{
    if (timeout_ms < 5000) {
        timeout_ms = 120000;
    }
    if (!s_nimble_ready) {
        for (int i = 0; i < 50 && !s_nimble_ready; i++) {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        if (!s_nimble_ready) {
            return ESP_ERR_INVALID_STATE;
        }
    }

    s_window_active = true;
    s_window_deadline_us = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    /* Distinct from LoRa pairing breathe: one short blink, then dark. */
    tank_led_blink(1, 120, 0);
    tank_led_off();
    advertise();
    ESP_LOGI(TAG, "OTA advertise started (%u ms window)", (unsigned)timeout_ms);
    return ESP_OK;
}

esp_err_t tank_ble_wait_ota_window(void)
{
    if (!s_window_active) {
        return ESP_OK;
    }

    bool want_pair = false;
    int64_t hold_start_us = 0;
    while (s_window_active) {
        if (tank_ota_state() == TANKLINK_OTA_ST_REBOOTING) {
            vTaskDelay(pdMS_TO_TICKS(200));
            continue;
        }
        if (!tank_ota_is_active() && esp_timer_get_time() >= s_window_deadline_us) {
            ESP_LOGI(TAG, "OTA window timed out");
            break;
        }
        /* Hold during OTA window → exit so main can LoRa-pair. */
        if (!tank_ota_is_active() && tank_board_button_down()) {
            if (hold_start_us == 0) {
                hold_start_us = esp_timer_get_time();
            } else if ((esp_timer_get_time() - hold_start_us) / 1000 >=
                       CONFIG_TANK_BUTTON_HOLD_MS) {
                want_pair = true;
                break;
            }
        } else {
            hold_start_us = 0;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }

    s_window_active = false;
    ble_gap_adv_stop();
    if (!tank_ota_is_active()) {
        tank_led_off();
    }
    return want_pair ? ESP_ERR_INVALID_STATE : ESP_OK;
}

esp_err_t tank_ble_run_ota_window(uint32_t timeout_ms)
{
    esp_err_t err = tank_ble_start_ota_window(timeout_ms);
    if (err != ESP_OK) {
        return err;
    }
    return tank_ble_wait_ota_window();
}
