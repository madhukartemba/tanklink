# Plan: BLE alerts with the app closed

Status: **planned, not started.** Android only (12 and later). No Wi-Fi, no cloud.

## Goal

The phone shows a notification when something happens at the pump (tank full, auto-off, power cut, sensor offline, sensor battery low), even when the TankLink app is closed or swiped away. It works while the phone is in Bluetooth range of the pump.

## How it works

1. When an alert happens, the pump puts it in its **BLE advertisement** (manufacturer data), signed with a pump-wide **alert key**, and keeps it there for 60 minutes.
2. The app registers a background BLE scan with a **PendingIntent** (`BluetoothLeScanner.startScan(filters, settings, PendingIntent)`). Android does the scanning; the app's process does not need to run.
3. When Android sees a matching advertisement it starts a small `BroadcastReceiver` in the app. The receiver checks the signature against the saved pumps' alert keys, drops alerts it already showed, and posts a notification.

No foreground service, no permanent notification, no open BLE connection.

## Out of scope for this plan

- Wi-Fi or cloud alerts (later: the same alert types go through the Worker).
- iOS.
- Android 8–11. Background scans there need "Allow all the time" location, which this plan does not ask for. The app hides the alerts setting below Android 12 (`Build.VERSION.SDK_INT < 31`). This is a platform limit, not old-version handling.
- An "instant alerts" foreground-service mode. Add it only if testing shows the delay is too long.

## Work split

Do this as **three commits**, in order. Each ends in a state that builds and makes sense on its own, so running out of usage mid-way never leaves half-done code.

| Phase | What | Commit subject |
| --- | --- | --- |
| 1 | Pump firmware: alert key, alert events, advertisement | `Pump alerts in the BLE advertisement.` |
| 2 | App: read the alert key, native background scan, notifications, settings | `App: BLE alerts with the app closed.` |
| 3 | Phone-maker battery guide, docs, versions | `Pump 0.20.0, TankLink app 1.9.0: BLE alerts.` (via `scripts/release.sh`) |

---

## Phase 1 — Pump firmware

### 1.1 Advertisement layout

Today (`pump_node/main/main.c`, `advertise()`): flags (3) + name (2 + 13) + manufacturer data (2 + 2 + 1) = 23 of 31 bytes. The name is always 13 characters (`TankLink-` + 4 hex, or `TankLink-Pump`).

New manufacturer data, after the company ID `0xFFFF`:

| Byte | Field | Notes |
| --- | --- | --- |
| 0 | state | Existing byte. New bit `TANKLINK_ADV_STATE_ALERT 0x04`: an alert is in bytes 1–7 |
| 1 | `seq` | Alert number, 1–255 then wraps to 1 (0 = none). Saved in NVS so a restart does not reuse numbers |
| 2 | `type` | `tl_alert_type_t` below |
| 3 | `arg` | Tank slot (0–7) or sensor index (0–3), depending on `type`; 0xFF = none |
| 4–7 | `tag` | First 4 bytes of `HMAC-SHA256(alert_key, device_id[6] ‖ seq ‖ type ‖ arg)` |

The manufacturer data is **always 8 bytes** (bytes 1–7 zero when there is no alert), so the advertisement length doesn't change between states. AD structure: 1 + 1 + 2 + 8 = 12 bytes. Total: 3 + 15 + 12 = **30 of 31**. Add a `_Static_assert` or a runtime check so a longer name can't silently overflow.

The tank's manufacturer data is 6 bytes (its id), so a filter on 8 bytes never matches a tank (Android's `matchesPartialData` rejects data shorter than the filter). Check this on a real phone.

Add to `pump_node/main/tanklink_uuid.h` **and** `tanklink_app/lib/ble/tanklink_uuids.dart`:

