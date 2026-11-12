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
uint8_t sx1278_read_version(void);

#ifdef __cplusplus
}
#endif
