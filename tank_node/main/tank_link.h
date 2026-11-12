#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "tank_board.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef bool (*tank_link_should_cancel_fn)(void *ctx);

esp_err_t tank_link_init(void);
void tank_link_deinit_radio(void);
bool tank_link_radio_ok(void);

/**
 * Send status and wait for pump ACK. Retries up to Kconfig attempts.
 * Returns ESP_OK if ACK received.
 */
esp_err_t tank_link_send_status(const tank_inputs_t *in, uint8_t battery_pct,
                                bool button_event);

/**
 * PAIR with ACK retries. Optional cancel returns true to abort (ESP_ERR_INVALID_STATE).
 * on_attempt called before each TX (for LED flash tick ownership in caller).
 */
esp_err_t tank_link_send_pair_request(uint8_t battery_pct,
                                      tank_link_should_cancel_fn should_cancel,
                                      void *ctx);

#ifdef __cplusplus
}
#endif
