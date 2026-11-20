#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "tanklink_ble_uuid.h"
#include "tanklink_crypto.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Load (or make) the LoRa link key and derive the BLE OTA token. */
esp_err_t tank_ble_token_init(void);

/** The link key in use: tags every LoRa packet. */
const uint8_t *tank_link_key(void);

/** A fresh random key for a PAIR attempt (not saved). */
void tank_link_key_make_pending(uint8_t out[TL_KEY_LEN]);

/** The pump took [key]: use and save it, and derive the new OTA token. */
esp_err_t tank_link_key_commit(const uint8_t key[TL_KEY_LEN]);

/** BLE OTA token: HMAC(link key, "TLota"), so it changes on every pairing. */
const uint8_t *tank_ble_token_bytes(void);

#ifdef __cplusplus
}
#endif
