#include "pump_pair.h"

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "gatt_svr.h"
#include "pump_control.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "relay_control.h"
#include "sdkconfig.h"
#include "pump_alert.h"
#include "status_led.h"
#include "tanklink_crypto.h"

#define TAG "PUMP_PAIR"
#define NVS_NS "tl_pair"
#define NVS_KEY_BLOB "pair"

#ifndef CONFIG_PUMP_PAIRING_TIMEOUT_MS
#define CONFIG_PUMP_PAIRING_TIMEOUT_MS 60000
#endif

/* One token per phone, so one lost phone can be signed out on its own. */
typedef struct {
    uint8_t phones; /* bit i set = tokens[i] in use */
    uint8_t device_id[TANKLINK_DEVICE_ID_LEN];
    uint8_t tokens[PUMP_PAIR_PHONES_MAX][TANKLINK_TOKEN_LEN];
} pump_pair_blob_t;
_Static_assert(PUMP_PAIR_PHONES_MAX <= 8, "phones mask is 8 bits");

static pump_pair_blob_t s_pair;
static bool s_pairing_active;
static int64_t s_pairing_deadline_us;
static char s_serial[TANKLINK_SERIAL_LEN + 1];
static char s_adv_name[TANKLINK_ADV_NAME_MAX];
static void (*s_change_cb)(void);

void pump_pair_set_change_callback(void (*cb)(void))
{
    s_change_cb = cb;
}

static void notify_change(void)
{
    if (s_change_cb) {
        s_change_cb();
    }
}

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
    } else if (!s_pair.phones) {
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
        s_pair.phones = 0;
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

    if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND && err != ESP_ERR_NVS_INVALID_LENGTH) {
        /* A read error is not "never paired": a new identity saved over the
         * old one would unpair every phone. Stay locked until a restart. */
        memset(&s_pair, 0, sizeof(s_pair));
        refresh_identity_strings();
        ESP_LOGE(TAG, "pairing read failed: %s", esp_err_to_name(err));
        return err;
    }
    if (err != ESP_OK || len != sizeof(s_pair)) {
        memset(&s_pair, 0, sizeof(s_pair));
        esp_fill_random(s_pair.device_id, sizeof(s_pair.device_id));
        refresh_identity_strings();
        save_blob();
        s_pairing_active = true;
        s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
        refresh_led_for_pair_state();
        return ESP_OK;
    }

    refresh_identity_strings();
    if (!s_pair.phones) {
        /* Unpaired at power-up: open the window for a while, as on first boot. */
        s_pairing_active = true;
        s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
        ESP_LOGI(TAG, "UNPAIRED serial=%s", s_serial);
    } else {
        ESP_LOGI(TAG, "PAIRED serial=%s phones=0x%02x", s_serial, s_pair.phones);
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
    return s_pair.phones != 0;
}

bool pump_pair_pairing_active(void)
{
    return s_pairing_active;
}

/* Only while the window is open (button hold, first boot or a signed-in
 * phone's 0xF2). An unpaired pump whose window has closed needs the button. */
bool pump_pair_is_claimable(void)
{
    return s_pairing_active;
}

const uint8_t *pump_pair_device_id(void)
{
    return s_pair.device_id;
}

esp_err_t pump_pair_enter_pairing_mode(void)
{
    /* Diverting activity — pump must be off and stay off. */
    pump_control_set(false, PUMP_CAUSE_SYSTEM);
    relay_control_block(RELAY_BLOCK_PAIRING, true);
    s_pairing_active = true;
    s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
    ESP_LOGI(TAG, "Pairing window open (%d ms)", CONFIG_PUMP_PAIRING_TIMEOUT_MS);
    refresh_led_for_pair_state();
    notify_change();
    return ESP_OK;
}

void pump_pair_exit_pairing_mode(void)
{
    if (!s_pairing_active) {
        return;
    }
    s_pairing_active = false;
    relay_control_block(RELAY_BLOCK_PAIRING, false);
    ESP_LOGI(TAG, "Pairing window closed");
    refresh_led_for_pair_state();
    notify_change();
}

void pump_pair_poll(void)
{
    if (!s_pairing_active) {
        return;
    }
    /* The window always expires, paired or not. */
    if (esp_timer_get_time() >= s_pairing_deadline_us) {
        pump_pair_exit_pairing_mode();
    }
}

