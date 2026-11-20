#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "tanklink_crypto.h"
#include "tanklink_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Phones that can be signed in at once, each with its own token. */
#define PUMP_PAIR_PHONES_MAX 8

esp_err_t pump_pair_init(void);
bool pump_pair_is_paired(void);
bool pump_pair_is_claimable(void);
bool pump_pair_pairing_active(void);
const uint8_t *pump_pair_device_id(void);

/** Copy BLE MAC into device_id (stable serial) and persist if changed. */
esp_err_t pump_pair_set_mac_identity(const uint8_t mac[6]);

/** Last 4 hex chars of device_id (uppercase), e.g. "A1B2". */
const char *pump_pair_serial(void);

/** Full GAP/adv name, e.g. "TankLink-A1B2". */
const char *pump_pair_adv_name(void);

/** Open pairing window (e.g. after 5s button hold). Timeout from Kconfig. */
esp_err_t pump_pair_enter_pairing_mode(void);
void pump_pair_exit_pairing_mode(void);

/** Called after anything that changes pump_pair_is_claimable() or
 * pump_pair_is_paired(), so advertising can be refreshed. */
void pump_pair_set_change_callback(void (*cb)(void));
/** Call periodically; ends pairing window when timed out. */
void pump_pair_poll(void);

/**
 * Claim while the pairing window is open: makes a token for one new phone
 * and closes the window. ESP_ERR_NO_MEM when PUMP_PAIR_PHONES_MAX phones
 * already have the pump.
 */
esp_err_t pump_pair_claim(uint8_t out_token[TANKLINK_TOKEN_LEN], int *out_phone);

/** Clear every phone's token; the pump is unpaired and opens its window. */
esp_err_t pump_pair_unpair(void);

/** The phone whose token answers [nonce] with [resp], or -1. */
int pump_pair_check_response(const uint8_t nonce[TL_NONCE_LEN],
                             const uint8_t resp[TL_AUTH_RESP_LEN]);

/** Keep only [keep_phone]'s token (sign out every other phone). */
esp_err_t pump_pair_forget_others(int keep_phone);

int pump_pair_phone_count(void);

#ifdef __cplusplus
}
#endif
