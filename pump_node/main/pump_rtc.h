#pragma once

#include <stdbool.h>
#include "esp_err.h"
#include "pump_clock.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * DS3231 real-time clock on I2C (address 0x68). Holds local civil time as
 * last sent by the phone. Everything soft-fails: with no chip wired, the pump
 * falls back to phone-only time.
 */
esp_err_t pump_rtc_init(void);

/** True when the chip answered at init. */
bool pump_rtc_present(void);

/**
 * Read the time. Returns ESP_ERR_INVALID_STATE when the chip's oscillator-stop
 * flag is set (it lost power with no backup battery), so the time is not
 * trusted until the next phone sync.
 */
esp_err_t pump_rtc_read(pump_civil_time_t *out);

/** Write the time and clear the oscillator-stop flag. */
esp_err_t pump_rtc_write(const pump_civil_time_t *t);

#ifdef __cplusplus
}
#endif
