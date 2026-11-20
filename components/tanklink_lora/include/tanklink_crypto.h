#pragma once

/*
 * Small crypto helpers shared by the pump and the tank (HMAC-SHA256 from the
 * tinycrypt copy in the bt component).
 *
 * - LoRa: every packet ends in an 8-byte tag, HMAC-SHA256(link key, packet)
 *   truncated. The link key is made by the tank and sent once in PAIR.
 * - BLE sign-in: the board hands out a fresh 16-byte nonce per connection;
 *   the phone answers HMAC-SHA256(token, "TLauth" || nonce)[0..16), so the
 *   token itself never goes over the air after it is first handed out.
 * - The tank's BLE OTA token is derived from its link key, so it changes
 *   whenever the tank is paired again.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TL_KEY_LEN 16
#define TL_NONCE_LEN 16
#define TL_AUTH_RESP_LEN 16
#define TL_LORA_TAG_LEN 8

/** out = HMAC-SHA256(key, a || b), full 32 bytes. b may be NULL. */
void tl_hmac_sha256(const uint8_t *key, size_t key_len, const uint8_t *a, size_t a_len,
                    const uint8_t *b, size_t b_len, uint8_t out[32]);

/** Constant-time compare. */
bool tl_ct_equal(const uint8_t *a, const uint8_t *b, size_t n);

/** True if any byte is non-zero. */
bool tl_nonzero(const uint8_t *a, size_t n);

/** Writes the 8-byte tag of buf[0..body_len) at buf[body_len]. Returns body_len + 8. */
size_t tl_lora_seal(const uint8_t key[TL_KEY_LEN], uint8_t *buf, size_t body_len);

/** True if buf ends in a valid tag for buf[0..len-8). */
bool tl_lora_verify(const uint8_t key[TL_KEY_LEN], const uint8_t *buf, size_t len);

/** The tank's BLE OTA token for a link key. */
void tl_derive_ota_token(const uint8_t key[TL_KEY_LEN], uint8_t out[TL_KEY_LEN]);

/** The answer a phone writes to Auth for [token] and the board's [nonce]. */
void tl_auth_response(const uint8_t token[TL_KEY_LEN], const uint8_t nonce[TL_NONCE_LEN],
                      uint8_t out[TL_AUTH_RESP_LEN]);

#ifdef __cplusplus
}
#endif
