#pragma once

/*
 * The last PUMP_HISTORY_MAX fills, newest first, saved in NVS: when each
 * started, how long it ran, which tank, and what started and stopped it.
 */

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_HISTORY_MAX 20

/** Why the pump started or stopped. Sent to the app as one byte. */
typedef enum {
    PUMP_CAUSE_UNKNOWN = 0,
    PUMP_CAUSE_APP = 1,
    PUMP_CAUSE_BUTTON = 2,
    PUMP_CAUSE_SCHEDULE = 3,
    PUMP_CAUSE_TANK_FULL = 4,
    PUMP_CAUSE_AUTO_OFF = 5,
    PUMP_CAUSE_POWER = 6,  /* power cut or restart while running */
    PUMP_CAUSE_SYSTEM = 7, /* update, pairing, unpair or factory reset */
} pump_cause_t;

typedef struct {
    uint32_t started_local; /* pump-local seconds since 1970, 0 = clock unknown */
    uint32_t ran_sec;
    uint8_t slot;       /* tank slot it filled */
    uint8_t started_by; /* pump_cause_t */
    uint8_t stopped_by; /* pump_cause_t */
    uint8_t reserved;
} pump_fill_t;

esp_err_t pump_history_init(void);
esp_err_t pump_history_clear(void);

/** Save a finished fill and notify phones. */
void pump_history_add(const pump_fill_t *fill);

unsigned pump_history_count(void);
/** [nth] = 0 is the newest. False past the end. */
bool pump_history_get(unsigned nth, pump_fill_t *out);

#ifdef __cplusplus
}
#endif
