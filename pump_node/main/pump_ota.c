#include "pump_ota.h"

#include <string.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "tinycrypt/sha256.h"

#include "pump_api.h"
#include "pump_control.h"
#include "relay_control.h"
#include "status_led.h"
#include "tanklink_uuid.h"

#define TAG "PUMP_OTA"

static const esp_partition_t *s_part;
static esp_ota_handle_t s_handle;
static bool s_active;
static uint8_t s_state = TANKLINK_OTA_ST_IDLE;
static uint8_t s_err = TANKLINK_OTA_ERR_OK;
static uint32_t s_image_size;
static uint32_t s_offset;
static uint8_t s_expect_sha[32];
static struct tc_sha256_state_struct s_sha;
static pump_ota_status_cb_t s_status_cb;
static status_led_mode_t s_led_before;
static bool s_led_hold;
static uint16_t s_owner_conn = BLE_HS_CONN_HANDLE_NONE;
/* Milliseconds since boot, 32-bit so the poll task can't read half a write. */
static volatile uint32_t s_last_activity_ms;
static volatile uint32_t s_rebooting_since_ms;
/* The BLE host, the Wi-Fi API task, the update job and the poll task all call
 * in here. Recursive: an error path calls cleanup and notify under it. */
static SemaphoreHandle_t s_lock;

#define LOCK() xSemaphoreTakeRecursive(s_lock, portMAX_DELAY)
#define UNLOCK() xSemaphoreGiveRecursive(s_lock)

static uint32_t now_ms(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

/* No progress this long: drop the phone's link, so starts are not blocked
 * by a phone that stalled while still connected. */
#define OTA_STALL_DISCONNECT_MS 30000u
/* Still stuck after that: restart. The pump is off during an update and the
 * boot partition only changes after a verified image, so this is safe. */
#define OTA_STALL_RESTART_MS 60000u
/* The restart after a good image normally happens 1.5 s later. */
#define OTA_REBOOT_DEADLINE_MS 10000u

static void notify_status(void)
{
    if (s_status_cb) {
        s_status_cb();
    }
}

static void restore_led_after_ota(void)
{
    status_led_mode_t mode = status_led_get_mode();
    if (mode == STATUS_LED_UPDATING || mode == STATUS_LED_UPDATE_OK ||
        mode == STATUS_LED_UPDATE_ERR) {
        status_led_set_mode(s_led_before == STATUS_LED_UPDATING ||
                                    s_led_before == STATUS_LED_UPDATE_OK ||
                                    s_led_before == STATUS_LED_UPDATE_ERR
                                ? STATUS_LED_IDLE
                                : s_led_before);
    }
}

/* One timer for every error, so a burst of failed writes can't start a task
 * per write (each one used to take a 2 KB stack). */
static esp_timer_handle_t s_err_led_timer;

static void err_led_restore(void *arg)
{
    (void)arg;
    if (status_led_get_mode() == STATUS_LED_UPDATE_ERR) {
        restore_led_after_ota();
    }
}

static void show_ota_err_led(void)
{
    status_led_set_mode(STATUS_LED_UPDATE_ERR);
    esp_timer_stop(s_err_led_timer); /* restart the 2 s if already running */
    ESP_ERROR_CHECK(esp_timer_start_once(s_err_led_timer, 2000 * 1000));
}

static void set_err(uint8_t err)
{
    s_err = err;
    s_state = TANKLINK_OTA_ST_ERR;
    show_ota_err_led();
    notify_status();
}

static void cleanup_session(bool keep_err)
{
    const bool was_updating = (status_led_get_mode() == STATUS_LED_UPDATING) || s_active;
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
        if (s_led_hold) {
            /* pump_update owns the light across its download tries. */
        } else if (was_updating) {
            /* Abort / disconnect mid-OTA — flash red, then restore. */
            show_ota_err_led();
        } else {
            restore_led_after_ota();
        }
    }
    /* keep_err: caller shows UPDATE_ERR via set_err(); leave strip red. */
    relay_control_block(RELAY_BLOCK_OTA, false);
}

static bool is_owner(uint16_t conn_handle)
{
    return s_owner_conn != BLE_HS_CONN_HANDLE_NONE && s_owner_conn == conn_handle;
}

esp_err_t pump_ota_init(void)
{
    s_lock = xSemaphoreCreateRecursiveMutex();
    if (!s_lock) {
        return ESP_ERR_NO_MEM;
    }
    const esp_timer_create_args_t args = {
        .callback = err_led_restore,
        .name = "ota_led_err",
    };
    const esp_err_t err = esp_timer_create(&args, &s_err_led_timer);
    if (err != ESP_OK) {
        return err;
    }
    s_state = TANKLINK_OTA_ST_IDLE;
    s_err = TANKLINK_OTA_ERR_OK;
    s_owner_conn = BLE_HS_CONN_HANDLE_NONE;
    return ESP_OK;
}

