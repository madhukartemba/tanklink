#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Detects fills cut short by a power cut or restart. While the pump runs, a
 * small record sits in NVS. A normal stop removes it. If the board boots and
 * the record is still there, the run was interrupted: that becomes a notice the
 * app shows until dismissed. The pump never restarts on its own.
 */

#define PUMP_RUNLOG_NONE       0
#define PUMP_RUNLOG_POWER_LOST 1 /* power-on reset: supply went away */
#define PUMP_RUNLOG_BROWNOUT   2 /* supply dipped below the brownout level */
#define PUMP_RUNLOG_RESTARTED  3 /* crash, watchdog, or software reset */

typedef struct {
    uint8_t reason;           /* PUMP_RUNLOG_* */
    uint32_t started_local;   /* pump clock (local) when the run started; 0 = unknown */
    uint32_t last_seen_local; /* last time it was seen running; 0 = unknown */
    uint32_t back_local;      /* when the board came back; 0 = unknown */
    uint32_t ran_sec;         /* run time before the cut (±1 min) */
} pump_runlog_event_t;

/** Call at boot after pump_clock_init(), before the pump can start. */
void pump_runlog_init(void);

void pump_runlog_on_start(void);
void pump_runlog_on_stop(void);

/** Call every few hundred ms. Refreshes the running record once a minute. */
void pump_runlog_poll(bool running, uint32_t run_sec);

/** The pending notice, or NULL when there is none. */
const pump_runlog_event_t *pump_runlog_event(void);

/** Dismiss the pending notice (app). */
void pump_runlog_clear_event(void);

#ifdef __cplusplus
}
#endif
