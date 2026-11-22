#include "tank_ble.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_system.h"
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
#include "tank_errors.h"
#include "tank_gatt.h"
#include "tank_led.h"
#include "tank_link.h"
#include "tank_ota.h"
#include "tanklink_ble_uuid.h"


#define TAG "TANK_BLE"

static uint8_t s_own_addr_type;
static bool s_nimble_ready;
static bool s_stack_up;
/* Once a phone connects, the window stays open at least this long. */
#define CONNECTED_WINDOW_MS 60000
/* After a failed update, stay up long enough for the phone to read the
 * tank's own error from OtaStatus instead of seeing the link drop (GATT 133). */
#define OTA_ERROR_GRACE_MS 5000
/* An update that makes no progress this long is dropped (the phone was
 * backgrounded or stalled), so the tank can sleep again. */
#define OTA_STALL_DISCONNECT_MS 20000
/* If dropping the link did not end it, restart. The boot partition only
 * changes after a verified image, so this is always safe. */
#define OTA_STALL_RESTART_MS 30000
/* The restart after a good update is 1.2 s away; this is the fallback. */
#define OTA_REBOOT_FALLBACK_MS 10000

static bool s_window_active;
static bool s_connected;
static int64_t s_window_deadline_us;
static uint32_t s_window_ms;
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
    /* After a host reset the stack syncs again; keep the window reachable. */
    if (s_window_active && !s_connected) {
        advertise();
    }
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
            /* The phone still has to find the services, sign in and start
             * the update: keep the window open for it, or the tank would
             * sleep and drop the link mid-way (Android GATT error 133). */
            if (s_window_active) {
                const int64_t need =
                    esp_timer_get_time() + (int64_t)CONNECTED_WINDOW_MS * 1000;
                if (s_window_deadline_us < need) {
                    s_window_deadline_us = need;
                }
            }
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
    if (s_stack_up) {
        return ESP_OK;
    }
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init: %s", esp_err_to_name(err));
        return err;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.gatts_register_cb = tank_gatt_register_cb;

    err = tank_gatt_init();
    if (err == ESP_OK) {
        err = tank_ota_init();
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "GATT setup failed: %s", esp_err_to_name(err));
        (void)nimble_port_deinit();
        return err;
    }
    s_nimble_ready = false;
    nimble_port_freertos_init(ble_host_task);
    s_stack_up = true;

    /* Wait briefly for sync. */
    for (int i = 0; i < 50 && !s_nimble_ready; i++) {
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (!s_nimble_ready) {
        ESP_LOGW(TAG, "nimble not synced yet");
    }
    return ESP_OK;
}

void tank_ble_stop(void)
{
    s_window_active = false;
    if (s_stack_up) {
        ble_gap_adv_stop();
    }
    tank_ota_abort();
}

void tank_ble_deinit(void)
{
    if (!s_stack_up) {
        return;
    }
    s_window_active = false;
    ble_gap_adv_stop();

    /* Espressif: stop host then deinit (disables BT controller). The update
     * is aborted after the host stops, so no write can race the abort. */
    int rc = nimble_port_stop();
    if (rc != 0) {
        ESP_LOGW(TAG, "nimble_port_stop rc=%d — trying deinit anyway", rc);
    }
    tank_ota_abort();
    esp_err_t err = nimble_port_deinit();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "nimble_port_deinit: %s", esp_err_to_name(err));
    }
    s_nimble_ready = false;
    s_connected = false;
    s_stack_up = false;
    ESP_LOGI(TAG, "BLE stack powered down for deep sleep");
}

