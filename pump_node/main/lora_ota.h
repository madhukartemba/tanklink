#pragma once

/*
 * Experimental: send a stored tank firmware image to a tank over LoRa
 * (protocol in tanklink_lora_ota.h). The app uploads the image to the pump
 * (pump_ota_start_tank); lora_ota_begin then waits for that tank's next
 * STATUS, and lora_link runs the transfer in its task.
 *
 * Pump starts are blocked from begin until the transfer ends: the radio is
 * busy, so other tanks can't be heard.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_partition.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Tank-update status characteristic: state node error fast done(u16) total(u16). */
#define LORA_OTA_STATUS_LEN 8

#define LORA_OTA_ST_IDLE 0
#define LORA_OTA_ST_WAITING 1   /* for the tank to wake (heartbeat or button) */
#define LORA_OTA_ST_OFFERING 2  /* tank awake, erasing */
#define LORA_OTA_ST_SENDING 3
#define LORA_OTA_ST_FINISHING 4 /* tank checking the image */
#define LORA_OTA_ST_DONE 5      /* tank is booting the new firmware */
#define LORA_OTA_ST_FAILED 6

#define LORA_OTA_ERR_NONE 0
#define LORA_OTA_ERR_NO_ANSWER 1 /* tank never answered the offer */
#define LORA_OTA_ERR_REFUSED 2   /* tank couldn't take the image (size, flash) */
#define LORA_OTA_ERR_LOST 3      /* tank stopped answering during the transfer */
#define LORA_OTA_ERR_MISSING 4   /* tank was missing chunks at the end */
#define LORA_OTA_ERR_IMAGE 5     /* tank rejected the image (hash or signature) */
#define LORA_OTA_ERR_NO_RESULT 6 /* no answer to DONE */
#define LORA_OTA_ERR_CANCELLED 7
#define LORA_OTA_ERR_NO_KEY 8    /* sensor not paired */
#define LORA_OTA_ERR_PUMP_ON 9

/** Arm an update of sensor [node] with [size] bytes stored in [part]. */
esp_err_t lora_ota_begin(uint8_t node, const esp_partition_t *part, uint32_t size,
                         const uint8_t sha256[32]);
/** Send the stored image again (after a failure). [fast]: try 500 kHz first. */
esp_err_t lora_ota_retry(bool fast);
void lora_ota_cancel(void);

/** Waiting, offering, sending or finishing. */
bool lora_ota_busy(void);
/** True while waiting for [node] to wake. */
bool lora_ota_waiting_for(uint8_t node);
/** Run the whole transfer. Called by lora_link's task right after it ACKed
 * the waiting tank with TANKLINK_LORA_FLAG_OTA_PENDING. */
void lora_ota_run(void);

size_t lora_ota_status(uint8_t out[LORA_OTA_STATUS_LEN]);

#ifdef __cplusplus
}
#endif
