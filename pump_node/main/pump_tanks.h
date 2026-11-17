#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Room for a later second paired node. This build only fills slots from one node. */
#define PUMP_TANK_SLOT_MAX 4
#define PUMP_TANK_NAME_LEN 16
#define PUMP_AUTO_OFF_DEFAULT_MIN 30
#define PUMP_AUTO_OFF_MAX_MIN 240

#define PUMP_SENSOR_MODE_OFF 0
#define PUMP_SENSOR_MODE_EMPTY 1
#define PUMP_SENSOR_MODE_TWO 2

typedef struct {
    uint8_t present;
    uint8_t node_mac[6];
    uint8_t sensor; /* 0 = sensor 1 pin, 1 = sensor 2 pin */
    uint8_t auto_off_min; /* 0 = off, else stop a fill after this many minutes */
    char name[PUMP_TANK_NAME_LEN];
} pump_tank_slot_t;

esp_err_t pump_tanks_init(void);
esp_err_t pump_tanks_clear(void);

void pump_tanks_on_node_bound(const uint8_t mac[6]);
void pump_tanks_on_node_unpaired(void);

uint8_t pump_tanks_mode(void);
uint8_t pump_tanks_active(void);
uint8_t pump_tanks_active_sensor(void);

/** Present slots in index order. */
unsigned pump_tanks_count(void);
bool pump_tanks_slot_at(unsigned nth, uint8_t *index, pump_tank_slot_t *out);

/**
 * Change float mode. Leaving two-tank mode while the pump is running fails.
 * Leaving two-tank mode deletes slot 1 and schedules that point at it.
 */
esp_err_t pump_tanks_set_mode(uint8_t mode, bool pump_running);

/** Select a present slot. A different slot is rejected while the pump is running. */
esp_err_t pump_tanks_select(uint8_t slot, bool pump_running);

esp_err_t pump_tanks_rename(uint8_t slot, const uint8_t *name, size_t len);

/** Auto-off for one slot, 0 (off) to PUMP_AUTO_OFF_MAX_MIN minutes. */
esp_err_t pump_tanks_set_auto_off(uint8_t slot, uint8_t minutes);

/** Auto-off minutes of the active slot (0 = off). */
uint8_t pump_tanks_active_auto_off_min(void);

/** True when the active slot's float says that tank is full. */
bool pump_tanks_active_is_full(uint8_t raw_flags);

#ifdef __cplusplus
}
#endif
