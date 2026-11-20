#include "tanklink_crypto.h"

#include <string.h>

#include "tinycrypt/constants.h"
#include "tinycrypt/hmac.h"

static const uint8_t k_auth_label[] = {'T', 'L', 'a', 'u', 't', 'h'};
static const uint8_t k_ota_label[] = {'T', 'L', 'o', 't', 'a'};

void tl_hmac_sha256(const uint8_t *key, size_t key_len, const uint8_t *a, size_t a_len,
                    const uint8_t *b, size_t b_len, uint8_t out[32])
{
    struct tc_hmac_state_struct st;
    (void)tc_hmac_set_key(&st, key, (unsigned int)key_len);
    (void)tc_hmac_init(&st);
    if (a && a_len) {
        (void)tc_hmac_update(&st, a, (unsigned int)a_len);
    }
    if (b && b_len) {
        (void)tc_hmac_update(&st, b, (unsigned int)b_len);
    }
    (void)tc_hmac_final(out, TC_SHA256_DIGEST_SIZE, &st);
    memset(&st, 0, sizeof(st));
}

bool tl_ct_equal(const uint8_t *a, const uint8_t *b, size_t n)
{
    uint8_t diff = 0;
    for (size_t i = 0; i < n; i++) {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}

bool tl_nonzero(const uint8_t *a, size_t n)
{
    uint8_t acc = 0;
    for (size_t i = 0; i < n; i++) {
        acc |= a[i];
    }
    return acc != 0;
}

size_t tl_lora_seal(const uint8_t key[TL_KEY_LEN], uint8_t *buf, size_t body_len)
{
    uint8_t mac[32];
    tl_hmac_sha256(key, TL_KEY_LEN, buf, body_len, NULL, 0, mac);
    memcpy(buf + body_len, mac, TL_LORA_TAG_LEN);
    return body_len + TL_LORA_TAG_LEN;
}

bool tl_lora_verify(const uint8_t key[TL_KEY_LEN], const uint8_t *buf, size_t len)
{
    if (len <= TL_LORA_TAG_LEN) {
        return false;
    }
    uint8_t mac[32];
    tl_hmac_sha256(key, TL_KEY_LEN, buf, len - TL_LORA_TAG_LEN, NULL, 0, mac);
    return tl_ct_equal(mac, buf + len - TL_LORA_TAG_LEN, TL_LORA_TAG_LEN);
}

void tl_derive_ota_token(const uint8_t key[TL_KEY_LEN], uint8_t out[TL_KEY_LEN])
{
    uint8_t mac[32];
    tl_hmac_sha256(key, TL_KEY_LEN, k_ota_label, sizeof(k_ota_label), NULL, 0, mac);
    memcpy(out, mac, TL_KEY_LEN);
}

void tl_auth_response(const uint8_t token[TL_KEY_LEN], const uint8_t nonce[TL_NONCE_LEN],
                      uint8_t out[TL_AUTH_RESP_LEN])
{
    uint8_t mac[32];
    tl_hmac_sha256(token, TL_KEY_LEN, k_auth_label, sizeof(k_auth_label), nonce,
                   TL_NONCE_LEN, mac);
    memcpy(out, mac, TL_AUTH_RESP_LEN);
}
