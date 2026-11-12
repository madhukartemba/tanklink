#include "tank_ota.h"

#include <string.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "tinycrypt/sha256.h"

#include "tank_gatt.h"
#include "tank_led.h"
#include "tanklink_ble_uuid.h"

#define TAG "TANK_OTA"

static const esp_partition_t *s_part;
static esp_ota_handle_t s_handle;
static bool s_active;
static uint8_t s_state = TANKLINK_OTA_ST_IDLE;
static uint8_t s_err = TANKLINK_OTA_ERR_OK;
static uint32_t s_image_size;
static uint32_t s_offset;
static uint8_t s_expect_sha[32];
static struct tc_sha256_state_struct s_sha;
static tank_ota_status_cb_t s_status_cb;
static uint16_t s_owner_conn = BLE_HS_CONN_HANDLE_NONE;

static void notify_status(void)
{
    if (s_status_cb) {
        s_status_cb();
    }
}

static void set_err(uint8_t err)
{
    s_err = err;
    s_state = TANKLINK_OTA_ST_ERR;
    tank_led_show_error(3);
    notify_status();
}

static void cleanup_session(bool keep_err)
{
    if (s_active) {
        esp_ota_abort(s_handle);
        s_active = false;
        s_handle = 0;
        s_part = NULL;
    }
    s_offset = 0;
    s_image_size = 0;
    s_owner_conn = BLE_HS_CONN_HANDLE_NONE;
    if (!keep_err) {
        s_err = TANKLINK_OTA_ERR_OK;
        s_state = TANKLINK_OTA_ST_IDLE;
    }
}

static bool is_owner(uint16_t conn_handle)
{
    return s_owner_conn != BLE_HS_CONN_HANDLE_NONE && s_owner_conn == conn_handle;
}

esp_err_t tank_ota_init(void)
{
    s_state = TANKLINK_OTA_ST_IDLE;
    s_err = TANKLINK_OTA_ERR_OK;
    s_owner_conn = BLE_HS_CONN_HANDLE_NONE;
    return ESP_OK;
}

bool tank_ota_is_active(void)
{
    return s_active || s_state == TANKLINK_OTA_ST_READY ||
           s_state == TANKLINK_OTA_ST_WRITING ||
           s_state == TANKLINK_OTA_ST_VERIFY_OK ||
           s_state == TANKLINK_OTA_ST_REBOOTING;
}

void tank_ota_set_status_cb(tank_ota_status_cb_t cb)
{
    s_status_cb = cb;
}

uint8_t tank_ota_state(void)
{
    return s_state;
}

uint8_t tank_ota_last_error(void)
{
    return s_err;
}

uint32_t tank_ota_offset(void)
{
    return s_offset;
}

void tank_ota_on_disconnect(uint16_t conn_handle)
{
    if (is_owner(conn_handle) && tank_ota_is_active()) {
        ESP_LOGW(TAG, "OTA owner disconnected — abort");
        cleanup_session(false);
        notify_status();
    }
}

uint8_t tank_ota_start(uint16_t conn_handle, uint32_t image_size, const uint8_t sha256[32])
{
    if (!tank_gatt_is_authed_conn(conn_handle)) {
        set_err(TANKLINK_OTA_ERR_NOT_AUTH);
        return TANKLINK_OTA_ERR_NOT_AUTH;
    }
    if (s_active || s_state == TANKLINK_OTA_ST_REBOOTING) {
        set_err(TANKLINK_OTA_ERR_BUSY);
        return TANKLINK_OTA_ERR_BUSY;
    }
    if (image_size < 1024 || image_size > (0x1C0000u - 0x20u) || sha256 == NULL) {
        set_err(TANKLINK_OTA_ERR_BAD_PARAM);
        return TANKLINK_OTA_ERR_BAD_PARAM;
    }

    cleanup_session(false);

    s_part = esp_ota_get_next_update_partition(NULL);
    if (!s_part) {
        ESP_LOGE(TAG, "no OTA partition");
        set_err(TANKLINK_OTA_ERR_FLASH);
        return TANKLINK_OTA_ERR_FLASH;
    }
    if (image_size > s_part->size) {
        set_err(TANKLINK_OTA_ERR_BAD_PARAM);
        return TANKLINK_OTA_ERR_BAD_PARAM;
    }

    esp_err_t err = esp_ota_begin(s_part, image_size, &s_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_begin: %s", esp_err_to_name(err));
        set_err(TANKLINK_OTA_ERR_FLASH);
        return TANKLINK_OTA_ERR_FLASH;
    }

    (void)tc_sha256_init(&s_sha);
    memcpy(s_expect_sha, sha256, 32);
    s_image_size = image_size;
    s_offset = 0;
    s_active = true;
    s_owner_conn = conn_handle;
    s_err = TANKLINK_OTA_ERR_OK;
    s_state = TANKLINK_OTA_ST_READY;
    tank_led_pairing_flash_start();
    ESP_LOGI(TAG, "OTA start size=%lu part=%s", (unsigned long)image_size, s_part->label);
    notify_status();
    return TANKLINK_OTA_ERR_OK;
}