```c
#define TANKLINK_ADV_STATE_ALERT 0x04
#define TANKLINK_ADV_MFG_LEN     8   /* state + seq + type + arg + tag[4] */
#define TANKLINK_ALERT_TAG_LEN   4
#define TANKLINK_ALERT_HOLD_S    3600
```

### 1.2 Alert types

New header `pump_node/main/pump_alert.h`:

```c
typedef enum {
    TL_ALERT_NONE = 0,
    TL_ALERT_TANK_FULL = 1,     /* fill stopped: PUMP_CAUSE_TANK_FULL; arg = slot */
    TL_ALERT_AUTO_OFF = 2,      /* fill stopped: PUMP_CAUSE_AUTO_OFF; arg = slot */
    TL_ALERT_POWER_CUT = 3,     /* pump_runlog_interrupted_this_boot(); arg = slot or 0xFF */
    TL_ALERT_TANK_OFFLINE = 4,  /* selected tank went stale (PUMP_ERR_TANK_OFFLINE); arg = slot */
    TL_ALERT_BATTERY_LOW = 5,   /* sensor battery <= 20 %; arg = sensor index */
} tl_alert_type_t;
```

Same values in Dart (`tanklink_uuids.dart`) and in `docs/PROTOCOL.md`.

Where each one is raised:

| Type | Hook |
| --- | --- |
| TANK_FULL, AUTO_OFF | `set_state()` in `pump_control.c`, the `if (!on && s_on)` block where `pump_history_add()` is called. Only for those two `cause` values: app, button and system stops are the user's own action |
| POWER_CUT | After boot, once `pump_runlog_interrupted_this_boot()` is known (where the app notice is set up today) |
| TANK_OFFLINE | Where the pump sets `PUMP_ERR_TANK_OFFLINE` for the selected tank. Raise once per offline spell, not on every poll |
| BATTERY_LOW | Where `pump_battery_log_note()` is called. Once per sensor per pump-local day, and only again after the level has gone back above 30 % (hysteresis) |

### 1.3 `pump_alert.c`

- `void pump_alert_init(void)`: loads `seq` and the alert key from NVS (`tl_alert/seq`, `tl_alert/key`). No key yet → none until the first phone pairs.
- `void pump_alert_raise(tl_alert_type_t type, uint8_t arg)`: `seq` goes up (skip 0), saved to NVS, tag computed with `tl_hmac_sha256` (`components/tanklink_lora/tanklink_crypto.c`), alert time stored, advertisement refreshed. A newer alert replaces the current one; the app sees the `seq` gap.
- `void pump_alert_poll(void)`: from the existing poll task. Clears the alert 60 minutes after it was raised (time since boot, like auto-off) and refreshes the advertisement.
- `void pump_alert_adv_bytes(uint8_t out[7])`: what `advertise()` copies into bytes 1–7.
- Thread safety: `raise` runs from the poll/LoRa tasks and `advertise()` from the NimBLE host. Guard the state with a mutex or critical section, and refresh the advertisement the same way `pump_pair`'s change callback does today (stop, then `advertise()` again, only when `s_adv_ready`).
- No alert key → never set the ALERT bit.

### 1.4 Alert key

One random 16-byte key per pump, shared by all its paired phones (one advertisement can only carry one tag).

- Created with `esp_fill_random` when the first phone pairs (`pump_pair_claim`), saved in NVS `tl_alert/key`.
- New key when the phone list changes in a way that removes phones: unpair, `pump_pair_forget_others`, factory reset. The remaining phones read the new key on their next connect.
- New characteristic **Alert key**, UUID suffix `0x11` (`TANKLINK_CHR_ALERT_KEY_INIT`), read only, **after Auth only** (same check the other protected reads use in `gatt_svr.c`). Payload: 16 bytes.
- Append-only change: bump `TANKLINK_PROTO_MINOR` 3 → 4.

### 1.5 Docs in this phase

- `docs/PROTOCOL.md`: the new advertisement layout, alert types, tag input, the Alert key characteristic.
- `docs/CONFIGURATION.md`: NVS `tl_alert/seq`, `tl_alert/key`.

