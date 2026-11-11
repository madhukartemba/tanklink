#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "tanklink_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t pump_pair_init(void);
bool pump_pair_is_paired(void);
bool pump_pair_is_claimable(void);
bool pump_pair_pairing_active(void);
const uint8_t *pump_pair_device_id(void);
const uint8_t *pump_pair_token(void);

/** Copy BLE MAC into device_id (stable serial) and persist if changed. */
esp_err_t pump_pair_set_mac_identity(const uint8_t mac[6]);

/** Last 4 hex chars of device_id (uppercase), e.g. "A1B2". */
const char *pump_pair_serial(void);

/** Full GAP/adv name, e.g. "TankLink-A1B2". */
const char *pump_pair_adv_name(void);

/** Open pairing window (e.g. after 5s button hold). Timeout from Kconfig. */
esp_err_t pump_pair_enter_pairing_mode(void);
void pump_pair_exit_pairing_mode(void);
/** Call periodically; ends pairing window when timed out. */
void pump_pair_poll(void);

/**
 * Claim when claimable. If already paired, replaces owner token (re-pair).
 * Ends pairing window on success.
 */
esp_err_t pump_pair_claim(uint8_t out_token[TANKLINK_TOKEN_LEN]);

/** Clear owner token; device becomes unpaired/claimable. */
esp_err_t pump_pair_unpair(void);

bool pump_pair_check_token(const uint8_t *token, size_t len);

#ifdef __cplusplus
}
#endif
