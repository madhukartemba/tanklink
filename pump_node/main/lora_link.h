#pragma once

/*
 * LoRa link to the paired tank sensors (up to PUMP_NODE_MAX). Which sensors
 * are paired and which tank is selected live in pump_tanks.c; this module
 * keeps each sensor's BLE token and last packet, indexed by node.
 *
 * The lora_link_tank_* getters describe the sensor of the selected (active)
 * tank, for the Tank characteristic and the start/stop checks.
 */

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

/** Open the LoRa pair window. A PAIR packet adds that sensor (or refreshes it). */
esp_err_t lora_link_start_tank_pair(uint32_t timeout_ms);
void lora_link_stop_tank_pair(void);
bool lora_link_tank_pairing_active(void);

/** Forget one sensor. Refused while the pump runs into one of its tanks. */
esp_err_t lora_link_unpair_node(uint8_t node);
/** Forget every sensor (factory reset). */
esp_err_t lora_link_unpair_all(void);

/** Call after the selected tank changes: refreshes the tank-full LED and error. */
void lora_link_on_active_changed(void);

typedef struct {
    bool heard;
    bool online;
    uint16_t age_sec; /* 0xFFFF if never heard */
    uint8_t raw_flags;
    uint8_t battery_pct;
    uint8_t fw[3];
    uint8_t hw_rev;
    int16_t rssi_dbm;
    int8_t snr_db;
    bool has_ble_token;
    uint8_t ble_token[TANKLINK_LORA_BLE_TOKEN_LEN];
    uint8_t fault; /* tank LED code from the packet, 0 = none */
} lora_node_status_t;

/** Snapshot of one paired sensor. False if [node] is not paired. */
bool lora_link_node_status(uint8_t node, lora_node_status_t *out);

/** The selected tank has a sensor that is online and says full. */
bool lora_link_active_tank_full(void);

/* ---- The selected tank's sensor ---- */
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
/** True when a non-zero BLE OTA token was stored at LoRa pair time. */
bool lora_link_tank_has_ble_token(void);
/** 16-byte BLE OTA token (zeros if absent). */
const uint8_t *lora_link_tank_ble_token(void);
/** Bit 0 = the selected tank is full, bit 1 = almost empty (that sensor's mode). */
uint8_t lora_link_tank_flags(void);
/** Last raw pin flags from the sensor. Bit 0 is sensor 1, bit 1 is sensor 2. */
uint8_t lora_link_tank_raw_flags(void);
uint8_t lora_link_tank_battery_pct(void);
uint8_t lora_link_tank_fw_major(void);
uint8_t lora_link_tank_fw_minor(void);
uint8_t lora_link_tank_fw_patch(void);
/** Tank board revision from its last packet (0 = unknown). */
uint8_t lora_link_tank_hw_rev(void);
/** Selected tank's own fault code (0 = none). */
uint8_t lora_link_tank_fault(void);

#ifdef __cplusplus
}
#endif
