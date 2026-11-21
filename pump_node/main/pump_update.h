#pragma once

/*
 * The pump looks for and installs its own firmware over Wi-Fi (plan:
 * docs/plan-local-wifi.md, Phase 3). It asks the report service for the
 * newest release that fits this board, downloads it over HTTPS and feeds it
 * to pump_ota, so the sha256 check, the signature check, the pump-off rule and
 * the OtaStatus notifications are exactly those of an update from the app. A
 * binary that isn't signed with the TankLink key is refused whatever the
 * server says.
 */

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Load the "updated automatically" notice. Call after NVS and the clock start. */
void pump_update_init(void);

/** Every ~500 ms: the daily check, and the optional automatic install. */
void pump_update_poll(void);

/** Look for a newer firmware now (needs Wi-Fi). Returns at once; the result
 * shows in pump_update_state() / pump_update_check_result(). */
esp_err_t pump_update_request_check(void);

/** Download and install the update found by the last check. Refused while the
 * pump runs, during another update, or without Wi-Fi or a found update. */
esp_err_t pump_update_request_install(void);

/** TANKLINK_UPDATE_* */
uint8_t pump_update_state(void);
/** TANKLINK_CHECK_* */
uint8_t pump_update_check_result(void);
/** major, minor, patch of the update found (zeros = none). */
void pump_update_available_version(uint8_t out[3]);
/** Version installed by itself (automatic install), until dismissed (zeros = none). */
void pump_update_overnight_version(uint8_t out[3]);
void pump_update_dismiss_overnight(void);

#ifdef __cplusplus
}
#endif