uint8_t tank_ota_write(uint16_t conn_handle, uint32_t offset, const uint8_t *data, uint16_t len)
{
    if (!s_active) {
        set_err(TANKLINK_OTA_ERR_STATE);
        return TANKLINK_OTA_ERR_STATE;
    }
    if (!is_owner(conn_handle) || !tank_gatt_is_authed_conn(conn_handle)) {
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_NOT_AUTH);
        return TANKLINK_OTA_ERR_NOT_AUTH;
    }
    if (offset != s_offset || data == NULL || len == 0) {
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_BAD_PARAM);
        return TANKLINK_OTA_ERR_BAD_PARAM;
    }
    if (s_offset + len > s_image_size) {
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_BAD_PARAM);
        return TANKLINK_OTA_ERR_BAD_PARAM;
    }

    esp_err_t err = esp_ota_write(s_handle, data, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_write: %s", esp_err_to_name(err));
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_FLASH);
        return TANKLINK_OTA_ERR_FLASH;
    }

    (void)tc_sha256_update(&s_sha, data, len);
    s_offset += len;
    s_state = TANKLINK_OTA_ST_WRITING;
    s_err = TANKLINK_OTA_ERR_OK;
    tank_led_pairing_flash_tick();
    if ((s_offset & 0xfff) == 0 || s_offset == s_image_size) {
        notify_status();
    }
    return TANKLINK_OTA_ERR_OK;
}

uint8_t tank_ota_abort(void)
{
    if (!s_active && s_state == TANKLINK_OTA_ST_IDLE) {
        return TANKLINK_OTA_ERR_OK;
    }
    cleanup_session(false);
    tank_led_pairing_flash_stop();
    tank_led_off();
    ESP_LOGW(TAG, "OTA aborted");
    notify_status();
    return TANKLINK_OTA_ERR_OK;
}

uint8_t tank_ota_abort_from(uint16_t conn_handle)
{
    if (!s_active && s_state == TANKLINK_OTA_ST_IDLE) {
        return TANKLINK_OTA_ERR_OK;
    }
    if (s_owner_conn != BLE_HS_CONN_HANDLE_NONE && !is_owner(conn_handle)) {
        return TANKLINK_OTA_ERR_NOT_AUTH;
    }
    return tank_ota_abort();
}

static void reboot_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(1200));
    esp_restart();
}

uint8_t tank_ota_finish(uint16_t conn_handle)
{
    if (!s_active) {
        set_err(TANKLINK_OTA_ERR_STATE);
        return TANKLINK_OTA_ERR_STATE;
    }
    if (!is_owner(conn_handle) || !tank_gatt_is_authed_conn(conn_handle)) {
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_NOT_AUTH);
        return TANKLINK_OTA_ERR_NOT_AUTH;
    }
    if (s_offset != s_image_size) {
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_BAD_PARAM);
        return TANKLINK_OTA_ERR_BAD_PARAM;
    }

    uint8_t got[32];
    (void)tc_sha256_final(got, &s_sha);
    if (memcmp(got, s_expect_sha, 32) != 0) {
        ESP_LOGE(TAG, "SHA-256 mismatch");
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_HASH);
        return TANKLINK_OTA_ERR_HASH;
    }

    esp_err_t err = esp_ota_end(s_handle);
    s_active = false;
    s_handle = 0;
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_end: %s", esp_err_to_name(err));
        s_part = NULL;
        s_owner_conn = BLE_HS_CONN_HANDLE_NONE;
        set_err(TANKLINK_OTA_ERR_FLASH);
        return TANKLINK_OTA_ERR_FLASH;
    }

    err = esp_ota_set_boot_partition(s_part);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "set_boot: %s", esp_err_to_name(err));
        s_part = NULL;
        s_owner_conn = BLE_HS_CONN_HANDLE_NONE;
        set_err(TANKLINK_OTA_ERR_FLASH);
        return TANKLINK_OTA_ERR_FLASH;
    }

    tank_led_pairing_flash_stop();
    tank_led_success();
    s_state = TANKLINK_OTA_ST_VERIFY_OK;
    s_err = TANKLINK_OTA_ERR_OK;
    notify_status();
    s_state = TANKLINK_OTA_ST_REBOOTING;
    notify_status();
    ESP_LOGI(TAG, "OTA OK — rebooting");
    xTaskCreate(reboot_task, "tank_ota_rb", 2048, NULL, 5, NULL);
    return TANKLINK_OTA_ERR_OK;
}