### 1.6 Done when

- `idf.py build` passes (see `AGENTS.md` → Building).
- The binary is still under the 1.75 MB OTA slot (it's about 725 KB today).
- Code review of every hook: each alert fires once, not on every poll.
- Behaviour can only be checked on a real board. A quick manual check: nRF Connect on a phone shows manufacturer data `FF FF 06 …` (paired + alert) after the pump stops on auto-off.

---

## Phase 2 — App

### 2.1 Dart: alert key and pump list

- `lib/ble/protocol.dart`: parse the 16-byte Alert key read. Add the advertisement alert parser (`pumpAdvAlert(manufacturerData)` → seq, type, arg, tag) next to `pumpAdvState`, and a pure `alertTag(key, deviceId, seq, type, arg)` using `package:crypto`.
- `test/protocol_test.dart`: tests for both, including a fixed test vector. Compute the same vector in C (a short host-side check, or log it from the firmware once) so Dart and Kotlin are tested against the firmware's HMAC input order.
- `lib/ble/pump_session.dart`: after Auth succeeds, read the Alert key and save it with the pump (`lib/ble/models.dart`, next to `token`; stored the same way the token is). Then call the bridge's `syncPumps`.

### 2.2 Dart ↔ Kotlin bridge

`lib/alerts/alert_bridge.dart`, `MethodChannel('tanklink/alerts')`:

| Method | Does |
| --- | --- |
| `syncPumps(list)` | Each pump: device id (hex), MAC, display name, alert key (hex), tank slot names, sensor names. Kotlin saves it and re-registers the scan |
| `setEnabled(bool)`, `setTypes(list)` | Master switch and which alert types notify |
| `isSupported()` | `SDK_INT >= 31` |
| `batteryUnrestricted()`, `openBatterySettings()` | For the settings screen and the phone-maker guide |

Call `syncPumps` whenever saved pumps, the alert key or tank names change, and at app start.

### 2.3 Kotlin (`android/app/src/main/kotlin/.../`)

Kotlin keeps its own copy of what it needs in `SharedPreferences` (`tanklink_alerts`), because the receiver runs without Flutter.

- `AlertStore.kt`: pumps (id, MAC, name, key, slot and sensor names), enabled types, last shown `seq` per pump.
- `AlertScanner.kt`: `register(context)` / `unregister(context)`.
  - One `ScanFilter`: `setManufacturerData(0xFFFF, data, mask)` with 8-byte data `{0x04, 0,0,0,0,0,0,0}` and mask `{0x04, 0,0,0,0,0,0,0}`.
  - `ScanSettings`: `SCAN_MODE_LOW_POWER`, `CALLBACK_TYPE_ALL_MATCHES`.
  - `PendingIntent.getBroadcast(..., FLAG_UPDATE_CURRENT or FLAG_MUTABLE)` to `AlertScanReceiver` (mutable is required: Android adds the scan results to it).
  - Register only when enabled, at least one pump has a key, and `BLUETOOTH_SCAN` is granted. Unregister otherwise.
- `AlertScanReceiver.kt` (exported = false):
  - Read `BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT`.
  - For each result: manufacturer data for `0xFFFF`, 8 bytes, ALERT bit set.
  - Find the pump: try the MAC first, then every saved pump's key. Check the tag with `javax.crypto.Mac` (HmacSHA256), comparing the first 4 bytes.
  - New only if `(seq - lastSeq) mod 256` is 1–127, so replays of older alerts are ignored. Save `lastSeq`.
  - Gap of more than 1 → add "and N more — open TankLink" to the text.
  - Post the notification. Tapping it opens the app.
  - Keep `onReceive` short; no `goAsync` work needed.
- `BootReceiver.kt`: on `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`, call `AlertScanner.register`.
- `AlertNotifier.kt`: channel `alerts` ("Pump alerts", default importance). One notification id per pump, so a new alert replaces the old one.
- `MainActivity.kt`: the MethodChannel handler.

`AndroidManifest.xml`: add `POST_NOTIFICATIONS` and `RECEIVE_BOOT_COMPLETED`, and declare both receivers with `android:exported="false"`. The existing `BLUETOOTH_SCAN` with `neverForLocation` is enough on 12+. Note that this flag stops Android delivering some beacon types, but plain manufacturer data still comes through. Check this on a real phone.

### 2.4 Notification text

Short and plain, using the app's names (`util/format.dart` for shared labels):

| Type | Title | Text |
| --- | --- | --- |
| TANK_FULL | `<tank name> is full` | `Pump stopped.` |
| AUTO_OFF | `Pump stopped by auto-off` | `<tank name> may not be full.` |
| POWER_CUT | `Fill interrupted` | `Power was cut while the pump ran. It won't restart on its own.` |
| TANK_OFFLINE | `<tank name> sensor offline` | `The pump can't see this tank.` |
| BATTERY_LOW | `<sensor name> battery low` | `Charge or check the solar panel.` |

### 2.5 Settings UI

New `lib/screens/settings/alerts_section.dart`:

- Switch "Alerts when the app is closed". Turning it on asks for notifications (Android 13+) and Nearby devices if needed.
- One switch per alert type (all on by default).
- A line: "Works when your phone is near the pump."
- Hidden below Android 12.

### 2.6 Done when

- `flutter analyze` is clean and `flutter test` passes, apart from the known offline smoke-test failure (see `AGENTS.md`).
- `flutter build apk --release` builds.
- Manual check on a real phone and pump: swipe the app away, stop a fill with auto-off, and the notification appears. Restart the phone and repeat.

---

## Phase 3 — Phone makers, docs, release

- **Phone-maker guide.** On Xiaomi/Redmi/POCO, Oppo, Realme, Vivo, OnePlus and Huawei (`Build.MANUFACTURER`), show a one-time sheet after alerts are turned on: allow Autostart and set battery to "No restrictions", with a button that opens the app's settings. Keep it short. Re-show it from the alerts section.
- Offer `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only if testing shows it's needed. Sideloaded apps may use it.
- Docs: `AGENTS.md` code map (`pump_alert.c`, `lib/alerts/`, the Kotlin files), and `docs/ERROR_CODES.md` if alert names should match error names.
- Release with `scripts/release.sh`: pump minor bump (new characteristic) and an app minor bump. Release notes: the pump and the app must both be updated for alerts. Each phone must connect to the pump once after updating to get the alert key.

## Test matrix (real hardware; nothing here can be automated)

| Case | Expect |
| --- | --- |
| App swiped away, auto-off stop | Notification within about a minute |
| Screen off for 1+ hour, then an alert | Notification, maybe delayed by Doze |
| Phone restarted, app never opened | Notification (boot receiver) |
| App force-stopped | No notification until the app is opened again. That's expected: say so in the settings help text |
| Phone out of range during the alert, back within 60 min | Notification on return |
| Two alerts in a row while out of range | One notification with "and 1 more" |
| Two phones paired | Both notify |
| One phone removed with "forget others" | The removed phone stops getting alerts; the kept phone gets them after reconnecting |
| Tank sensor nearby advertising | Never triggers the receiver |
| Phones | At least one Samsung, one Xiaomi/Redmi, one Pixel or stock Android |

## Things to check early (could change the plan)

1. Android delivers PendingIntent scan results for this filter with the app swiped away, on a Xiaomi phone. If it doesn't, the foreground-service "instant alerts" mode moves into scope.
2. The 8-byte filter doesn't match the tank's 6-byte manufacturer data.
3. Changing the advertisement while phones are connected doesn't drop those connections (NimBLE stop and restart of advertising only).
