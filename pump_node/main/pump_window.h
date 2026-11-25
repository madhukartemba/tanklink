#pragma once

/*
 * A daily time window in pump-local time: auto-fill's allowed times and the
 * buzzer's quiet hours. start == end is not a window. A window whose end is
 * before its start runs past midnight; its days are the days it starts on,
 * so a Mon 22:00-06:00 window is open until Tue 06:00.
 */

#include <stdbool.h>
#include <stdint.h>
#include "pump_clock.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PUMP_WINDOW_ALL_DAYS 0x7F /* bit 0 = Monday ... bit 6 = Sunday */
#define PUMP_WINDOW_NEVER UINT32_MAX

typedef struct {
    uint8_t days;   /* PUMP_WINDOW_ALL_DAYS bits */
    uint16_t start; /* minute of the day, 0-1439 */
    uint16_t end;   /* minute of the day, 0-1439, != start */
} pump_window_t;

/** 0 = Monday ... 6 = Sunday. */
unsigned pump_weekday(const pump_civil_time_t *t);

/** h(0-23) m(0-59) start, h m end, days nonzero and start != end. */
bool pump_window_valid(uint8_t days, uint8_t sh, uint8_t sm, uint8_t eh, uint8_t em);

bool pump_window_open(const pump_window_t *w, const pump_civil_time_t *now);

/** Minutes until [w] next opens (at least 1), or PUMP_WINDOW_NEVER. */
uint32_t pump_window_minutes_until(const pump_window_t *w, const pump_civil_time_t *now);

#ifdef __cplusplus
}
#endif
