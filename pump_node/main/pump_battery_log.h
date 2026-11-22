#pragma once

/*
 * Each paired tank sensor's battery over the last PUMP_BATLOG_DAYS days: the
 * lowest and highest percentage heard on each pump-local day. The app turns
 * the daily lows into a trend ("solar keeping up", "about 3 weeks left").
 * Needs the pump clock; packets while it is unknown are not logged.
 */

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_BATLOG_DAYS 14

typedef struct {
    uint16_t day; /* pump-local days since 1970 */
    uint8_t min_pct;
    uint8_t max_pct;
} pump_batlog_day_t;

esp_err_t pump_battery_log_init(void);

/** Log a reading from [node]. 0 % (no reading) is ignored. */
void pump_battery_log_note(uint8_t node, uint8_t pct);

/** Forget [node]'s log (unpaired, or a new sensor in that slot). */
void pump_battery_log_clear(uint8_t node);

/** Copy [node]'s days, oldest first. Returns how many. */
unsigned pump_battery_log_get(uint8_t node, pump_batlog_day_t out[PUMP_BATLOG_DAYS]);

#ifdef __cplusplus
}
#endif
