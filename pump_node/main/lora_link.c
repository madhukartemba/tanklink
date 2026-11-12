#include "lora_link.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "gatt_svr.h"
#include "nvs.h"
#include "pump_errors.h"
#include "pump_pair.h"
#include "relay_control.h"
#include "sdkconfig.h"
#include "status_led.h"
#include "sx1278.h"

#define TAG "LORA"
#define NVS_NS "tl_tank"
#define NVS_KEY_BOUND "bound"
#define NVS_KEY_ID "id"

#ifndef CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS
#define CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS 60000
#endif

#if !CONFIG_PUMP_ENABLE_LORA

esp_err_t lora_link_init(void)
{
    ESP_LOGI(TAG, "disabled");
    return ESP_OK;
}
bool lora_link_ready(void)
{
    return false;
}
esp_err_t lora_link_start_tank_pair(uint32_t timeout_ms)
{
    (void)timeout_ms;
    return ESP_ERR_NOT_SUPPORTED;
}
void lora_link_stop_tank_pair(void) {}
bool lora_link_tank_pairing_active(void)
{
    return false;
}
esp_err_t lora_link_unpair_tank(void)
{
    return ESP_OK;
}
bool lora_link_tank_bound(void)
{
    return false;
}
bool lora_link_tank_heard(void)
{
    return false;
}
bool lora_link_tank_online(void)
{
    return false;
}
uint16_t lora_link_tank_age_sec(void)
{
    return 0xFFFF;
}
int16_t lora_link_tank_rssi_dbm(void)
{
    return 0;
}
int8_t lora_link_tank_snr_db(void)
{
    return 0;
}
const uint8_t *lora_link_tank_id(void)
{
    static const uint8_t z[TANKLINK_LORA_TANK_ID_LEN];
    return z;
}
uint8_t lora_link_tank_flags(void)
{
    return 0;
}
uint8_t lora_link_tank_battery_pct(void)
{
    return 0;
}
uint8_t lora_link_tank_fw_major(void)
{
    return 0;
}
uint8_t lora_link_tank_fw_minor(void)
{
    return 0;
}
uint8_t lora_link_tank_fw_patch(void)
{
    return 0;
}

#else

#ifndef CONFIG_PUMP_TANK_STALE_SEC
#define CONFIG_PUMP_TANK_STALE_SEC 1500
#endif

static bool s_ready;
static bool s_bound;
static bool s_heard;
static bool s_pairing;
static bool s_was_online;
static int64_t s_pair_deadline_us;
static int64_t s_last_rx_us;
static uint8_t s_tank_id[TANKLINK_LORA_TANK_ID_LEN];
static uint8_t s_flags;
static uint8_t s_bat;
static uint8_t s_fw_maj;
static uint8_t s_fw_min;
static uint8_t s_fw_pat;
static int16_t s_rssi_dbm;
static int8_t s_snr_db;
static uint16_t s_last_seq = 0xFFFF;

static esp_err_t save_bind(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        return err;
    }
    uint8_t bound = s_bound ? 1 : 0;
    err = nvs_set_u8(h, NVS_KEY_BOUND, bound);
    if (err == ESP_OK && s_bound) {
        err = nvs_set_blob(h, NVS_KEY_ID, s_tank_id, sizeof(s_tank_id));
    }
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

static void load_bind(void)
{
    memset(s_tank_id, 0, sizeof(s_tank_id));
    s_bound = false;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    uint8_t bound = 0;
    if (nvs_get_u8(h, NVS_KEY_BOUND, &bound) == ESP_OK && bound) {
        size_t len = sizeof(s_tank_id);
        if (nvs_get_blob(h, NVS_KEY_ID, s_tank_id, &len) == ESP_OK &&
            len == sizeof(s_tank_id)) {
            s_bound = true;
            ESP_LOGI(TAG, "bound tank %02x:%02x:%02x:%02x:%02x:%02x", s_tank_id[0],
                     s_tank_id[1], s_tank_id[2], s_tank_id[3], s_tank_id[4],
                     s_tank_id[5]);
        }
    }
    nvs_close(h);
}

static void send_ack(const tanklink_lora_status_t *pkt)
{
    tanklink_lora_status_t ack;
    memset(&ack, 0, sizeof(ack));
    ack.magic0 = TANKLINK_LORA_MAGIC0;
    ack.magic1 = TANKLINK_LORA_MAGIC1;
    ack.ver = TANKLINK_LORA_VER;
    ack.type = TANKLINK_LORA_TYPE_ACK;
    ack.seq = pkt->seq;
    memcpy(ack.tank_id, pkt->tank_id, TANKLINK_LORA_TANK_ID_LEN);
    esp_err_t err = sx1278_send((const uint8_t *)&ack, sizeof(ack), 1500);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "ACK TX failed: %s", esp_err_to_name(err));
    }
    (void)sx1278_start_rx();
}

static uint16_t tank_age_sec_now(void)
{
    if (!s_heard || s_last_rx_us == 0) {
        return 0xFFFF;
    }
    int64_t age = (esp_timer_get_time() - s_last_rx_us) / 1000000LL;
    if (age < 0) {
        age = 0;
    }
    if (age > 65535) {
        age = 65535;
    }
    return (uint16_t)age;
}

