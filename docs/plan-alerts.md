# Plan: pump alerts on every channel (Bluetooth and Wi-Fi)

Status: **The Bluetooth channel (Phases 1 and 3) is built and compiles; it has not been tried with a pump and phone yet. The Wi-Fi channels (Phases 2, 4 and 5) are designed here but deferred.** Android only (12 and later). Builds on the shipped local Wi-Fi feature (pump 0.21.0, app 1.10.0).

**Scope decision:** alerts go over Bluetooth only for now, because it works with the app closed and needs no server, account or internet. The alert core is still built so that more channels can be added later without changing the alert format (a sink list in `pump_alert.c`). Anything below about webhooks, ntfy, Telegram or push is the later design, not part of the first release.

## Goal

The phone shows a notification when something happens at the pump (tank full, auto-off, power cut, sensor offline, sensor battery low), **even when the TankLink app is closed**, and the alert gets through even if one way of delivering it fails.

An alert is sent on **every channel that is turned on**, at the same time:

| Channel | Reaches the phone when | Needs |
| --- | --- | --- |
| **Bluetooth advertisement** | The phone is within Bluetooth range of the pump | Nothing else. Works with the router, the internet and Wi-Fi all down |
| **Wi-Fi: local webhook** | A server or service you run at home gets the alert and forwards it (ntfy, Home Assistant, a script) | The pump on Wi-Fi. A local server works with **no internet** |
| **Wi-Fi: internet push** (optional, Phase 5) | The phone has internet, anywhere in the world | The pump on Wi-Fi with internet, and the report Worker |
| **App open** | Always | The existing live updates over Bluetooth or Wi-Fi |

Each channel is independent, so a failed router, a phone out of Bluetooth range or a dead server leaves the others working. The phone **shows each alert once**, whichever channel brought it first (see "One alert, many channels").

## How it works

1. Something happens. `pump_alert_raise(type, arg)` makes **one alert**: a number (`seq`), a type, a tank or sensor, and a tag that proves the pump made it. The alert goes into a small saved **alert log**.
2. The pump hands that alert to every channel:
   - **Bluetooth:** the alert goes into the pump's advertisement (manufacturer data) for 60 minutes. The app has registered a background scan with a `PendingIntent`, so Android wakes a small receiver in the app without the app running.
   - **Wi-Fi webhook:** the pump sends an HTTP(S) POST to the address you set, and retries until it is accepted or 60 minutes have passed.
   - **Internet push (Phase 5):** the pump asks the Worker, which sends a Firebase push to the phones registered for that pump.
3. On the phone every channel ends in the same Kotlin code: check the tag, drop an alert already shown, post the notification.

No foreground service, no permanent notification, no open connection while the app is closed.

## One alert, many channels

