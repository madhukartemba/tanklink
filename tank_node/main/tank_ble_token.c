/*
 * The tank's LoRa link key and the BLE OTA token derived from it.
 *
 * The key is made on first boot. Each pairing makes a new one, sends it in
 * PAIR, and keeps it only once the pump's ACK (tagged with that key) shows
 * the pump took it; a pairing that fails leaves the old link working.
 */
#include "tank_ble_token.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "nvs.h"
#include "tanklink_crypto.h"

#define TAG "TANK_KEY"
#define NVS_NS "tank"
#define NVS_KEY_LINK "link_key"

static uint8_t s_key[TL_KEY_LEN];
static uint8_t s_token[TANKLINK_TOKEN_LEN];

static esp_err_t save_key(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    err = nvs_set_blob(h, NVS_KEY_LINK, s_key, sizeof(s_key));
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

esp_err_t tank_ble_token_init(void)
{
    memset(s_key, 0, sizeof(s_key));
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    size_t len = sizeof(s_key);
    err = nvs_get_blob(h, NVS_KEY_LINK, s_key, &len);
    nvs_close(h);
    if (err != ESP_OK || len != sizeof(s_key) || !tl_nonzero(s_key, sizeof(s_key))) {
        esp_fill_random(s_key, sizeof(s_key));
        err = save_key();
        ESP_LOGI(TAG, "generated new link key");
    } else {
        err = ESP_OK;
    }
    tl_derive_ota_token(s_key, s_token);
    return err;
}

const uint8_t *tank_link_key(void)
{
    return s_key;
}

void tank_link_key_make_pending(uint8_t out[TL_KEY_LEN])
{
    do {
        esp_fill_random(out, TL_KEY_LEN);
    } while (!tl_nonzero(out, TL_KEY_LEN));
}

esp_err_t tank_link_key_commit(const uint8_t key[TL_KEY_LEN])
{
    memcpy(s_key, key, sizeof(s_key));
    tl_derive_ota_token(s_key, s_token);
    ESP_LOGI(TAG, "new link key in use");
    return save_key();
}

const uint8_t *tank_ble_token_bytes(void)
{
    return s_token;
}
