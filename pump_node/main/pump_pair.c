#include "pump_pair.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"
#include "status_led.h"

#define TAG "PUMP_PAIR"
#define NVS_NS "tl_pair"
#define NVS_KEY_BLOB "pair"

#ifndef CONFIG_PUMP_PAIRING_TIMEOUT_MS
#define CONFIG_PUMP_PAIRING_TIMEOUT_MS 60000
#endif

typedef struct {
    uint8_t paired;
    uint8_t device_id[TANKLINK_DEVICE_ID_LEN];
    uint8_t token[TANKLINK_TOKEN_LEN];
} pump_pair_blob_t;

static pump_pair_blob_t s_pair;
static bool s_pairing_active;
static int64_t s_pairing_deadline_us;
static char s_serial[TANKLINK_SERIAL_LEN + 1];
static char s_adv_name[TANKLINK_ADV_NAME_MAX];

static void refresh_identity_strings(void)
{
    snprintf(s_serial, sizeof(s_serial), "%02X%02X",
             s_pair.device_id[4], s_pair.device_id[5]);
    snprintf(s_adv_name, sizeof(s_adv_name), "%s%s",
             TANKLINK_DEVICE_NAME_PREFIX, s_serial);
}

static esp_err_t save_blob(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY_BLOB, &s_pair, sizeof(s_pair));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

static void refresh_led_for_pair_state(void)
{
    if (s_pairing_active) {
        status_led_set_mode(STATUS_LED_PAIRING);
    } else if (!s_pair.paired) {
        status_led_set_mode(STATUS_LED_UNPAIRED);
    } else {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

esp_err_t pump_pair_init(void)
{
    memset(&s_pair, 0, sizeof(s_pair));
    s_pairing_active = false;
    refresh_identity_strings();

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        esp_fill_random(s_pair.device_id, sizeof(s_pair.device_id));
        s_pair.paired = 0;
        refresh_identity_strings();
        save_blob();
        s_pairing_active = true; /* first boot: open for claim */
        s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
        refresh_led_for_pair_state();
        ESP_LOGI(TAG, "First boot serial=%s", s_serial);
        return ESP_OK;
    }
    if (err != ESP_OK) {
        return err;
    }

    size_t len = sizeof(s_pair);
    err = nvs_get_blob(h, NVS_KEY_BLOB, &s_pair, &len);
    nvs_close(h);

    if (err != ESP_OK || len != sizeof(s_pair)) {
        esp_fill_random(s_pair.device_id, sizeof(s_pair.device_id));
        s_pair.paired = 0;
        memset(s_pair.token, 0, sizeof(s_pair.token));
        refresh_identity_strings();
        save_blob();
        s_pairing_active = true;
        s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
        refresh_led_for_pair_state();
        return ESP_OK;
    }

    refresh_identity_strings();
    if (!s_pair.paired) {
        s_pairing_active = true;
        s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
        ESP_LOGI(TAG, "UNPAIRED serial=%s", s_serial);
    } else {
        ESP_LOGI(TAG, "PAIRED serial=%s — hold button 5s to re-pair", s_serial);
    }
    refresh_led_for_pair_state();
    return ESP_OK;
}

esp_err_t pump_pair_set_mac_identity(const uint8_t mac[6])
{
    if (!mac) {
        return ESP_ERR_INVALID_ARG;
    }
    if (memcmp(s_pair.device_id, mac, TANKLINK_DEVICE_ID_LEN) == 0) {
        refresh_identity_strings();
        return ESP_OK;
    }
    memcpy(s_pair.device_id, mac, TANKLINK_DEVICE_ID_LEN);
    refresh_identity_strings();
    ESP_LOGI(TAG, "Identity from MAC → serial=%s", s_serial);
    return save_blob();
}

const char *pump_pair_serial(void)
{
    return s_serial;
}

const char *pump_pair_adv_name(void)
{
    return s_adv_name;
}

bool pump_pair_is_paired(void)
{
    return s_pair.paired != 0;
}

bool pump_pair_pairing_active(void)
{
    return s_pairing_active;
}

bool pump_pair_is_claimable(void)
{
    return !s_pair.paired || s_pairing_active;
}

const uint8_t *pump_pair_device_id(void)
{
    return s_pair.device_id;
}

const uint8_t *pump_pair_token(void)
{
    return s_pair.token;
}

esp_err_t pump_pair_enter_pairing_mode(void)
{
    s_pairing_active = true;
    s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
    ESP_LOGI(TAG, "Pairing window open (%d ms)", CONFIG_PUMP_PAIRING_TIMEOUT_MS);
    refresh_led_for_pair_state();
    return ESP_OK;
}

void pump_pair_exit_pairing_mode(void)
{
    if (!s_pairing_active) {
        return;
    }
    s_pairing_active = false;
    ESP_LOGI(TAG, "Pairing window closed");
    refresh_led_for_pair_state();
}

void pump_pair_poll(void)
{
    if (!s_pairing_active) {
        return;
    }
    /* Pairing LED/window always expires; unpaired pumps stay claimable
     * via pump_pair_is_claimable() even after the window closes. */
    if (esp_timer_get_time() >= s_pairing_deadline_us) {
        pump_pair_exit_pairing_mode();
    }
}

esp_err_t pump_pair_claim(uint8_t out_token[TANKLINK_TOKEN_LEN])
{
    if (!pump_pair_is_claimable()) {
        return ESP_ERR_INVALID_STATE;
    }
    /*
     * One shared token for every paired phone/tablet.
     * First claim (unpaired) creates it; later claims during a pairing
     * window hand out the same token so additional devices can join
     * without invalidating phones that already have it.
     */
    if (!s_pair.paired) {
        esp_fill_random(s_pair.token, TANKLINK_TOKEN_LEN);
        s_pair.paired = 1;
        esp_err_t err = save_blob();
        if (err != ESP_OK) {
            return err;
        }
        ESP_LOGI(TAG, "CLAIMED new token serial=%s", s_serial);
    } else {
        ESP_LOGI(TAG, "CLAIMED shared token serial=%s", s_serial);
    }
    memcpy(out_token, s_pair.token, TANKLINK_TOKEN_LEN);
    /* Keep pairing window open until timeout so multiple devices can claim. */
    refresh_led_for_pair_state();
    return ESP_OK;
}

esp_err_t pump_pair_unpair(void)
{
    s_pair.paired = 0;
    memset(s_pair.token, 0, sizeof(s_pair.token));
    esp_err_t err = save_blob();
    if (err != ESP_OK) {
        return err;
    }
    s_pairing_active = true;
    s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
    ESP_LOGI(TAG, "UNPAIRED via command serial=%s", s_serial);
    refresh_led_for_pair_state();
    return ESP_OK;
}

bool pump_pair_check_token(const uint8_t *token, size_t len)
{
    if (!s_pair.paired || !token || len != TANKLINK_TOKEN_LEN) {
        return false;
    }
    return memcmp(token, s_pair.token, TANKLINK_TOKEN_LEN) == 0;
}