- Every alert has a **`seq`** (1–255, wrapping, saved in NVS so a restart doesn't reuse numbers) and a **tag**: the first 4 bytes of `HMAC-SHA256(alert_key, device_id[6] ‖ seq ‖ type ‖ arg)`. The tag is the same on every channel.
- The phone keeps the last `seq` shown per pump (`AlertStore`). An alert is new only if `(seq − last) mod 256` is 1–127. So a second copy of the same alert from another channel is ignored, and an old copy arriving late is ignored too.
- If `seq` jumps by more than 1 the notification says "and N more: open TankLink".
- The alert log lets the app (and a phone that just came back in range) **catch up on alerts it missed**: when the app connects it reads the log and shows anything newer than its `seq`.

## Out of scope

- Cloud control of the pump (see the cloud question in the Wi-Fi plan notes: separate plan).
- iOS.
- Android 8–11: background scans there need "Allow all the time" location, which this plan does not ask for. The Bluetooth channel is hidden below Android 12 (`Build.VERSION.SDK_INT < 31`); the Wi-Fi channels still work on older phones through the webhook server's own app. This is a platform limit, not old-version handling.
- An "instant alerts" foreground-service mode. Add it only if testing shows Bluetooth delivery is too slow.
- Alerts to people who don't have the TankLink app (SMS, email). A webhook to a service that does that is possible, but not built here.

## Work split

Do this as separate commits, in order. Each ends in a state that builds and makes sense on its own, so running out of usage mid-way never leaves half-done code.

| Phase | What | Commit subject |
| --- | --- | --- |
| 1 | Pump: alert core, alert key, alert log, Bluetooth advertisement, test alert | `Pump alerts: core, Bluetooth advertisement, alert log.` |
| 2 | Pump: Wi-Fi webhook channel (settings, send, retry) | `Pump alerts over Wi-Fi: webhook.` |
| 3 | App: Kotlin scan and notifier, alert key, catch-up, settings, phone-maker guide | `App: alerts with the app closed.` |
| 4 | App: webhook settings, test button, delivery status | `App: set up the Wi-Fi alert webhook.` |
| 5 | Optional: internet push through the Worker, pump heartbeat | `Alerts over the internet.` |
| 6 | Docs and release | `Pump 0.22.0, TankLink app 1.11.0: alerts.` (via `scripts/release.sh`) |

Phases 1–2 are firmware and can be done without the app. Phase 5 is only worth doing if you want alerts away from home; skip it first and see whether Bluetooth plus a local server is enough.

---

## Phase 1: Pump core and Bluetooth

### 1.1 Alert types

New header `pump_node/main/pump_alert.h`:

```c
typedef enum {
    TL_ALERT_NONE = 0,
    TL_ALERT_TANK_FULL = 1,     /* fill stopped: PUMP_CAUSE_TANK_FULL; arg = slot */
    TL_ALERT_AUTO_OFF = 2,      /* fill stopped: PUMP_CAUSE_AUTO_OFF; arg = slot */
    TL_ALERT_POWER_CUT = 3,     /* pump_runlog_interrupted_this_boot(); arg = slot or 0xFF */
    TL_ALERT_TANK_OFFLINE = 4,  /* selected tank went stale (PUMP_ERR_TANK_OFFLINE); arg = slot */
    TL_ALERT_BATTERY_LOW = 5,   /* sensor battery <= 20 %; arg = sensor index */
    TL_ALERT_TEST = 6,          /* from the app's "Send test alert"; arg = 0xFF */
} tl_alert_type_t;
```

Same values in Dart (`tanklink_uuids.dart`) and `docs/PROTOCOL.md`.

| Type | Hook |
| --- | --- |
| TANK_FULL, AUTO_OFF | `set_state()` in `pump_control.c`, the `if (!on && s_on)` block where `pump_history_add()` is called. Only for those two `cause` values: app, button and system stops are the user's own action |
| POWER_CUT | After boot, once `pump_runlog_interrupted_this_boot()` is known |
| TANK_OFFLINE | Where the pump sets `PUMP_ERR_TANK_OFFLINE` for the selected tank. Once per offline spell, not on every poll |
| BATTERY_LOW | Where `pump_battery_log_note()` is called. Once per sensor per pump-local day, and again only after the level has gone back above 30 % |
| TEST | A new Cmd (below) |

### 1.2 `pump_alert.c`

- `pump_alert_init()`: loads `seq`, the alert key and the log from NVS (`tl_alert/seq`, `tl_alert/key`, `tl_alert/log`). No key yet means no alerts until the first phone pairs.
- `pump_alert_raise(type, arg)`: `seq` goes up (skip 0), the tag is computed with `tl_hmac_sha256` (`components/tanklink_lora/tanklink_crypto.c`), the alert is added to the **log** (last 8: seq, type, arg, time since boot or pump-local time if the clock is known) and handed to every channel through a small list of **sinks**:

  ```c
  typedef void (*pump_alert_sink_t)(const pump_alert_t *alert);
  void pump_alert_add_sink(pump_alert_sink_t sink);
  ```

  Bluetooth is the first sink, the webhook (Phase 2) the second, push (Phase 5) the third. A new alert replaces the current one on the advertisement; the app sees the `seq` gap.
- `pump_alert_poll()`: from the existing poll task. Clears the advertised alert 60 minutes after it was raised (time since boot, like auto-off) and refreshes the advertisement.
- Thread safety: `raise` runs from the poll and LoRa tasks, `advertise()` from the NimBLE host. Guard the state with a mutex, and refresh the advertisement the way `pump_pair`'s change callback does today (stop, then `advertise()` again, only when `s_adv_ready`).
- No alert key: never set the ALERT bit, and the other sinks stay quiet.

### 1.3 Advertisement layout

Today (`pump_node/main/main.c`, `advertise()`): flags (3) + name (2 + 13) + manufacturer data (2 + 2 + 1) = 23 of 31 bytes. The name is always 13 characters (`TankLink-` + 4 hex, or `TankLink-Pump`).

New manufacturer data, after the company ID `0xFFFF`:

| Byte | Field | Notes |
| --- | --- | --- |
| 0 | state | Existing byte. New bit `TANKLINK_ADV_STATE_ALERT 0x04`: an alert is in bytes 1–7 |
| 1 | `seq` | 1–255, then wraps to 1 (0 = none) |
| 2 | `type` | `tl_alert_type_t` |
| 3 | `arg` | Tank slot (0–7) or sensor index (0–3), depending on `type`; 0xFF = none |
| 4–7 | `tag` | As above |

The manufacturer data is **always 8 bytes** (bytes 1–7 zero with no alert), so the advertisement length doesn't change between states. AD structure: 1 + 1 + 2 + 8 = 12 bytes. Total: 3 + 15 + 12 = **30 of 31**. Add a `_Static_assert` so a longer name can't silently overflow.

The tank's manufacturer data is 6 bytes (its id), so a filter on 8 bytes never matches a tank. Check this on a real phone.

Add to `pump_node/main/tanklink_uuid.h` **and** `tanklink_app/lib/ble/tanklink_uuids.dart`:

```c
#define TANKLINK_ADV_STATE_ALERT 0x04
#define TANKLINK_ADV_MFG_LEN     8   /* state + seq + type + arg + tag[4] */
#define TANKLINK_ALERT_TAG_LEN   4
#define TANKLINK_ALERT_HOLD_S    3600
```

### 1.4 Alert key

One random 16-byte key per pump, shared by all its paired phones (one advertisement carries one tag). The Wi-Fi channels use the same key and tag, so the phone verifies every channel the same way.

- Created with `esp_fill_random` when the first phone pairs (`pump_pair_claim`), saved in NVS `tl_alert/key`.
- A new key whenever the phone list loses phones: unpair, `pump_pair_forget_others`, factory reset. The remaining phones read the new key on their next connect.
- New characteristics (UUID suffixes follow the Wifi characteristic `0x11`):

| Id | Name | Access | Payload |
| --- | --- | --- | --- |
| `0x12` | Alert key | read, after Auth only | 16 bytes |
| `0x13` | Alert log | read + notify, after Auth only | `count(1)` then `count` × `seq(1) type(1) arg(1) age_min(u16)`, newest first, up to 8 |
| `0x14` | Alert settings | read + write + notify, after Auth only | Phase 2 |

- New Cmd `0xAD` **TEST_ALERT**: raises `TL_ALERT_TEST`. For a test the Bluetooth advertisement is held for 2 minutes, not 60.
- Append-only change: bump `TANKLINK_PROTO_MINOR` 5 → 6.
- Over the Wi-Fi API the same characteristics work with no extra code (the characteristic id is the UUID suffix).

### 1.5 Docs in this phase

- `docs/PROTOCOL.md`: the advertisement layout, alert types, tag input, the three characteristics and the Cmd.
- `docs/CONFIGURATION.md`: NVS `tl_alert/*`.

### 1.6 Done when

- `idf.py build` passes and free RAM stays healthy (`DIAG: heap` in the log; see `docs/CONFIGURATION.md`, "Memory").
- Each alert fires once, not on every poll (check every hook in review).
- On a board: nRF Connect on a phone shows manufacturer data `FF FF 06 …` (paired + alert) after a test alert; the Alert log reads back.

---

## Phase 2: Pump Wi-Fi webhook

### 2.1 What it sends

An HTTP or HTTPS **POST** to a URL the user sets in the app, for each alert, as soon as the pump is on Wi-Fi. Two formats, chosen in the settings:

| Format | Body | For |
| --- | --- | --- |
| `json` (default) | `{"pump":"E5FE","seq":12,"type":"tank_full","slot":0,"tank":"Tank 1","tag":"a1b2c3d4","age_s":0}` | Home Assistant webhooks, scripts, Node-RED |
| `ntfy` | Plain text body with a `Title` header, for example `Title: Tank 1 is full`, body `Pump stopped.` | A self-hosted or public [ntfy](https://ntfy.sh) topic: a push notification on the phone from any network the phone is on, with no app code of ours |

The `tag` lets a receiver that has the alert key check the alert is genuine. Most won't, and don't need to.

### 2.2 Where the URL is allowed to point

The alert text goes in the open if it leaves the home over plain HTTP, so:

- `https://…` to any host (checked with the same certificate bundle as the update check).
- `http://…` **only** to a private address: `10.x`, `172.16–31.x`, `192.168.x`, or a name ending in `.local`. Anything else is refused when it is saved.
- The URL can contain a secret (an ntfy topic name acts as a password), so it is never written to the log, and the app shows it masked.

### 2.3 `pump_alert_wifi.c`

- A sink on the alert list. It puts the alert in a short queue (up to 4 pending) and wakes a short-lived task, like `pump_update.c`'s job task (6 KB stack; TLS needs about 35 KB at the peak, measured in the update dry run). Plain HTTP to a local server needs far less.
- **One network job at a time**: share the busy flag with `pump_update.c` (an update check or download defers the alert by a few seconds, and an alert defers the check). Alerts win: a pending alert waits at most for the download in progress, and the download is not started while one is queued.
- Sends with `esp_http_client`, 5 s connect timeout, 10 s total. Success is a 2xx answer.
- **Retry**: on failure or no Wi-Fi, try again after 5 s, 15 s, 1 min, then every 5 min, until the alert is accepted or 60 minutes have passed (the same hold as the advertisement). Retries happen when Wi-Fi comes back too: the queue lives through a Wi-Fi drop.
- Records the last result (`seq`, ok / failed, how many tries) for the app.
- Memory: the queue is 4 small structs. Nothing is kept open between alerts.

### 2.3.1 Alert settings characteristic (`0x14`)

Read: `enabled_types(u8 mask)` `webhook_on(1)` `format(1)` `last_seq(1)` `last_result(1: 0 none, 1 ok, 2 failed, 3 no Wi-Fi)` `tries(1)` `url_len(1)` `url` (read returns the URL **masked**: scheme, host and `…` only). Write ops, byte 0: `SET_TYPES mask`, `SET_WEBHOOK on format url_len url`, `CLEAR_WEBHOOK`. The URL is validated as in 2.2 and the write is refused with a clear error code if it isn't allowed.

`enabled_types` is also what the Bluetooth channel uses, so one set of switches turns an alert type on or off everywhere.

### 2.4 Done when

- `idf.py build` passes and the webhook reaches a local test server (for example `python -m http.server`-style logger or a free ntfy topic) when a test alert is raised, with Wi-Fi up, and arrives after Wi-Fi is turned off and back on.
- A URL pointing at a public host over `http://` is refused.
- Docs: `docs/PROTOCOL.md` ("Alert settings"), `docs/CONFIGURATION.md` (NVS).

---

## Phase 3: App, Bluetooth alerts and the notifier

### 3.1 Dart: alert key and catch-up

- `lib/ble/protocol.dart`: parse the 16-byte Alert key, the Alert log and the advertisement alert (`pumpAdvAlert(manufacturerData)` → seq, type, arg, tag), and a pure `alertTag(key, deviceId, seq, type, arg)` with `package:crypto`.
- `test/protocol_test.dart`: tests for all of them, with a fixed test vector. Compute the same vector in C (log it from the firmware once, or a short host-side check) so Dart and Kotlin are tested against the firmware's HMAC input order.
- `lib/ble/pump_session.dart`: after Auth succeeds (over **either** link), read the Alert key and save it with the pump (`lib/ble/models.dart`, next to `token`). Read the Alert log and hand any alert newer than the saved `seq` to the notifier (the **catch-up**). Follow the log's notifications while connected. Then call the bridge's `syncPumps`.

### 3.2 Dart and Kotlin bridge

`lib/alerts/alert_bridge.dart`, `MethodChannel('tanklink/alerts')`:

| Method | Does |
| --- | --- |
| `syncPumps(list)` | Each pump: device id (hex), MAC, display name, alert key (hex), tank slot names, sensor names. Kotlin saves it and re-registers the scan |
| `setEnabled(bool)`, `setTypes(list)` | Master switch and which alert types notify |
| `showAlert(pump, seq, type, arg)` | The app, when it is open, hands alerts it saw to the same notifier, so the dedupe is shared |
| `isSupported()` | `SDK_INT >= 31` (Bluetooth channel) |
| `batteryUnrestricted()`, `openBatterySettings()` | For the settings screen and the phone-maker guide |

Call `syncPumps` whenever saved pumps, the alert key or tank names change, and at app start.

### 3.3 Kotlin (`android/app/src/main/kotlin/.../`)

Kotlin keeps its own copy of what it needs in `SharedPreferences` (`tanklink_alerts`), because the receiver runs without Flutter.

- `AlertStore.kt`: pumps (id, MAC, name, key, slot and sensor names), enabled types, last shown `seq` per pump.
- `AlertNotifier.kt`: **the one place that shows an alert**. `handle(pump, seq, type, arg, tag)` checks the tag, applies the `(seq − last) mod 256` rule, saves `lastSeq`, and posts the notification. Used by the scan receiver, by the app (`showAlert`), and by Phase 5's push service. Channel `alerts` ("Pump alerts", default importance); one notification id per pump so a new alert replaces the old one.
- `AlertScanner.kt`: `register(context)` / `unregister(context)`.
  - One `ScanFilter`: `setManufacturerData(0xFFFF, data, mask)` with 8-byte data `{0x04, 0,0,0,0,0,0,0}` and mask `{0x04, 0,0,0,0,0,0,0}`.
  - `ScanSettings`: `SCAN_MODE_LOW_POWER`, `CALLBACK_TYPE_ALL_MATCHES`.
  - `PendingIntent.getBroadcast(..., FLAG_UPDATE_CURRENT or FLAG_MUTABLE)` to `AlertScanReceiver` (mutable is required: Android adds the scan results to it).
  - Register only when enabled, at least one pump has a key, and `BLUETOOTH_SCAN` is granted. Unregister otherwise.
- `AlertScanReceiver.kt` (exported = false): read `BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT`; for each result take the manufacturer data for `0xFFFF` (8 bytes, ALERT bit set), find the pump (MAC first, then every saved pump's key), and give it to `AlertNotifier`.
- `BootReceiver.kt`: on `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`, call `AlertScanner.register`.
- `MainActivity.kt`: the MethodChannel handler.

`AndroidManifest.xml`: add `POST_NOTIFICATIONS` and `RECEIVE_BOOT_COMPLETED`, and declare both receivers with `android:exported="false"`. The existing `BLUETOOTH_SCAN` with `neverForLocation` is enough on 12+. This flag stops Android delivering some beacon types, but plain manufacturer data should still come through: check on a real phone.

### 3.4 Notification text

Short and plain, using the app's names (`util/format.dart` for shared labels):

| Type | Title | Text |
| --- | --- | --- |
| TANK_FULL | `<tank name> is full` | `Pump stopped.` |
| AUTO_OFF | `Pump stopped by auto-off` | `<tank name> may not be full.` |
| POWER_CUT | `Fill interrupted` | `Power was cut while the pump ran. It won't restart on its own.` |
| TANK_OFFLINE | `<tank name> sensor offline` | `The pump can't see this tank.` |
| BATTERY_LOW | `<sensor name> battery low` | `Charge or check the solar panel.` |
| TEST | `Test alert` | `This is how a TankLink alert looks.` |

### 3.5 Settings UI

New `lib/screens/settings/alerts_section.dart`, in the pump settings:

- Switch "Alerts when the app is closed". Turning it on asks for notifications (Android 13+) and Nearby devices if needed.
- One switch per alert type, all on by default (these are the pump's `enabled_types`, so they apply to every channel).
- "Bluetooth: works when your phone is near the pump." (hidden below Android 12).
- **Send test alert** button: raises a test alert and shows, per channel, whether it arrived ("Bluetooth: seen", "Wi-Fi: delivered" once Phase 4 exists). This is how you check the redundancy works.
- The phone-maker guide below.

### 3.6 Phone-maker guide

On Xiaomi/Redmi/POCO, Oppo, Realme, Vivo, OnePlus and Huawei (`Build.MANUFACTURER`), show a one-time sheet after alerts are turned on: allow Autostart and set battery to "No restrictions", with a button that opens the app's settings. Keep it short. Re-show it from the alerts section. Offer `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only if testing shows it's needed (sideloaded apps may use it).

### 3.7 Done when

- `flutter analyze` is clean and `flutter test` passes, apart from the known offline smoke-test failure (see `AGENTS.md`).
- `flutter build apk --release` builds.
- On a real phone and pump: swipe the app away, stop a fill with auto-off, and the notification appears. Restart the phone and repeat.

---

## Phase 4: App, the Wi-Fi webhook

- `lib/screens/settings/alerts_section.dart` gets a **Wi-Fi alerts** part: a switch, a field for the address (shown masked once saved), the format (JSON or ntfy), and a one-line explanation: "The pump sends each alert to this address over your home Wi-Fi. Use a server at home to work without internet, or an ntfy topic to get a push on your phone."
- Writes the Alert settings characteristic (over Bluetooth or Wi-Fi), shows the pump's error if it refuses the address ("Plain http:// only works for addresses on your home network").
- Shows the last delivery: "Last alert delivered 14:02" or "Last alert couldn't be delivered (3 tries)", from `last_result`.
- A short help sheet with two ready-made setups: **ntfy** (install the ntfy app, pick a long random topic, paste `https://ntfy.sh/<topic>` and choose the ntfy format) and **Home Assistant** (create a webhook automation, paste its URL, keep the JSON format).
- Tests: parsing and encoding of the Alert settings payload in `test/protocol_test.dart`.

Done when: a test alert from the app reaches an ntfy topic on a second phone, and the delivery status updates.

---

## Phase 5 (optional): internet push through the Worker

Only if you want alerts when the phone is far from both the pump and any home server. Costs a Firebase project (free at this size) and the Firebase library in the app.

- **Registration.** The app gets an FCM token and calls `POST /v1/alert/register` on the Worker with the pump's id, the alert key and the token (over HTTPS). The Worker keeps `pump id → key, tokens` in KV.
- **Pump to Worker.** A third sink posts `POST /v1/alert` with the alert and its tag. The Worker checks the tag with the stored key, then sends an FCM data message with the same fields to each registered token. The Worker can't invent alerts for other pumps without their key.
- **Phone.** A `FirebaseMessagingService` receives the message and calls `AlertNotifier.handle` (the same dedupe and tag check as Bluetooth).
- **Heartbeat.** The pump posts `/v1/heartbeat` every 10 minutes. A Worker cron trigger sends a "pump hasn't been seen for 30 minutes" alert if it stops (power cut, router down, pump crashed). This is the one alert no pump-side channel can send, because the pump isn't there to send it.
- **Privacy.** The Worker sees the pump id, alert type and tank name. Say so in the settings help text. The alert key is stored in KV: use a separate key per channel if that is a concern.
- Revoking a phone ("forget others") rotates the alert key and removes the old tokens.

Effort: about 1 week including the Firebase setup.

---

## Phase 6: Docs and release

- `AGENTS.md` code map: `pump_alert.c`, `pump_alert_wifi.c`, `lib/alerts/`, the Kotlin files; the shared contracts table (alert tag and layout: `pump_alert.c` ↔ `AlertNotifier.kt` ↔ `lib/ble/protocol.dart`).
- `docs/ERROR_CODES.md` if alert names should match error names.
- Release with `scripts/release.sh`: pump 0.22.0 and app 1.11.0 (new characteristics). Release notes: the pump and the app must both be updated for alerts. Each phone must connect to the pump once after updating to get the alert key. Wi-Fi alerts need the pump on Wi-Fi.

## Test matrix (real hardware; nothing here can be automated)

| Case | Expect |
| --- | --- |
| App swiped away, auto-off stop | Bluetooth notification within about a minute |
| Same alert on Bluetooth and the webhook | **One** notification, not two |
| Router off, pump on Bluetooth only | Bluetooth alert still arrives |
| Phone out of Bluetooth range, ntfy topic set | The ntfy push arrives; the TankLink notification appears on return, with no duplicate |
| Phone away and Bluetooth only | Nothing until back in range, then the alert (catch-up from the log or the 60-minute advertisement) |
| Webhook server down for 10 minutes | Delivered when it comes back, within the 60-minute window |
| Alert after 60 minutes of no delivery | Dropped on every channel; the app still shows it from the alert log when it connects |
| Screen off for 1+ hour, then an alert | Notification, maybe delayed by Doze |
| Phone restarted, app never opened | Bluetooth notification (boot receiver) |
| App force-stopped | No notification from the Bluetooth channel until the app is opened again. That's expected: say so in the settings help text |
| Two alerts in a row while out of range | One notification with "and 1 more" |
| Two phones paired | Both notify |
| One phone removed with "forget others" | The removed phone stops getting alerts; the kept phone gets them after reconnecting |
| Tank sensor nearby advertising | Never triggers the receiver |
| Webhook set to `http://` on a public address | Refused with a clear message |
| Update check running when an alert is raised | The alert still goes out within seconds |
| Phones | At least one Samsung, one Xiaomi/Redmi, one Pixel or stock Android |

## Things to check early (could change the plan)

1. Android delivers PendingIntent scan results for this filter with the app swiped away, on a Xiaomi phone. If it doesn't, the foreground-service "instant alerts" mode moves into scope, and the webhook channel matters more.
2. The 8-byte filter doesn't match the tank's 6-byte manufacturer data.
3. Changing the advertisement while phones are connected doesn't drop those connections (NimBLE stop and restart of advertising only).
4. The pump can send a TLS webhook while two phones are connected over Wi-Fi without dropping below about 30 KB of free heap (`DIAG: heap`). If it can't, send the webhook over plain HTTP to a local server only, and leave HTTPS to Phase 5's single Worker call.
5. Whether ntfy's free server is acceptable for you (alert text is visible to it). A self-hosted ntfy on the Proxmox box removes that concern.
