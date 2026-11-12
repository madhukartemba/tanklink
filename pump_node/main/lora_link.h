#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "tanklink_lora_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Init RA-02; returns error if missing — caller should soft-fail. */
esp_err_t lora_link_init(void);
bool lora_link_ready(void);

/** Open LoRa window; first PAIR packet auto-binds the tank. */
esp_err_t lora_link_start_tank_pair(uint32_t timeout_ms);
void lora_link_stop_tank_pair(void);
bool lora_link_tank_pairing_active(void);

esp_err_t lora_link_unpair_tank(void);
bool lora_link_tank_bound(void);
bool lora_link_tank_heard(void);
/** Bound and last packet within stale window. */
bool lora_link_tank_online(void);
/** Seconds since last RX; 0xFFFF if never heard. */
uint16_t lora_link_tank_age_sec(void);
/** Last packet RSSI (dBm); 0 if never heard. */
int16_t lora_link_tank_rssi_dbm(void);
/** Last packet SNR (dB); 0 if never heard. */
int8_t lora_link_tank_snr_db(void);
const uint8_t *lora_link_tank_id(void);
uint8_t lora_link_tank_flags(void);
uint8_t lora_link_tank_battery_pct(void);
uint8_t lora_link_tank_fw_major(void);
uint8_t lora_link_tank_fw_minor(void);
uint8_t lora_link_tank_fw_patch(void);

#ifdef __cplusplus
}
#endif
