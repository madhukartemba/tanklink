#include "tank_link.h"

#include <string.h>

#include "esp_mac.h"
#include "esp_random.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "sdkconfig.h"
#include "sx1278.h"
#include "tank_ble_token.h"
#include "tank_boot_pins.h"
#include "tank_errors.h"
#include "tank_led.h"
#include "tank_version.h"
#include "tanklink_crypto.h"
#include "tanklink_lora_proto.h"

#define TAG "TANK_LINK"
#define NVS_NS "tank"
#define NVS_KEY_SEQ "seq32"

static uint32_t s_seq;
static bool s_radio_ok;
static uint8_t s_tank_id[TANKLINK_LORA_TANK_ID_LEN];
static uint8_t s_fault;

uint8_t tank_link_fault(void)
{
    return s_fault;
}

void tank_link_set_fault(uint8_t code)
{
    s_fault = code;
}

/* Saved before every send: the pump drops any seq it has already seen, so
 * a recorded packet can't be played back. */
static uint32_t next_seq(void)
{
    s_seq++;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u32(h, NVS_KEY_SEQ, s_seq);
        nvs_commit(h);
        nvs_close(h);
    }
    return s_seq;
}

esp_err_t tank_link_init(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        nvs_get_u32(h, NVS_KEY_SEQ, &s_seq);
        nvs_close(h);
    }

    if (esp_read_mac(s_tank_id, ESP_MAC_WIFI_STA) != ESP_OK) {
        memset(s_tank_id, 0, sizeof(s_tank_id));
    }

    tank_boot_pins_log(TAG);
    if (!tank_boot_pins_ok()) {
        ESP_LOGE(TAG, "refusing LoRa init — fix strap pin wiring (see docs/PINMAPS.md)");
        s_radio_ok = false;
        return ESP_ERR_INVALID_ARG;
    }

    sx1278_config_t cfg = {
        .pin_sck = CONFIG_TANK_LORA_SCK_GPIO,
        .pin_miso = CONFIG_TANK_LORA_MISO_GPIO,
        .pin_mosi = CONFIG_TANK_LORA_MOSI_GPIO,
        .pin_cs = CONFIG_TANK_LORA_CS_GPIO,
        .pin_rst = CONFIG_TANK_LORA_RST_GPIO,
        .pin_dio0 = CONFIG_TANK_LORA_DIO0_GPIO,
        .freq_hz = (uint32_t)CONFIG_TANK_LORA_FREQ_HZ,
    };
    esp_err_t err = sx1278_init(&cfg);
    s_radio_ok = (err == ESP_OK);
    if (!s_radio_ok) {
        ESP_LOGW(TAG, "LoRa init failed — will skip TX (%s)", esp_err_to_name(err));
        return err;
    }
    ESP_LOGI(TAG, "tank_id %02x:%02x:%02x:%02x:%02x:%02x fw=%s", s_tank_id[0],
             s_tank_id[1], s_tank_id[2], s_tank_id[3], s_tank_id[4], s_tank_id[5],
             TANK_FW_VERSION_STR);
    return ESP_OK;
}

void tank_link_deinit_radio(void)
{
    /* Sleep SX1278 and latch SPI pins — floating NSS wakes ~2 mA standby. */
    sx1278_prepare_deep_sleep();
    s_radio_ok = false;
}

bool tank_link_radio_ok(void)
{
    return s_radio_ok;
}

const uint8_t *tank_link_tank_id(void)
{
    return s_tank_id;
}

static bool packet_is_ack_for(const uint8_t *buf, size_t len, uint32_t seq,
                              const uint8_t key[TL_KEY_LEN])
{
    if (len < TANKLINK_LORA_STATUS_LEN) {
        return false;
    }
    const tanklink_lora_status_t *ack = (const tanklink_lora_status_t *)buf;
    if (ack->magic0 != TANKLINK_LORA_MAGIC0 || ack->magic1 != TANKLINK_LORA_MAGIC1) {
        return false;
    }
    if (ack->ver != TANKLINK_LORA_VER ||
        ack->type != TANKLINK_LORA_TYPE_ACK) {
        return false;
    }
    /* Several tanks can share a pump, and seq is per tank: the ACK must be ours,
     * and only the pump that holds our key can tag it. */
    return ack->seq == seq &&
           memcmp(ack->tank_id, s_tank_id, TANKLINK_LORA_TANK_ID_LEN) == 0 &&
           tl_lora_verify(key, buf, len);
}

