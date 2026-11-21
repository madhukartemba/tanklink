#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Pump NeoPixel error codes — long hard red blinks (same pattern as tank). */
#define PUMP_ERR_NONE          0
#define PUMP_ERR_TANK_FULL     1 /* Start denied — tank reports full */
#define PUMP_ERR_LORA_MISSING  2 /* RA-02 did not initialize */
#define PUMP_ERR_TANK_OFFLINE  3 /* Bound tank has no recent heartbeat */
#define PUMP_ERR_BLOCKED       4 /* Start denied — OTA / pairing lockout */
#define PUMP_ERR_NOT_PAIRED    5 /* Start ignored — pump not claimed */
#define PUMP_ERR_I2C           6 /* I2C bus for the clock did not start */
#define PUMP_ERR_RTC_MISSING   7 /* DS3231 did not answer */
#define PUMP_ERR_RTC_LOST      8 /* DS3231 oscillator stopped (lost power) */
#define PUMP_ERR_RTC_COMM      9 /* DS3231 read or write failed */
/* Start denied because a firmware update is running. Not shown as a light
 * code: the update light is already on, and this is not a fault. */
#define PUMP_ERR_UPDATING      10

#ifdef __cplusplus
}
#endif