static bool tank_online_now(void)
{
    if (!s_bound || !s_heard) {
        return false;
    }
    return tank_age_sec_now() <= (uint16_t)CONFIG_PUMP_TANK_STALE_SEC;
}

static void apply_tank_packet(const tanklink_lora_status_t *pkt, int16_t rssi_dbm,
                              int8_t snr_db)
{
    s_heard = true;
    s_last_rx_us = esp_timer_get_time();
    s_was_online = true;
    s_flags = pkt->flags;
    s_bat = pkt->battery_pct;
    s_fw_maj = pkt->fw_major;
    s_fw_min = pkt->fw_minor;
    s_fw_pat = pkt->fw_patch;
    s_rssi_dbm = rssi_dbm;
    s_snr_db = snr_db;
    const bool full = (pkt->flags & TANKLINK_LORA_FLAG_FULL) != 0;
    status_led_set_tank_full(full);
    if (full && gatt_svr_pump_state()) {
        gatt_svr_set_pump_state_silent(0);
    }
    ESP_LOGI(TAG,
             "tank RX type=%u flags=0x%02x bat=%u%% seq=%u fw=%u.%u.%u full=%d "
             "rssi=%d snr=%d",
             pkt->type, pkt->flags, pkt->battery_pct, pkt->seq, pkt->fw_major,
             pkt->fw_minor, pkt->fw_patch, (int)full, (int)rssi_dbm, (int)snr_db);
    gatt_svr_notify_tank_if_subscribed();
}

static void restore_led_after_tank_pair(void)
{
    if (status_led_get_mode() != STATUS_LED_TANK_PAIRING) {
        return;
    }
    if (pump_pair_pairing_active()) {
        status_led_set_mode(STATUS_LED_PAIRING);
    } else if (!pump_pair_is_paired()) {
        status_led_set_mode(STATUS_LED_UNPAIRED);
    } else if (gatt_svr_pump_state()) {
        status_led_set_mode(STATUS_LED_PUMP_ON);
    } else {
        status_led_set_mode(STATUS_LED_IDLE);
    }
}

static bool pairing_window_open(void)
{
    if (!s_pairing) {
        return false;
    }
    if (esp_timer_get_time() >= s_pair_deadline_us) {
        s_pairing = false;
        ESP_LOGI(TAG, "tank pair window closed");
        restore_led_after_tank_pair();
        gatt_svr_notify_tank_if_subscribed();
        return false;
    }
    return true;
}

static void lora_task(void *arg)
{
    (void)arg;
    uint8_t buf[64];
    while (true) {
        (void)pairing_window_open();
        /* Notify app when a bound tank drops out of range. */
        const bool online = tank_online_now();
        if (s_bound && s_was_online && !online) {
            s_was_online = false;
            ESP_LOGW(TAG, "tank went offline (no packet ≥%ds)", CONFIG_PUMP_TANK_STALE_SEC);
            gatt_svr_set_last_error(PUMP_ERR_TANK_OFFLINE);
        } else if (online) {
            if (!s_was_online && gatt_svr_last_error() == PUMP_ERR_TANK_OFFLINE) {
                gatt_svr_clear_last_error();
            }
            s_was_online = true;
        }
        size_t n = 0;
        int16_t rssi = 0;
        int8_t snr = 0;
        esp_err_t err = sx1278_poll_recv_ex(buf, sizeof(buf), &n, &rssi, &snr);
        if (err == ESP_OK && n >= sizeof(tanklink_lora_status_t)) {
            const tanklink_lora_status_t *pkt = (const tanklink_lora_status_t *)buf;
            if (pkt->magic0 != TANKLINK_LORA_MAGIC0 ||
                pkt->magic1 != TANKLINK_LORA_MAGIC1 || pkt->ver != TANKLINK_LORA_VER) {
                vTaskDelay(pdMS_TO_TICKS(15));
                continue;
            }

            if (pkt->type == TANKLINK_LORA_TYPE_PAIR) {
                if (!pairing_window_open()) {
                    ESP_LOGW(TAG, "PAIR ignored — window closed");
                } else {
                    memcpy(s_tank_id, pkt->tank_id, TANKLINK_LORA_TANK_ID_LEN);
                    s_bound = true;
                    s_pairing = false;
                    restore_led_after_tank_pair();
                    save_bind();
                    send_ack(pkt);
                    if (pkt->seq != s_last_seq) {
                        s_last_seq = pkt->seq;
                        apply_tank_packet(pkt, rssi, snr);
                    } else {
                        s_rssi_dbm = rssi;
                        s_snr_db = snr;
                        gatt_svr_notify_tank_if_subscribed();
                    }
                    ESP_LOGI(TAG, "tank paired %02x:%02x:%02x:%02x:%02x:%02x",
                             s_tank_id[0], s_tank_id[1], s_tank_id[2], s_tank_id[3],
                             s_tank_id[4], s_tank_id[5]);
                }
            } else if (pkt->type == TANKLINK_LORA_TYPE_STATUS) {
                if (!s_bound ||
                    memcmp(pkt->tank_id, s_tank_id, TANKLINK_LORA_TANK_ID_LEN) != 0) {
                    ESP_LOGW(TAG, "STATUS ignored — not bound / wrong tank");
                } else {
                    send_ack(pkt);
                    if (pkt->seq != s_last_seq) {
                        s_last_seq = pkt->seq;
                        apply_tank_packet(pkt, rssi, snr);
                    } else {
                        s_rssi_dbm = rssi;
                        s_snr_db = snr;
                        gatt_svr_notify_tank_if_subscribed();
                    }
                }
            }
        } else if (err != ESP_ERR_NOT_FOUND && err != ESP_ERR_INVALID_CRC) {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
        vTaskDelay(pdMS_TO_TICKS(15));
    }
}

esp_err_t lora_link_init(void)
{
    load_bind();
    sx1278_config_t cfg = {
        .pin_sck = CONFIG_PUMP_LORA_SCK_GPIO,
        .pin_miso = CONFIG_PUMP_LORA_MISO_GPIO,
        .pin_mosi = CONFIG_PUMP_LORA_MOSI_GPIO,
        .pin_cs = CONFIG_PUMP_LORA_CS_GPIO,
        .pin_rst = CONFIG_PUMP_LORA_RST_GPIO,
        .pin_dio0 = CONFIG_PUMP_LORA_DIO0_GPIO,
        .freq_hz = (uint32_t)CONFIG_PUMP_LORA_FREQ_HZ,
    };
    esp_err_t err = sx1278_init(&cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "RA-02 not ready (%s) — continuing without LoRa",
                 esp_err_to_name(err));
        s_ready = false;
        return err;
    }
    err = sx1278_start_rx();
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "RX start failed: %s", esp_err_to_name(err));
        s_ready = false;
        return err;
    }
    s_ready = true;
    if (xTaskCreate(lora_task, "lora_rx", 4096, NULL, 5, NULL) != pdPASS) {
        ESP_LOGW(TAG, "lora_rx task failed");
        s_ready = false;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "listening for tank @ %u Hz", (unsigned)CONFIG_PUMP_LORA_FREQ_HZ);
    return ESP_OK;
}