static bool wait_ack(uint32_t seq, const uint8_t key[TL_KEY_LEN], uint32_t timeout_ms,
                     tank_link_should_cancel_fn should_cancel, void *ctx)
{
    if (sx1278_start_rx() != ESP_OK) {
        return false;
    }
    const TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(timeout_ms);
    uint8_t buf[64];
    while (xTaskGetTickCount() < deadline) {
        if (should_cancel && should_cancel(ctx)) {
            return false;
        }
        size_t n = 0;
        esp_err_t err = sx1278_poll_recv(buf, sizeof(buf), &n);
        if (err == ESP_OK && packet_is_ack_for(buf, n, seq, key)) {
            ESP_LOGI(TAG, "ACK seq=%lu", (unsigned long)seq);
            return true;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    ESP_LOGW(TAG, "ACK timeout seq=%lu", (unsigned long)seq);
    return false;
}

static void fill_status(tanklink_lora_status_t *pkt, const tank_inputs_t *in,
                        uint8_t battery_pct, bool button_event, bool pairing)
{
    memset(pkt, 0, sizeof(*pkt));
    pkt->magic0 = TANKLINK_LORA_MAGIC0;
    pkt->magic1 = TANKLINK_LORA_MAGIC1;
    pkt->ver = TANKLINK_LORA_VER;
    pkt->type = pairing ? TANKLINK_LORA_TYPE_PAIR : TANKLINK_LORA_TYPE_STATUS;
    pkt->battery_pct = battery_pct > 100 ? 100 : battery_pct;
    pkt->seq = next_seq();
    memcpy(pkt->tank_id, s_tank_id, TANKLINK_LORA_TANK_ID_LEN);
    pkt->fw_major = TANK_FW_MAJOR;
    pkt->fw_minor = TANK_FW_MINOR;
    pkt->fw_patch = TANK_FW_PATCH;
    pkt->hw_rev = TANK_HW_REV;
    pkt->fault = s_fault;
    if (in) {
        if (in->sensor1) {
            pkt->flags |= TANKLINK_LORA_FLAG_SENSOR1;
        }
        if (in->sensor2) {
            pkt->flags |= TANKLINK_LORA_FLAG_SENSOR2;
        }
    }
    if (button_event) {
        pkt->flags |= TANKLINK_LORA_FLAG_BTN;
    }
    if (pairing) {
        pkt->flags |= TANKLINK_LORA_FLAG_PAIRING;
    }
}

static esp_err_t send_with_ack(const uint8_t *payload, size_t len, uint32_t seq,
                               const uint8_t key[TL_KEY_LEN],
                               tank_link_should_cancel_fn should_cancel, void *ctx)
{
    if (!s_radio_ok) {
        return ESP_ERR_INVALID_STATE;
    }

    const int attempts = CONFIG_TANK_TX_RETRIES;
    const uint32_t ack_ms = CONFIG_TANK_ACK_TIMEOUT_MS;
    const tanklink_lora_status_t *hdr = (const tanklink_lora_status_t *)payload;

    for (int i = 0; i < attempts; i++) {
        if (should_cancel && should_cancel(ctx)) {
            return ESP_ERR_INVALID_STATE;
        }
        ESP_LOGI(TAG, "TX attempt %d/%d type=%u seq=%lu flags=0x%02x len=%u", i + 1,
                 attempts, hdr->type, (unsigned long)seq, hdr->flags, (unsigned)len);
        esp_err_t err = sx1278_send(payload, len, 2000);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "radio TX failed: %s", esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        if (wait_ack(seq, key, ack_ms, should_cancel, ctx)) {
            return ESP_OK;
        }
        if (should_cancel && should_cancel(ctx)) {
            return ESP_ERR_INVALID_STATE;
        }
        /* Random backoff: two tanks that collided once should not retry in step. */
        vTaskDelay(pdMS_TO_TICKS(40 + esp_random() % 400));
    }
    return ESP_ERR_TIMEOUT;
}

esp_err_t tank_link_send_status(const tank_inputs_t *in, uint8_t battery_pct,
                                bool button_event,
                                tank_link_should_cancel_fn should_cancel, void *ctx)
{
    uint8_t buf[TANKLINK_LORA_STATUS_LEN];
    tanklink_lora_status_t *pkt = (tanklink_lora_status_t *)buf;
    fill_status(pkt, in, battery_pct, button_event, false);
    const uint8_t *key = tank_link_key();
    const size_t len = tl_lora_seal(key, buf, TANKLINK_LORA_STATUS_BODY_LEN);
    esp_err_t err = send_with_ack(buf, len, pkt->seq, key, should_cancel, ctx);
    if (err == ESP_ERR_INVALID_STATE && should_cancel) {
        return err;
    }
    if (err == ESP_OK) {
        tank_led_success();
    } else {
        tank_led_show_error(TANK_ERR_NO_ACK);
    }
    return err;
}

esp_err_t tank_link_send_pair_request(uint8_t battery_pct,
                                      tank_link_should_cancel_fn should_cancel,
                                      void *ctx)
{
    tank_inputs_t in;
    tank_board_read(&in);
    /* A new key every pairing. It is only kept once the pump ACKs with it. */
    uint8_t key[TL_KEY_LEN];
    tank_link_key_make_pending(key);
    uint8_t buf[TANKLINK_LORA_PAIR_LEN];
    tanklink_lora_status_t *pkt = (tanklink_lora_status_t *)buf;
    fill_status(pkt, &in, battery_pct, true, true);
    memcpy(buf + TANKLINK_LORA_STATUS_BODY_LEN, key, sizeof(key));
    const size_t len = tl_lora_seal(key, buf, TANKLINK_LORA_PAIR_BODY_LEN);
    esp_err_t err = send_with_ack(buf, len, pkt->seq, key, should_cancel, ctx);
    if (err == ESP_OK) {
        err = tank_link_key_commit(key);
    }
    memset(key, 0, sizeof(key));
    return err;
}
