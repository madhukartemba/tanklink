#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "pump_clock.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_SCHED_MAX 4

typedef struct {
    uint8_t enabled;
    uint8_t hour;
    uint8_t minute;
    uint8_t slot;
} pump_sched_entry_t;

esp_err_t pump_sched_init(void);
esp_err_t pump_sched_clear(void);

unsigned pump_sched_count(void);
const pump_sched_entry_t *pump_sched_entries(void);

/** Replace the list. Rejects count > 4, bad times, and duplicate hour:minute. */
esp_err_t pump_sched_set(const pump_sched_entry_t *entries, unsigned count);

/** Drop "already fired today" marks. Call after a new clock sync. */
void pump_sched_clear_fired(void);

/** Remove every entry that targets [slot]. */
esp_err_t pump_sched_drop_slot(uint8_t slot);

/**
 * If an enabled time matches and has not fired for this local date, mark it
 * fired and return its slot. Returns -1 when nothing is due.
 */
int pump_sched_take_due(const pump_civil_time_t *now);

#ifdef __cplusplus
}
#endif
