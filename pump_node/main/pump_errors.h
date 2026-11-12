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

#ifdef __cplusplus
}
#endif
