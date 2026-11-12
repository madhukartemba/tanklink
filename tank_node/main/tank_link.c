#include "tank_link.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "sdkconfig.h"
#include "sx1278.h"
#include "tank_board.h"
#include "tanklink_lora_proto.h"

#define TAG "TANK_LINK"
#define NVS_NS "tank"
#define NVS_KEY_SEQ "seq"

static uint16_t s_seq;
static bool s_radio_ok;

static uint16_t next_seq(void)
{
    s_seq++;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u16(h, NVS_KEY_SEQ, s_seq);
        nvs_commit(h);
        nvs_close(h);
    }
    return s_seq;
}

esp_err_t tank_link_init(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
        nvs_get_u16(h, NVS_KEY_SEQ, &s_seq);
        nvs_close(h);
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
    return ESP_OK;
}

void tank_link_deinit_radio(void)
{
    if (s_radio_ok) {
        sx1278_sleep();
    }
}

static void led_tx_attempt(void)
{
    tank_led_set(true);
    vTaskDelay(pdMS_TO_TICKS(35));
    tank_led_set(false);
}

static void led_success(void)
{
    /* Two calm blinks = ACK OK */
    tank_led_blink(2, 160, 120);
}

static void led_failure(void)
{
    /* Fast chatter = no ACK */
    tank_led_blink(5, 50, 50);
}

static void led_pairing_start(void)
{
    tank_led_blink(8, 60, 60);
}

static bool packet_is_ack_for(const uint8_t *buf, size_t len, uint16_t seq)
{
    if (len < sizeof(tanklink_lora_status_t)) {
        return false;
    }
    const tanklink_lora_status_t *ack = (const tanklink_lora_status_t *)buf;
    if (ack->magic0 != TANKLINK_LORA_MAGIC0 || ack->magic1 != TANKLINK_LORA_MAGIC1) {
        return false;
    }
    if (ack->ver != TANKLINK_LORA_VER || ack->type != TANKLINK_LORA_TYPE_ACK) {
        return false;
    }
    return ack->seq == seq;
}

static bool wait_ack(uint16_t seq, uint32_t timeout_ms)
{
    if (sx1278_start_rx() != ESP_OK) {
        return false;
    }
    const TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(timeout_ms);
    uint8_t buf[64];
    while (xTaskGetTickCount() < deadline) {
        size_t n = 0;
        esp_err_t err = sx1278_poll_recv(buf, sizeof(buf), &n);
        if (err == ESP_OK && packet_is_ack_for(buf, n, seq)) {
            ESP_LOGI(TAG, "ACK seq=%u", seq);
            return true;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    ESP_LOGW(TAG, "ACK timeout seq=%u", seq);
    return false;
}

static esp_err_t send_with_ack(tanklink_lora_status_t *pkt)
{
    if (!s_radio_ok) {
        led_failure();
        return ESP_ERR_INVALID_STATE;
    }

    const int attempts = CONFIG_TANK_TX_RETRIES;
    const uint32_t ack_ms = CONFIG_TANK_ACK_TIMEOUT_MS;

    for (int i = 0; i < attempts; i++) {
        ESP_LOGI(TAG, "TX attempt %d/%d type=%u seq=%u flags=0x%02x", i + 1, attempts,
                 pkt->type, pkt->seq, pkt->flags);
        led_tx_attempt();
        esp_err_t err = sx1278_send((const uint8_t *)pkt, sizeof(*pkt), 2000);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "radio TX failed: %s", esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        if (wait_ack(pkt->seq, ack_ms)) {
            led_success();
            return ESP_OK;
        }
        /* Brief gap before retry */
        vTaskDelay(pdMS_TO_TICKS(40));
    }

    led_failure();
    return ESP_ERR_TIMEOUT;
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
    if (in) {
        if (in->full) {
            pkt->flags |= TANKLINK_LORA_FLAG_FULL;
        }
        if (in->empty) {
            pkt->flags |= TANKLINK_LORA_FLAG_EMPTY;
        }
    }
    if (button_event) {
        pkt->flags |= TANKLINK_LORA_FLAG_BTN;
    }
    if (pairing) {
        pkt->flags |= TANKLINK_LORA_FLAG_PAIRING;
    }
}

esp_err_t tank_link_send_status(const tank_inputs_t *in, uint8_t battery_pct,
                                bool button_event)
{
    tanklink_lora_status_t pkt;
    fill_status(&pkt, in, battery_pct, button_event, false);
    return send_with_ack(&pkt);
}

esp_err_t tank_link_send_pair_request(uint8_t battery_pct)
{
    tank_inputs_t in;
    tank_board_read(&in);
    led_pairing_start();
    tanklink_lora_status_t pkt;
    fill_status(&pkt, &in, battery_pct, true, true);
    esp_err_t err = send_with_ack(&pkt);
    /* send_with_ack already blinked success/fail */
    return err;
}
