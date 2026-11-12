#include "tank_ble_token.h"

#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "nvs.h"

#define TAG "TANK_TOK"
#define NVS_NS "tank"
#define NVS_KEY_TOKEN "ble_tok"

static uint8_t s_token[TANKLINK_TOKEN_LEN];

esp_err_t tank_ble_token_init(void)
{
    memset(s_token, 0, sizeof(s_token));
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    size_t len = sizeof(s_token);
    err = nvs_get_blob(h, NVS_KEY_TOKEN, s_token, &len);
    if (err != ESP_OK || len != sizeof(s_token)) {
        esp_fill_random(s_token, sizeof(s_token));
        err = nvs_set_blob(h, NVS_KEY_TOKEN, s_token, sizeof(s_token));
        if (err == ESP_OK) {
            err = nvs_commit(h);
        }
        ESP_LOGI(TAG, "generated new BLE OTA token");
    } else {
        ESP_LOGI(TAG, "loaded BLE OTA token");
    }
    nvs_close(h);
    return err;
}

const uint8_t *tank_ble_token_bytes(void)
{
    return s_token;
}

bool tank_ble_token_check(const uint8_t *token, size_t len)
{
    if (!token || len != TANKLINK_TOKEN_LEN) {
        return false;
    }
    return memcmp(token, s_token, TANKLINK_TOKEN_LEN) == 0;
}
