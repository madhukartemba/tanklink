#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "tank_board.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t tank_link_init(void);
void tank_link_deinit_radio(void);

/**
 * Send status and wait for pump ACK. Retries up to Kconfig attempts.
 * LED: short pulse each TX; success / fail blink at end.
 * Returns ESP_OK if ACK received.
 */
esp_err_t tank_link_send_status(const tank_inputs_t *in, uint8_t battery_pct,
                                bool button_event);

/**
 * Pairing restart: clear local state is caller's job.
 * Sends PAIR packets with ACK wait/retry; LED shows pairing + result.
 */
esp_err_t tank_link_send_pair_request(uint8_t battery_pct);

#ifdef __cplusplus
}
#endif
