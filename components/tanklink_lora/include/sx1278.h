#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int pin_sck;
    int pin_miso;
    int pin_mosi;
    int pin_cs;
    int pin_rst;
    int pin_dio0; /* -1 if unused */
    uint32_t freq_hz; /* e.g. 433000000 */
} sx1278_config_t;

esp_err_t sx1278_init(const sx1278_config_t *cfg);
void sx1278_sleep(void);
esp_err_t sx1278_send(const uint8_t *data, size_t len, uint32_t timeout_ms);
esp_err_t sx1278_start_rx(void);
/** Non-blocking: copy packet if ready. Returns ESP_OK, ESP_ERR_NOT_FOUND, or error. */
esp_err_t sx1278_poll_recv(uint8_t *buf, size_t buf_len, size_t *out_len);
/**
 * Same as poll_recv; on success fills optional last-packet RSSI (dBm) and SNR (dB).
 * 433 MHz: RSSI ≈ -164 + RegPktRssiValue. SNR is RegPktSnrValue/4.
 */
esp_err_t sx1278_poll_recv_ex(uint8_t *buf, size_t buf_len, size_t *out_len,
                              int16_t *rssi_dbm, int8_t *snr_db);
uint8_t sx1278_read_version(void);

#ifdef __cplusplus
}
#endif
