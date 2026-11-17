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

/**
 * Start the DS3231 (if wired) and, when it holds a trusted time, start the
 * clock from it. Call once at boot, before schedules and LoRa start.
 */
void pump_clock_init(void);

/** Call every few hundred ms. Re-reads the RTC about once an hour. */
void pump_clock_poll(void);

/** DS3231 answered at boot. */
bool pump_clock_rtc_present(void);

/** DS3231 holds a trusted time (read at boot or written by a phone sync). */
bool pump_clock_rtc_ok(void);

/** True once the time is known: from the RTC at boot, or a phone sync. */
bool pump_clock_is_valid(void);

/**
 * Set local civil time from the phone and write it to the RTC. Weekday is
 * accepted for protocol compatibility and ignored.
 */
esp_err_t pump_clock_set(int year, unsigned month, unsigned day,
                         unsigned hour, unsigned minute, unsigned second,
                         unsigned wday);

/** Current local civil time. False while the time is unknown. */
bool pump_clock_now(pump_civil_time_t *out);

/** Current local time as seconds since 1970-01-01 00:00 (local, not UTC). */
bool pump_clock_unix_now(int64_t *out);

#ifdef __cplusplus
}
#endif