bool pump_ota_is_active(void)
{
    return s_active || s_state == TANKLINK_OTA_ST_READY ||
           s_state == TANKLINK_OTA_ST_WRITING ||
           s_state == TANKLINK_OTA_ST_VERIFY_OK ||
           s_state == TANKLINK_OTA_ST_REBOOTING;
}

void pump_ota_set_led_hold(bool hold)
{
    s_led_hold = hold;
}

void pump_ota_set_status_cb(pump_ota_status_cb_t cb)
{
    s_status_cb = cb;
}

uint8_t pump_ota_state(void)
{
    return s_state;
}

uint8_t pump_ota_last_error(void)
{
    return s_err;
}

uint32_t pump_ota_offset(void)
{
    return s_offset;
}

void pump_ota_on_disconnect(uint16_t conn_handle)
{
    LOCK();
    if (is_owner(conn_handle) && s_active) {
        ESP_LOGW(TAG, "OTA owner disconnected — abort");
        cleanup_session(false);
        notify_status();
    }
    UNLOCK();
}

/* Every public entry below takes the lock and calls one of these. */

static uint8_t start_locked(uint16_t conn_handle, uint32_t image_size, const uint8_t sha256[32])
{
    if (s_active || s_state == TANKLINK_OTA_ST_REBOOTING) {
        return TANKLINK_OTA_ERR_BUSY; /* someone else's update: leave its state alone */
    }
    if (!pump_api_id_authed(conn_handle)) {
        set_err(TANKLINK_OTA_ERR_NOT_AUTH);
        return TANKLINK_OTA_ERR_NOT_AUTH;
    }
    /* Safety: never OTA while pumping — force off and block starts. */
    if (pump_control_is_on() != 0) {
        pump_control_set(false, PUMP_CAUSE_SYSTEM);
        set_err(TANKLINK_OTA_ERR_PUMP_ON);
        return TANKLINK_OTA_ERR_PUMP_ON;
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

    /* Erase as the image arrives, a sector at a time, instead of the whole
     * image up front: that took seconds with the BLE host (or Wi-Fi task) stuck. */
    esp_err_t err = esp_ota_begin(s_part, OTA_WITH_SEQUENTIAL_WRITES, &s_handle);
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
    s_last_activity_ms = now_ms();
    s_err = TANKLINK_OTA_ERR_OK;
    s_state = TANKLINK_OTA_ST_READY;
    relay_control_block(RELAY_BLOCK_OTA, true); /* also stops the motor */
    s_led_before = status_led_get_mode();
    status_led_set_mode(STATUS_LED_UPDATING);
    ESP_LOGI(TAG, "OTA start size=%lu part=%s owner=%u",
             (unsigned long)image_size, s_part->label, conn_handle);
    notify_status();
    return TANKLINK_OTA_ERR_OK;
}

static uint8_t write_locked(uint16_t conn_handle, uint32_t offset, const uint8_t *data,
                            uint16_t len)
{
    if (s_state == TANKLINK_OTA_ST_REBOOTING) {
        return TANKLINK_OTA_ERR_BUSY;
    }
    if (!s_active) {
        set_err(TANKLINK_OTA_ERR_STATE);
        return TANKLINK_OTA_ERR_STATE;
    }
    if (!is_owner(conn_handle)) {
        return TANKLINK_OTA_ERR_BUSY; /* not this session's update */
    }
    if (!pump_api_id_authed(conn_handle)) {
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
    s_last_activity_ms = now_ms();
    s_state = TANKLINK_OTA_ST_WRITING;
    s_err = TANKLINK_OTA_ERR_OK;
    if (s_image_size > 0) {
        uint8_t pct = (uint8_t)((s_offset * 100ull) / s_image_size);
        if (pct > 100) {
            pct = 100;
        }
        status_led_set_update_progress(pct);
    }
    /* Notify every ~4KB or on last chunk to limit BLE chatter. */
    if ((s_offset & 0xfff) == 0 || s_offset == s_image_size) {
        notify_status();
    }
    return TANKLINK_OTA_ERR_OK;
}

static uint8_t abort_locked(void)
{
    if (s_state == TANKLINK_OTA_ST_REBOOTING) {
        return TANKLINK_OTA_ERR_BUSY; /* the new image is already set to boot */
    }
    if (!s_active && s_state == TANKLINK_OTA_ST_IDLE) {
        return TANKLINK_OTA_ERR_OK;
    }
    cleanup_session(false);
    ESP_LOGW(TAG, "OTA aborted");
    notify_status();
    return TANKLINK_OTA_ERR_OK;
}

static uint8_t abort_from_locked(uint16_t conn_handle)
{
    if (!s_active && s_state == TANKLINK_OTA_ST_IDLE) {
        return TANKLINK_OTA_ERR_OK;
    }
    if (s_owner_conn != BLE_HS_CONN_HANDLE_NONE && !is_owner(conn_handle)) {
        return TANKLINK_OTA_ERR_NOT_AUTH;
    }
    return abort_locked();
}

static void reboot_task(void *arg)
{
    (void)arg;
    /* Hold green success long enough to read on the strip. */
    vTaskDelay(pdMS_TO_TICKS(1500));
    esp_restart();
}

static uint8_t finish_locked(uint16_t conn_handle)
{
    if (s_state == TANKLINK_OTA_ST_REBOOTING) {
        return TANKLINK_OTA_ERR_BUSY;
    }
    if (!s_active) {
        set_err(TANKLINK_OTA_ERR_STATE);
        return TANKLINK_OTA_ERR_STATE;
    }
    if (!is_owner(conn_handle)) {
        return TANKLINK_OTA_ERR_BUSY;
    }
    if (!pump_api_id_authed(conn_handle)) {
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
    if (err == ESP_OK) {
        err = esp_ota_set_boot_partition(s_part);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "set_boot: %s", esp_err_to_name(err));
        }
    } else {
        ESP_LOGE(TAG, "esp_ota_end: %s", esp_err_to_name(err));
    }
    if (err != ESP_OK) {
        /* The image was rejected (check or signature): the session is over,
         * so the pump may start again. */
        cleanup_session(true);
        set_err(TANKLINK_OTA_ERR_FLASH);
        return TANKLINK_OTA_ERR_FLASH;
    }

    s_state = TANKLINK_OTA_ST_VERIFY_OK;
    s_err = TANKLINK_OTA_ERR_OK;
    status_led_set_mode(STATUS_LED_UPDATE_OK);
    notify_status();
    s_rebooting_since_ms = now_ms(); /* before the state, which the poll reads */
    s_state = TANKLINK_OTA_ST_REBOOTING;
    notify_status();
    ESP_LOGI(TAG, "OTA OK — rebooting");
    if (xTaskCreate(reboot_task, "ota_reboot", 2048, NULL, 5, NULL) != pdPASS) {
        esp_restart(); /* the new image is already the boot partition */
    }
    return TANKLINK_OTA_ERR_OK;
}

static void poll_locked(void)
{
    const uint32_t now = now_ms();
    if (s_state == TANKLINK_OTA_ST_REBOOTING) {
        if (now - s_rebooting_since_ms > OTA_REBOOT_DEADLINE_MS) {
            ESP_LOGE(TAG, "restart after update did not happen — restarting");
            esp_restart();
        }
        return;
    }
    if (!s_active) {
        return;
    }
    const uint32_t idle = now - s_last_activity_ms;
    if (idle > OTA_STALL_RESTART_MS) {
        ESP_LOGE(TAG, "update stalled %u s — restarting", (unsigned)(idle / 1000));
        esp_restart();
    }
    if (idle > OTA_STALL_DISCONNECT_MS) {
        const uint16_t conn = s_owner_conn;
        if (conn != BLE_HS_CONN_HANDLE_NONE) {
            ESP_LOGW(TAG, "update stalled %u s — dropping the link", (unsigned)(idle / 1000));
            pump_api_drop_id(conn);
        }
    }
}

uint8_t pump_ota_start(uint16_t conn_handle, uint32_t image_size, const uint8_t sha256[32])
{
    LOCK();
    const uint8_t r = start_locked(conn_handle, image_size, sha256);
    UNLOCK();
    return r;
}

uint8_t pump_ota_write(uint16_t conn_handle, uint32_t offset, const uint8_t *data, uint16_t len)
{
    LOCK();
    const uint8_t r = write_locked(conn_handle, offset, data, len);
    UNLOCK();
    return r;
}

uint8_t pump_ota_abort(void)
{
    LOCK();
    const uint8_t r = abort_locked();
    UNLOCK();
    return r;
}

uint8_t pump_ota_abort_from(uint16_t conn_handle)
{
    LOCK();
    const uint8_t r = abort_from_locked(conn_handle);
    UNLOCK();
    return r;
}

uint8_t pump_ota_finish(uint16_t conn_handle)
{
    LOCK();
    const uint8_t r = finish_locked(conn_handle);
    UNLOCK();
    return r;
}

void pump_ota_poll(void)
{
    /* Never wait here: this runs on the watched poll task, and a flash write
     * may hold the lock for a while. The next poll comes in 500 ms. */
    if (xSemaphoreTakeRecursive(s_lock, 0) != pdTRUE) {
        return;
    }
    poll_locked();
    UNLOCK();
}