esp_err_t pump_pair_claim(uint8_t out_token[TANKLINK_TOKEN_LEN], int *out_phone)
{
    if (!pump_pair_is_claimable()) {
        return ESP_ERR_INVALID_STATE;
    }
    int phone = -1;
    for (int i = 0; i < PUMP_PAIR_PHONES_MAX; i++) {
        if (!(s_pair.phones & (1u << i))) {
            phone = i;
            break;
        }
    }
    if (phone < 0) {
        ESP_LOGW(TAG, "claim refused: %d phones already", PUMP_PAIR_PHONES_MAX);
        return ESP_ERR_NO_MEM;
    }
    /* Each phone gets its own token. */
    do {
        esp_fill_random(s_pair.tokens[phone], TANKLINK_TOKEN_LEN);
    } while (!tl_nonzero(s_pair.tokens[phone], TANKLINK_TOKEN_LEN));
    s_pair.phones |= (uint8_t)(1u << phone);
    esp_err_t err = save_blob();
    if (err != ESP_OK) {
        s_pair.phones &= (uint8_t)~(1u << phone);
        return err;
    }
    ESP_LOGI(TAG, "CLAIMED phone %d serial=%s", phone, s_serial);
    memcpy(out_token, s_pair.tokens[phone], TANKLINK_TOKEN_LEN);
    *out_phone = phone;
    /* One phone per window: the next one needs the window opened again. */
    pump_pair_exit_pairing_mode(); /* notifies */
    return ESP_OK;
}

int pump_pair_check_response(const uint8_t nonce[TL_NONCE_LEN],
                             const uint8_t resp[TL_AUTH_RESP_LEN])
{
    int found = -1;
    for (int i = 0; i < PUMP_PAIR_PHONES_MAX; i++) {
        if (!(s_pair.phones & (1u << i))) {
            continue;
        }
        uint8_t want[TL_AUTH_RESP_LEN];
        tl_auth_response(s_pair.tokens[i], nonce, want);
        if (tl_ct_equal(want, resp, sizeof(want))) {
            found = i;
        }
    }
    return found;
}

bool pump_pair_phone_token(int phone, uint8_t out[TANKLINK_TOKEN_LEN])
{
    if (phone < 0 || phone >= PUMP_PAIR_PHONES_MAX || !(s_pair.phones & (1u << phone))) {
        return false;
    }
    memcpy(out, s_pair.tokens[phone], TANKLINK_TOKEN_LEN);
    return true;
}

int pump_pair_phone_count(void)
{
    return __builtin_popcount(s_pair.phones);
}

esp_err_t pump_pair_forget_others(int keep_phone)
{
    if (keep_phone < 0 || keep_phone >= PUMP_PAIR_PHONES_MAX ||
        !(s_pair.phones & (1u << keep_phone))) {
        return ESP_ERR_INVALID_ARG;
    }
    for (int i = 0; i < PUMP_PAIR_PHONES_MAX; i++) {
        if (i != keep_phone) {
            memset(s_pair.tokens[i], 0, TANKLINK_TOKEN_LEN);
        }
    }
    s_pair.phones = (uint8_t)(1u << keep_phone);
    ESP_LOGI(TAG, "signed out every phone but %d", keep_phone);
    pump_alert_phones_removed(true); /* the removed phones' key is now useless */
    return save_blob();
}

esp_err_t pump_pair_unpair(void)
{
    pump_control_set(false, PUMP_CAUSE_SYSTEM);
    relay_control_block(RELAY_BLOCK_PAIRING, true);
    s_pair.phones = 0;
    memset(s_pair.tokens, 0, sizeof(s_pair.tokens));
    esp_err_t err = save_blob();
    if (err != ESP_OK) {
        relay_control_block(RELAY_BLOCK_PAIRING, false);
        return err;
    }
    s_pairing_active = true;
    s_pairing_deadline_us = esp_timer_get_time() + (int64_t)CONFIG_PUMP_PAIRING_TIMEOUT_MS * 1000;
    pump_alert_phones_removed(false);
    ESP_LOGI(TAG, "UNPAIRED via command serial=%s", s_serial);
    refresh_led_for_pair_state();
    notify_change();
    return ESP_OK;
}
