#pragma once

/*
 * Pump alerts: something the owner should know about (tank full, auto-off, a
 * power cut, a tank going out of range, a flat tank battery). docs/plan-alerts.md.
 *
 * An alert is a number (seq), a type and a tank or sensor, plus a 4-byte tag
 * that proves this pump made it: the first 4 bytes of
 * HMAC-SHA256(alert_key, device_id[6] || seq || type || arg). It goes into the
 * Bluetooth advertisement for an hour, so a phone whose app is closed can show
 * it from a background scan, and into a short log the app reads when it
 * connects, to catch up on what it missed.
 *
 * The alert key is one random key per pump, shared by its paired phones. It is
 * made when the first phone pairs and replaced when phones are removed.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "tanklink_uuid.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Values are sent to the app: keep in step with tanklink_uuids.dart. */
typedef enum {
    TL_ALERT_NONE = 0,
    TL_ALERT_TANK_FULL = 1,    /* a fill stopped because the tank is full; arg = tank slot */
    TL_ALERT_AUTO_OFF = 2,     /* a fill stopped by auto-off; arg = tank slot */
    TL_ALERT_POWER_CUT = 3,    /* a fill was cut short by a power cut; arg = tank slot */
    TL_ALERT_TANK_OFFLINE = 4, /* the selected tank's sensor went out of range; arg = slot */
    TL_ALERT_BATTERY_LOW = 5,  /* a sensor's battery is low; arg = sensor index */
    TL_ALERT_TEST = 6,         /* from the app's "Send test alert" */
} tl_alert_type_t;

#define PUMP_ALERT_LOG_MAX 8

void pump_alert_init(void);

/** Call every few hundred ms: ends an alert's time in the advertisement. */
void pump_alert_poll(void);

/** Make an alert. Ignored until a phone has paired (no key yet). Safe from any task. */
void pump_alert_raise(tl_alert_type_t type, uint8_t arg);

/** A sensor's battery reading: raises BATTERY_LOW when it drops to 20 % or
 * below (again after 24 hours while it stays low, and after it has been back
 * above 30 %). */
void pump_alert_note_battery(uint8_t sensor, uint8_t pct);

/** The alert key, false if there is none yet. */
bool pump_alert_key(uint8_t out[16]);

/** A phone paired: make the key if there is none. */
void pump_alert_phone_added(void);

/** Phones were removed: a new key if some remain, none if not. Drops the
 * current alert and the log, so a removed phone's key is useless. */
void pump_alert_phones_removed(bool some_remain);

/** The 7 bytes that follow the state byte in the advertisement's manufacturer
 * data: seq type arg tag[4]. False (and zeros) when no alert is current. */
bool pump_alert_adv_bytes(uint8_t out[7]);

/** Alert log payload: count(1), then count x seq(1) type(1) arg(1) age_min(u16),
 * newest first. Returns the length. */
size_t pump_alert_log_payload(uint8_t *out);
#define PUMP_ALERT_LOG_MAX_LEN (1 + PUMP_ALERT_LOG_MAX * 5)

/** Called (from another task) when the advertisement or the log changed. */
void pump_alert_set_change_callback(void (*cb)(void));

#ifdef __cplusplus
}
#endif
