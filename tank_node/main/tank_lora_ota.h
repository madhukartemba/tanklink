#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Experimental: the pump said it has an update (TANKLINK_LORA_FLAG_OTA_PENDING
 * in an ACK). Stay awake and receive it over LoRa. Reboots into the new
 * firmware on success; returns after a failure or a timeout.
 */
void tank_lora_ota_run(void);

#ifdef __cplusplus
}
#endif
