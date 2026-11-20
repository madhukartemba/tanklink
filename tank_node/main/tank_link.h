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
/** 6-byte tank identity (WiFi STA MAC). */
const uint8_t *tank_link_tank_id(void);

/**
 * Fault byte sent after every STATUS / PAIR (0 = none). Only faults that are
 * still true when a packet goes out belong here (battery sense, code 6). It
 * lives in RAM and is found again on every wake. See tank_errors.h.
 */
uint8_t tank_link_fault(void);

/** True once a pump ACK said it has a firmware update for this tank. */
bool tank_link_ota_pending(void);
void tank_link_set_fault(uint8_t code);

/**
 * Send status and wait for pump ACK. Retries up to Kconfig attempts.
 * Returns ESP_OK if ACK received. should_cancel may abort with
 * ESP_ERR_INVALID_STATE (no error blink). A trailing fault byte follows
 * the status body.
 */
esp_err_t tank_link_send_status(const tank_inputs_t *in, uint8_t battery_pct,
                                bool button_event,
                                tank_link_should_cancel_fn should_cancel,
                                void *ctx);

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
