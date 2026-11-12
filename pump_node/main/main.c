/*
 * TankLink pump controller (ESP32-C3).
 * BLE GATT claim/pair + OnOff. Hold Start+Stop ~5s → BLE pairing window.
 * Short Start = ON, short Stop = OFF. Adv name TankLink-XXXX from MAC.
 */

#include <string.h>

#include "esp_log.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_att.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"

#include "board.h"
#include "buzzer.h"
#include "gatt_svr.h"
#include "lora_link.h"
#include "pump_config.h"
#include "pump_ota.h"
#include "pump_pair.h"
#include "relay_control.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "PUMP"

static uint8_t s_own_addr_type;
static const ble_uuid128_t s_svc_uuid = TANKLINK_SVC_UUID_INIT;

static void advertise(void);
static int gap_event(struct ble_gap_event *event, void *arg);

static void on_ble_pair_hold(void)
{
    pump_pair_enter_pairing_mode();
}

static void maybe_exit_ble_pairing(void)
{
    if (!pump_pair_pairing_active()) {
        return;
    }
    if (pump_config_buzzer_on_button()) {
        buzzer_play_user(false);
    }
    pump_pair_exit_pairing_mode();
}

static void on_start(void)
{
    if (pump_ota_is_active()) {
        return;
    }
    if (pump_pair_pairing_active()) {
        maybe_exit_ble_pairing();
        return;
    }
    if (pump_config_buzzer_on_button()) {
        buzzer_play_user(false);
    }
    gatt_svr_set_pump_state_silent(1);
}

static void on_stop(void)
{
    if (pump_ota_is_active()) {
        /* Still allow stop for safety during OTA. */
        gatt_svr_set_pump_state_silent(0);
        return;
    }
    if (pump_pair_pairing_active()) {
        maybe_exit_ble_pairing();
        return;
    }
    if (pump_config_buzzer_on_button()) {
        buzzer_play_user(false);
    }
    gatt_svr_set_pump_state_silent(0);
}

static void pair_poll_task(void *arg)
{
    (void)arg;
    while (1) {
        pump_pair_poll();
        gatt_svr_poll();
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void advertise(void)
{
    const char *name = pump_pair_adv_name();
    if (!name || name[0] == '\0') {
        name = TANKLINK_DEVICE_NAME;
    }

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.tx_pwr_lvl_is_present = 1;
    fields.tx_pwr_lvl = BLE_HS_ADV_TX_PWR_LVL_AUTO;
    fields.name = (uint8_t *)name;
    fields.name_len = strlen(name);
    fields.name_is_complete = 1;
    fields.uuids128 = (ble_uuid128_t *)&s_svc_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv fields compact fallback rc=%d", rc);
        memset(&fields, 0, sizeof(fields));
        fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
        fields.name = (uint8_t *)name;
        fields.name_len = strlen(name);
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
        rc = ble_gap_adv_rsp_set_fields(&rsp);
        if (rc != 0) {
            ESP_LOGW(TAG, "scan rsp set failed rc=%d", rc);
        }
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

    if (pump_pair_pairing_active()) {
        ESP_LOGI(TAG, "PAIRING — advertising as %s", name);
    } else if (pump_pair_is_paired()) {
        ESP_LOGI(TAG, "PAIRED — advertising as %s", name);
    } else {
        ESP_LOGI(TAG, "UNPAIRED — advertising as %s", name);
    }
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        ESP_LOGI(TAG, "connect %s status=%d",
                 event->connect.status == 0 ? "ok" : "fail",
                 event->connect.status);
        if (event->connect.status != 0) {
            advertise();
        } else {
            gatt_svr_on_connect(event->connect.conn_handle);
            /* Prefer large ATT MTU for OTA throughput (central may also request). */
            ble_att_set_preferred_mtu(512);
            ble_gattc_exchange_mtu(event->connect.conn_handle, NULL, NULL);
            /* NimBLE stops advertising on connect — reopen while slots remain. */
            if (gatt_svr_conn_count() < TANKLINK_MAX_BLE_CONN) {
                advertise();
            }
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnect reason=%d", event->disconnect.reason);
        gatt_svr_on_disconnect(event->disconnect.conn.conn_handle);
        advertise();
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (gatt_svr_conn_count() < TANKLINK_MAX_BLE_CONN) {
            advertise();
        }
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "subscribe conn=%d attr=%d notify=%d",
                 event->subscribe.conn_handle,
                 event->subscribe.attr_handle, event->subscribe.cur_notify);
        gatt_svr_on_subscribe(event->subscribe.conn_handle,
                              event->subscribe.attr_handle,
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

static void on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "infer addr rc=%d", rc);
        return;
    }
    uint8_t addr[6] = {0};
    ble_hs_id_copy_addr(s_own_addr_type, addr, NULL);
    /* NimBLE returns little-endian; store network/human order for serial. */
    uint8_t mac[6] = {addr[5], addr[4], addr[3], addr[2], addr[1], addr[0]};
    ESP_LOGI(TAG, "addr %02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    pump_pair_set_mac_identity(mac);
    ble_svc_gap_device_name_set(pump_pair_adv_name());
    advertise();
}

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "nimble reset reason=%d", reason);
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void app_main(void)
{
    ESP_LOGI(TAG, "TankLink pump starting…");

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    /* Peripherals soft-fail so LoRa-only / partial wiring still boots. */
    if (buzzer_init() != ESP_OK) {
        ESP_LOGW(TAG, "buzzer init failed — continuing");
    }
    ESP_ERROR_CHECK(pump_config_init());
    if (relay_control_init() != ESP_OK) {
        ESP_LOGW(TAG, "relay init failed — continuing");
    }
    if (board_init() != ESP_OK) {
        ESP_LOGW(TAG, "board/LED/button init failed — continuing");
    }
    pump_config_apply_led();
    ESP_ERROR_CHECK(pump_pair_init());
    board_set_long_press_callback(on_ble_pair_hold);
    board_set_start_callback(on_start);
    board_set_stop_callback(on_stop);
    if (lora_link_init() != ESP_OK) {
        ESP_LOGW(TAG, "LoRa init failed — tank link offline");
    }
    if (pump_ota_init() != ESP_OK) {
        ESP_LOGW(TAG, "OTA init failed — continuing");
    }

    if (buzzer_enabled()) {
        buzzer_play(BUZZER_TONE_CLICK, true);
    }

    if (xTaskCreate(pair_poll_task, "pair_poll", 2048, NULL, 3, NULL) != pdPASS) {
        ESP_LOGW(TAG, "pair_poll task failed");
    }

    err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(err));
        return;
    }

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.gatts_register_cb = gatt_svr_register_cb;

    int rc = gatt_svr_init();
    if (rc != 0) {
        ESP_LOGE(TAG, "gatt_svr_init rc=%d", rc);
        return;
    }

    rc = ble_svc_gap_device_name_set(TANKLINK_DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGE(TAG, "device_name_set rc=%d", rc);
        return;
    }

    nimble_port_freertos_init(host_task);
}