esp_err_t tank_ble_start_ota_window(uint32_t timeout_ms)
{
    if (!s_stack_up) {
        esp_err_t err = tank_ble_init();
        if (err != ESP_OK) {
            return err;
        }
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
    s_window_ms = timeout_ms;
    s_window_deadline_us = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    advertise();
    ESP_LOGI(TAG, "OTA advertise started (%u ms window)", (unsigned)timeout_ms);
    return ESP_OK;
}

/** The LED code for a failed update, shown from this task (never from BLE). */
static void show_ota_failure(void)
{
    if (tank_ota_take_failure()) {
        tank_led_show_error(TANK_ERR_UPDATE_FAILED);
    }
}

tank_ble_window_result_t tank_ble_wait_ota_window(tank_button_hold_t *carry)
{
    if (!s_window_active) {
        return TANK_BLE_WINDOW_DONE;
    }

    tank_button_hold_t hold;
    if (carry) {
        hold = *carry;
    } else {
        tank_button_hold_reset(&hold);
    }
    bool err_grace = false;
    bool stall_kicked = false;
    int64_t reboot_since_us = 0;
    while (s_window_active) {
        if (tank_ota_state() == TANKLINK_OTA_ST_ERR) {
            if (!err_grace) {
                err_grace = true;
                const int64_t need =
                    esp_timer_get_time() + (int64_t)OTA_ERROR_GRACE_MS * 1000;
                if (s_window_deadline_us < need) {
                    s_window_deadline_us = need;
                }
            }
        } else {
            err_grace = false;
        }
        if (tank_ota_state() == TANKLINK_OTA_ST_REBOOTING) {
            if (reboot_since_us == 0) {
                reboot_since_us = esp_timer_get_time();
            } else if (esp_timer_get_time() - reboot_since_us >
                       (int64_t)OTA_REBOOT_FALLBACK_MS * 1000) {
                ESP_LOGE(TAG, "restart after update did not happen — restarting");
                esp_restart();
            }
            vTaskDelay(pdMS_TO_TICKS(200));
            continue;
        }
        if (tank_ota_is_active()) {
            tank_button_hold_reset(&hold);
            const uint32_t idle = tank_ota_idle_ms();
            if (idle >= OTA_STALL_RESTART_MS) {
                ESP_LOGE(TAG, "update stalled %u ms — restarting", (unsigned)idle);
                esp_restart();
            }
            if (idle >= OTA_STALL_DISCONNECT_MS && !stall_kicked) {
                stall_kicked = true;
                const uint16_t conn = tank_ota_owner_conn();
                ESP_LOGW(TAG, "update stalled %u ms — dropping the link", (unsigned)idle);
                if (conn != BLE_HS_CONN_HANDLE_NONE) {
                    (void)ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
                }
            }
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }
        stall_kicked = false;
        if (esp_timer_get_time() >= s_window_deadline_us) {
            ESP_LOGI(TAG, "OTA window timed out");
            break;
        }

        uint32_t held_ms = 0;
        uint8_t pct = 0;
        const tank_button_hold_event_t ev =
            tank_button_hold_poll(&hold, CONFIG_TANK_BUTTON_HOLD_MS, &held_ms, &pct);
        if (ev == TANK_HOLD_HOLDING || ev == TANK_HOLD_REACHED) {
            tank_led_set_brightness(pct);
            /* A hold started near the end of the window still gets to finish. */
            const int64_t need =
                esp_timer_get_time() + (int64_t)CONFIG_TANK_BUTTON_HOLD_MS * 1000;
            if (s_window_deadline_us < need) {
                s_window_deadline_us = need;
            }
        }
        if (ev == TANK_HOLD_REACHED) {
            s_window_active = false;
            ble_gap_adv_stop();
            ESP_LOGI(TAG, "hold during OTA window — pairing");
            return TANK_BLE_WINDOW_PAIR;
        }
        if (ev == TANK_HOLD_RELEASED && held_ms >= 40) {
            tank_led_off();
            s_window_deadline_us = esp_timer_get_time() + (int64_t)s_window_ms * 1000;
            ESP_LOGI(TAG, "short press during OTA window — LoRa TX");
            return TANK_BLE_WINDOW_CLICK;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }

    s_window_active = false;
    ble_gap_adv_stop();
    if (!tank_ota_is_active()) {
        tank_led_off();
    }
    show_ota_failure();
    return TANK_BLE_WINDOW_DONE;
}

