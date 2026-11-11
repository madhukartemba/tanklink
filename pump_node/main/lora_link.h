#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Stub: tank LoRa link (not implemented yet). */
esp_err_t lora_link_init(void);
void lora_link_poll(void);

#ifdef __cplusplus
}
#endif
