#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int year;
    unsigned month;
    unsigned day;
    unsigned hour;
    unsigned minute;
    unsigned second;
} pump_civil_time_t;

/** True after a phone time sync since boot. Reboot clears this. */
bool pump_clock_is_valid(void);

/**
 * Anchor local civil time to esp_timer. Weekday is accepted for protocol
 * compatibility and ignored; the date itself tracks elapsed time.
 */
esp_err_t pump_clock_set(int year, unsigned month, unsigned day,
                         unsigned hour, unsigned minute, unsigned second,
                         unsigned wday);

/** Current local civil time. False if the clock was never set this boot. */
bool pump_clock_now(pump_civil_time_t *out);

#ifdef __cplusplus
}
#endif