bool lora_link_ready(void)
{
    return s_ready;
}

esp_err_t lora_link_start_tank_pair(uint32_t timeout_ms)
{
    if (!s_ready) {
        return ESP_ERR_INVALID_STATE;
    }
    if (timeout_ms < 5000) {
        timeout_ms = CONFIG_PUMP_TANK_PAIR_TIMEOUT_MS;
    }
    s_pairing = true;
    s_pair_deadline_us = esp_timer_get_time() + (int64_t)timeout_ms * 1000;
    status_led_set_mode(STATUS_LED_TANK_PAIRING);
    ESP_LOGI(TAG, "tank pair window open (%u ms)", (unsigned)timeout_ms);
    gatt_svr_notify_tank_if_subscribed();
    return ESP_OK;
}

void lora_link_stop_tank_pair(void)
{
    if (s_pairing) {
        s_pairing = false;
        ESP_LOGI(TAG, "tank pair window stopped");
        restore_led_after_tank_pair();
        gatt_svr_notify_tank_if_subscribed();
    }
}

bool lora_link_tank_pairing_active(void)
{
    return pairing_window_open();
}

esp_err_t lora_link_unpair_tank(void)
{
    s_bound = false;
    s_heard = false;
    s_was_online = false;
    s_last_rx_us = 0;
    s_flags = 0;
    s_bat = 0;
    s_rssi_dbm = 0;
    s_snr_db = 0;
    memset(s_tank_id, 0, sizeof(s_tank_id));
    status_led_set_tank_full(false);
    esp_err_t err = save_bind();
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_erase_key(h, NVS_KEY_ID);
        nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGI(TAG, "tank unpaired");
    gatt_svr_notify_tank_if_subscribed();
    return err;
}

bool lora_link_tank_bound(void)
{
    return s_bound;
}
bool lora_link_tank_heard(void)
{
    return s_heard;
}
bool lora_link_tank_online(void)
{
    return tank_online_now();
}
uint16_t lora_link_tank_age_sec(void)
{
    return tank_age_sec_now();
}
int16_t lora_link_tank_rssi_dbm(void)
{
    return s_heard ? s_rssi_dbm : 0;
}
int8_t lora_link_tank_snr_db(void)
{
    return s_heard ? s_snr_db : 0;
}
const uint8_t *lora_link_tank_id(void)
{
    return s_tank_id;
}
uint8_t lora_link_tank_flags(void)
{
    return s_flags;
}
uint8_t lora_link_tank_battery_pct(void)
{
    return s_bat;
}
uint8_t lora_link_tank_fw_major(void)
{
    return s_fw_maj;
}
uint8_t lora_link_tank_fw_minor(void)
{
    return s_fw_min;
}
uint8_t lora_link_tank_fw_patch(void)
{
    return s_fw_pat;
}

#endif /* CONFIG_PUMP_ENABLE_LORA */
