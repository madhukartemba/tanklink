#pragma once

/*
 * Which tank sensors are paired to this pump, and the tanks they watch.
 *
 * A sensor node is one tank board (one MAC, two float pins). Its float mode
 * says what its second pin means: nothing, "almost empty", or the full float
 * of a second tank. A tank slot is one logical tank: a node plus which pin is
 * its full float, a name, and its own auto-off.
 *
 * Invariants (kept by every change):
 *  - With no nodes there is exactly one slot, with node PUMP_NODE_NONE. It
 *    keeps the name and auto-off for a pump that runs without a sensor.
 *  - With nodes, every slot belongs to a node; each node has a sensor-0 slot,
 *    and a sensor-1 slot only in two-tank mode.
 *  - The active slot is always present. Only the active slot's tank can block
 *    a start or stop a running fill.
 *
 * The radio side (tokens, last packet per node) is in lora_link.c, indexed by
 * the same node index.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_NODE_MAX 4
#define PUMP_NODE_NONE 0xFF
/* Every node in two-tank mode: two slots each. */
#define PUMP_TANK_SLOT_MAX (PUMP_NODE_MAX * 2)
#define PUMP_TANK_NAME_LEN 16
#define PUMP_AUTO_OFF_DEFAULT_MIN 30
/* Auto-off is always on: it is the last stop if a float or the radio fails. */
#define PUMP_AUTO_OFF_MIN_MIN 1
#define PUMP_AUTO_OFF_MAX_MIN 240

#define PUMP_SENSOR_MODE_OFF 0
#define PUMP_SENSOR_MODE_EMPTY 1
#define PUMP_SENSOR_MODE_TWO 2

typedef struct {
    uint8_t present;
    uint8_t mac[6];
    uint8_t mode; /* PUMP_SENSOR_MODE_* */
} pump_tank_node_t;

typedef struct {
    uint8_t present;
    uint8_t node;   /* node index, PUMP_NODE_NONE = no sensor */
    uint8_t sensor; /* 0 = sensor 1 pin, 1 = sensor 2 pin */
    uint8_t auto_off_min; /* stop a fill after this many minutes (1-240) */
    char name[PUMP_TANK_NAME_LEN];
} pump_tank_slot_t;

/** Load saved sensors and tanks. Call after pump_sched_init. */
esp_err_t pump_tanks_init(void);

/* ---- Sensor nodes ---- */

unsigned pump_tanks_node_count(void);
bool pump_tanks_node_get(uint8_t node, pump_tank_node_t *out);
/** Node index for [mac], or -1. */
int pump_tanks_node_find(const uint8_t mac[6]);

/**
 * Add a node, or return the index it already has. A new node gets one tank
 * slot (the first node takes over the no-sensor slot). ESP_ERR_NO_MEM when
 * PUMP_NODE_MAX nodes are already paired.
 */
esp_err_t pump_tanks_node_add(const uint8_t mac[6], uint8_t *index, bool *added);

/**
 * Remove a node, its slots and the schedules that point at them. Refused
 * while the pump runs into one of its tanks. Removing the last node keeps one
 * no-sensor slot.
 */
esp_err_t pump_tanks_node_remove(uint8_t node, bool pump_running);

uint8_t pump_tanks_node_mode(uint8_t node);

/**
 * Change one node's float mode. Leaving two-tank mode removes that node's
 * second tank and its schedules, and is refused while the pump runs into it.
 */
esp_err_t pump_tanks_set_node_mode(uint8_t node, uint8_t mode, bool pump_running);

/* ---- Tank slots ---- */

/** Present slots in index order. */
unsigned pump_tanks_count(void);
bool pump_tanks_slot_at(unsigned nth, uint8_t *index, pump_tank_slot_t *out);
bool pump_tanks_slot_present(uint8_t slot);

uint8_t pump_tanks_active(void);
/** Node of the active slot, or PUMP_NODE_NONE. */
uint8_t pump_tanks_active_node(void);
/** Float mode of the active slot's node (OFF without a node). */
uint8_t pump_tanks_mode(void);

/** Select a present slot. A different slot is rejected while the pump is running. */
esp_err_t pump_tanks_select(uint8_t slot, bool pump_running);

esp_err_t pump_tanks_rename(uint8_t slot, const uint8_t *name, size_t len);

/** Auto-off for one slot, PUMP_AUTO_OFF_MIN_MIN to PUMP_AUTO_OFF_MAX_MIN minutes (clamped). */
esp_err_t pump_tanks_set_auto_off(uint8_t slot, uint8_t minutes);

/** Auto-off minutes of the active slot (never 0). */
uint8_t pump_tanks_active_auto_off_min(void);

/** True when [raw_flags] (from the slot's node) say that slot's tank is full. */
bool pump_tanks_slot_is_full(uint8_t slot, uint8_t raw_flags);

/** True when [raw_flags] (from the active node) say the active tank is full. */
bool pump_tanks_active_is_full(uint8_t raw_flags);

/* ---- Auto-fill ----
 * Any tank with a sensor can fill itself when it runs low. "Low" is the
 * almost-empty float when the tank has one (pin-1 tank of a sensor in
 * almost-empty mode), else the full float dropping: the tank is kept topped
 * up. The setting is cleared when the tank loses its sensor. */

bool pump_tanks_slot_can_auto_fill(uint8_t slot);
/** ESP_ERR_INVALID_STATE when turning it on for a tank without a sensor. */
esp_err_t pump_tanks_set_auto_fill(uint8_t slot, bool on);
bool pump_tanks_auto_fill_on(uint8_t slot);
/** Bit i set = slot i has auto-fill on. */
uint8_t pump_tanks_auto_fill_mask(void);

/** True when [raw_flags] say the active tank is low (see above). */
bool pump_tanks_active_is_low(uint8_t raw_flags);

#ifdef __cplusplus
}
#endif
