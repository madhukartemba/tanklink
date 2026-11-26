# TankLink — guide for coding agents

Read this first. It covers how the parts fit together, where the shared contracts live, and the traps that have caused bad releases before.

## What this is

A local water-tank pump controller (no cloud control; the internet is only used for time, update checks and downloads, and "Report a problem"). The parts:

| Part | Folder | Hardware / stack | Talks to |
| --- | --- | --- | --- |
| Pump node | [`pump_node/`](pump_node/) | ESP32-C3 SuperMini, ESP-IDF v6.1, NimBLE | App over **BLE**, tank over **LoRa** |
| Tank node | [`tank_node/`](tank_node/) | Seeed XIAO ESP32-C3, ESP-IDF v6.1, battery, deep sleep | Pump over **LoRa**, app over **BLE** (OTA only) |
| App | [`tanklink_app/`](tanklink_app/) | Flutter, `flutter_blue_plus`, Android sideload | Pump over BLE, GitHub Releases for updates |
| Shared LoRa driver | [`components/tanklink_lora/`](components/tanklink_lora/) | SX1278 (RA-02, 433 MHz) driver + packet format | Used by both firmware nodes |
| Report service | [`report_worker/`](report_worker/) | Cloudflare Worker | Receives "Report a problem" from the app (issues in a private GitHub repo), serves the cached release list for update checks, answers the pump's "latest firmware" question and streams the firmware to it, and refreshes its cache on request (`scripts/refresh_worker.sh`) |

The pump can also join the home Wi-Fi (optional, set up from the app over BLE). Then the app controls it over TCP with the same bytes as BLE, and the pump checks for and installs its own firmware. BLE stays required for setup, phone pairing and the tank. The pump also raises **alerts** (tank full, auto-off, power cut, tank offline, battery low, sensor removed) that a phone shows even with the app closed, and it keeps its own **name**, so every phone shows the same one.

Flow: the tank wakes on a float change or a heartbeat (every 5 minutes by default; the app's "Tank updates" sets it on the pump, which sends it to each tank in its LoRa ACK), sends a LoRa STATUS packet with raw float pin levels, and sleeps. A pump pairs up to 4 tank sensors; each sensor's float mode says what its pins mean (full / almost-empty / second tank), giving up to 8 tanks. The pump fills one **selected** tank at a time (the user sets a valve or lever to match); only that tank's float can block a start or stop a fill. It drives the starter relays and serves state to the app over BLE. The app is the only UI besides the single pump button.

## Docs map

| Topic | File |
| --- | --- |
| BLE GATT + LoRa byte layouts | [`docs/PROTOCOL.md`](docs/PROTOCOL.md) |
| Pin maps (both boards) | [`docs/PINMAPS.md`](docs/PINMAPS.md), [`pump_node/WIRING.md`](pump_node/WIRING.md), [`tank_node/WIRING.md`](tank_node/WIRING.md) |
| LED / error codes | [`docs/ERROR_CODES.md`](docs/ERROR_CODES.md) |
| Build and flash (firmware + app), serial log, troubleshooting | [`docs/firmware-build-setup.md`](docs/firmware-build-setup.md) |
| Build options, app-set runtime settings, NVS layout, values that must match | [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) |
| Firmware releases (`pump-v*`, `tank-v*`) | [`docs/firmware-release.md`](docs/firmware-release.md) |
| App releases (`app-v*`) | [`docs/app-release.md`](docs/app-release.md) |
| Diagnostics and bug reports (plan and status) | [`docs/plan-diagnostics-and-bug-reports.md`](docs/plan-diagnostics-and-bug-reports.md), [`report_worker/README.md`](report_worker/README.md) |
| Alerts with the app closed (Bluetooth is built; Wi-Fi/webhook/push channels are designed, not built) | [`docs/plan-alerts.md`](docs/plan-alerts.md); layouts in [`docs/PROTOCOL.md`](docs/PROTOCOL.md) ("Alerts") |
| Local Wi-Fi: control and pump updates over Wi-Fi (plan and status) | [`docs/plan-local-wifi.md`](docs/plan-local-wifi.md); wire format in [`docs/PROTOCOL.md`](docs/PROTOCOL.md#wi-fi-transport) |

## Code map

Pump (`pump_node/main/`):

| File | Job |
| --- | --- |
| `main.c` | Boot order, NimBLE host and GAP events, advertising |
| `pump_control.c` | Pump on/off (each call says why: `pump_cause_t`), start checks, run time, last error, schedules, per-tank auto-off |
| `pump_history.c`, `pump_battery_log.c` | Last 200 fills with stop reason (read in pages); each sensor's daily battery low/high |
| `gatt_svr.c` | BLE service table, connections, Pair, notifications (also forwarded to Wi-Fi clients) |
| `gatt_payloads.c` | Byte layout of every characteristic read |
| `relay_control.c`, `board.c` | Starter relays (none, two-button pulses, single-phase MCB: relay 1 held while running; starts blocked per reason: OTA, pairing, reset); button and LED wiring |
| `lora_link.c` | Tank link: pairing, STATUS/ACK, UNPAIR (a tank that goes into pairing mode tells its old pump it left), per-sensor token and last-seen record |
| `pump_tanks.c` | Paired sensors (up to 4, each with its float mode), tank slots (up to 8), the selected tank. Keeps the invariants in `pump_tanks.h` |
| `pump_sched.c`, `pump_config.c`, `pump_pair.c` | Saved state in NVS: schedules, settings (including the pump's name, the auto-update switch and the tank update interval), phone pairing |
| `pump_clock.c`, `pump_rtc.c`, `pump_runlog.c` | Local time, DS3231, interrupted-fill detection |
| `pump_ota.c` | Firmware update, from either transport or from the pump itself (owner = a session id; one lock, another session's writes get BUSY) |
| `pump_api.c` | The app API, shared by both transports: one `pump_api_read` / `pump_api_write` per characteristic, sessions, sign-in. Pair stays in `gatt_svr.c` (BLE only) |
| `pump_wifi.c` | Optional Wi-Fi: saved network (`tl_wifi`), reconnect, scan, mDNS, SNTP time |
| `pump_wifi_api.c` | TCP server on port 7580: the same API over Wi-Fi (framing, tags) |
| `pump_autofill.c` | Auto-fill: when the selected tank fills itself (armed / paused, gap, allowed times, stop at the end), the state the app shows |
| `pump_buzz.c`, `buzzer.c` | Which events sound and how (switches, a sound per event, quiet hours); `buzzer.c` plays the patterns on its own task |
| `pump_window.c` | Daily time windows (auto-fill times, quiet hours), weekday |
| `pump_alert.c` | Alerts: events (tank full, auto-off, power cut, tank offline, battery low, sensor removed), the alert key (made when a signed-in phone first reads it), tag, log and the advertisement bytes |
| `pump_update.c` | When the pump checks (every 3 h, retry backoff, deferred while busy), when it installs by itself, the update lock (no start, pairing or reset while updating), the state the app shows |
| `pump_update_http.c` | The network half of the update: ask the report service what's newest, download an image into `pump_ota` |

App (`tanklink_app/lib/`):

| Folder / file | Job |
| --- | --- |
| `ble/protocol.dart` | Byte layouts (pure, unit tested) |
| `ble/models.dart` | Saved pumps, tank slots, schedules |
| `ble/pump_session.dart` | Connection (Wi-Fi first when the pump has it, else Bluetooth), state the screens read, commands |
| `alerts/alert_bridge.dart` | Dart side of the Android alert code (`android/.../Alert*.kt`: background Bluetooth scan, one notifier, boot receiver) |
| `link/` | `PumpChr` (one characteristic over either link), `wifi_link.dart` (TCP framing and tags), `ble_link.dart`, `pump_finder.dart` (mDNS lookup through MainActivity) |
| `ble/ota_upload.dart` | The shared OTA transfer for pump and tank |
| `update/` | GitHub release checks, downloads, update flows (the update sheet picks a method: the pump downloads it, the phone sends it over Wi-Fi, or over Bluetooth) |
| `screens/settings/alerts_screen.dart` | Alerts switches, test alert, permission and battery help |
| `screens/settings/auto_fill_screen.dart`, `buzzer_screen.dart` | Auto-fill (tanks, allowed times, gap, live state) and the buzzer (events, sounds, quiet hours) |
| `screens/`, `screens/home/`, `screens/settings/` | UI. One widget family per file. `settings/wifi_screen.dart` sets up the pump's Wi-Fi |
| `util/format.dart` | Shared labels |
| `util/water_use.dart`, `screens/usage_screen.dart` | Water and power: litres, energy and cost from run time (unit tested) and the charts. Flow, power, price and the 200-fill history all live on the pump |
| `diag/` | App log (`app_log.dart`), report text and redaction (`report_builder.dart`, unit tested), sending and offline queue (`report_sender.dart`) |
| `screens/report_problem_screen.dart` | Report a problem; opened from Settings, error banners and failed updates |

## Shared contracts — change all copies together

These values are duplicated by hand. There is no codegen. If you change one, change the others in the same commit.

| Contract | Pump (C) | Tank (C) | App (Dart) |
| --- | --- | --- | --- |
| BLE UUIDs, Cmd opcodes, OTA opcodes/status, payload lengths | `pump_node/main/tanklink_uuid.h` | `tank_node/main/tanklink_ble_uuid.h` | `tanklink_app/lib/ble/tanklink_uuids.dart` |
| LoRa packet format, tank update interval range | `components/tanklink_lora/include/tanklink_lora_proto.h` (shared) | same | `tankUpdateMinSec` / `MaxSec` in `tanklink_uuids.dart` |
| Sign-in answer, LoRa tag, tank OTA token | `components/tanklink_lora/tanklink_crypto.c` (shared) | same | `authResponse` in `tanklink_app/lib/ble/protocol.dart` (covered by `test/auth_test.dart`) |
| Report body (`POST /v1/report`) | — | — | `tanklink_app/lib/diag/report_builder.dart` (`toJson`) ↔ `report_worker/src/index.js` |
| BLE payload layouts | `pump_node/main/gatt_payloads.c` (reads) and the handlers in `gatt_svr.c` (writes) | `tank_node/main/tank_gatt.c` | `tanklink_app/lib/ble/protocol.dart` (covered by `test/protocol_test.dart`) |
| Buzzer and AutoFill payloads, buzzer events and sounds, auto-fill states | `pump_node/main/pump_buzz.h`, `buzzer.h`, `pump_autofill.h` (and their `.c`) | — | `BuzzerConfig`, `AutoFillInfo` in `tanklink_app/lib/ble/protocol.dart`, constants in `tanklink_uuids.dart` (`test/protocol_test.dart`) |
| Alert tag and advertisement layout | `pump_node/main/pump_alert.c`, `main.c` (`advertise`) | — | `lib/ble/protocol.dart` (`alertTag`, `pumpAdvAlert`; `test/protocol_test.dart`) and `AlertNotifier.kt` / `AlertScanReceiver.kt` |
| Alert types and what `arg` carries | `pump_node/main/pump_alert.h` | — | `tanklink_uuids.dart`, `AlertNotifier.kt` (the notification text) |
| LoRa UNPAIR notice | `pump_node/main/lora_link.c` (`on_unpair_packet`) | `tank_node/main/tank_link.c`, `main.c` (`tell_old_pump`) | — |
| Wi-Fi transport framing, tags, status codes | `pump_node/main/pump_wifi_api.c` | — | `tanklink_app/lib/link/wifi_link.dart` (covered by `test/wifi_link_test.dart`, same vectors as `scripts/wifi_api_check.py`) |
| Update request (`GET /v1/firmware/pump/latest`, `.../download/<ver>.bin`) | `pump_node/main/pump_update_http.c` | — | `report_worker/src/index.js` |
| Protocol versions | `TANKLINK_PROTO_MAJOR/MINOR` in `tanklink_uuid.h` | same names in `tanklink_ble_uuid.h` | `TankLinkUuids.protoMajor` |

Versioning rule (details in [`docs/PROTOCOL.md`](docs/PROTOCOL.md#versioning)):

- **Adding** a field, opcode or characteristic: append at the end of the payload, bump `TANKLINK_PROTO_MINOR`. Readers ignore bytes they don't know and accept writes longer than they need.
- **Moving, resizing or removing** anything: bump `TANKLINK_PROTO_MAJOR` in the firmware *and* `TankLinkUuids.protoMajor` in the app. The app then refuses to control a board on another major and only offers a firmware update.
- **Never change** the service UUID, the Info layouts, Pair, Auth or the OTA characteristics. They are how any app updates any board.
- LoRa follows the same append-only rule. Bump `TANKLINK_LORA_VER` only for a breaking layout change, and say in the release notes that pump and tank must be updated together.
- A board change that needs different firmware bumps `PUMP_HW_REV` / `TANK_HW_REV`. The manifest's `hw_revs` decides which boards are offered a binary.

## Versions

| Component | Where | Tag |
| --- | --- | --- |
| Pump | `TANKLINK_FW_MAJOR/MINOR/PATCH` in `pump_node/main/tanklink_uuid.h` (the string is built from them) | `pump-vX.Y.Z` |
| Tank | `TANK_FW_MAJOR/MINOR/PATCH` in `tank_node/main/tank_version.h` (same) | `tank-vX.Y.Z` |
| App | `version: X.Y.Z+N` in `tanklink_app/pubspec.yaml`; `N` (Android versionCode) must go up every release | `app-vX.Y.Z` |

The app finds updates by listing GitHub releases (through the report service's cached `GET /v1/releases`, or GitHub directly if that can't be reached) and picking the **highest semver** per tag prefix, not the newest by date. For firmware it skips any release whose manifest `proto_major` differs from the app's or whose `hw_revs` doesn't list the connected board. It verifies the `sha256` in each release's manifest JSON before installing or flashing.

## Building

Firmware (ESP-IDF v6.1 at `~/esp/esp-idf`):

```bash
. "$HOME/esp/esp-idf/export.sh"
cd pump_node   # or tank_node
idf.py build
```

If `export.sh` fails with *Python virtual environment ... not found*, the install has an env for a different Python. List `~/.espressif/python_env/` and point at the one that exists, for example:

```bash
export IDF_PYTHON_ENV_PATH="$HOME/.espressif/python_env/idf6.1_py3.14_env"
. "$HOME/esp/esp-idf/export.sh"
```

`export.sh` needs bash or zsh with `.`/`source`. In a non-interactive shell, run the whole build inside `bash -c '...'`.

App:

```bash
cd tanklink_app
flutter pub get
flutter analyze
flutter test            # protocol byte-layout tests + one smoke test
flutter build apk --release
```

**Signing:** release builds need `tanklink_app/android/key.properties` and the upload keystore `tanklink_app/android/app/upload-keystore.jks` (both gitignored), and fail without them. The upload key's certificate SHA-256 is `d4000075…ecc3a1`; every release from the next one on must be signed with it. Releases through app 1.2.0 are signed with this machine's debug key (`4eaeb0bf…afa381`), so the first upload-key release needs a one-time uninstall on each phone. Never publish with `allowDebugSigning` again. Check the signer before publishing:

```bash
apksigner verify --print-certs tanklink_app/build/app/outputs/flutter-apk/app-release.apk | grep SHA-256
```

`test/protocol_test.dart` checks every BLE byte layout against the firmware's; update it with any protocol change. The smoke test (`widget_test.dart`) currently fails offline: it pumps the full app, and the update checker's HTTP call gets a 400 in the test environment. That failure is not from your change.

## Release checklist (agents have got this wrong before)

`scripts/release.sh` does all of this (`--help`; `--dry-run` checks everything without publishing). Use it. The steps it automates:

1. Bump the version in source and commit it.
2. **Rebuild.** Never upload whatever is already in `build/`. It may be an older build.
3. Run the manifest script (`scripts/make_*_manifest.sh X.Y.Z`) and **check the sha256 differs from the previous release's manifest.** If it matches, you are about to re-ship the old binary.
4. Check that the binary contains the new version: `strings pump_node/build/pump_node.bin | grep -x X.Y.Z`.
5. Push the commit, then `gh release create <tag> --target <full 40-char sha>` (a short SHA fails with *target_commitish is invalid*) with exactly the asset names the app expects:
   - pump: `pump_node.bin`, `firmware-manifest.json`
   - tank: `tank_node.bin`, `firmware-manifest.json`
   - app: `TankLink.apk`, `app-manifest.json`. The install QR (`tanklink.madhukartemba.in/app`) redirects to the newest `app-v*` APK on its own (`docs/app-release.md`)
6. Release notes: a short `## Changes` list, then which pump / tank / app versions go with it. Call out wiring changes and anything that must be updated together. The app's update sheet shows the `## Changes` bullets as "What's new", so keep them user-facing.
7. Refresh the update service's cache: `scripts/refresh_worker.sh` (the script runs it for you). Without it a new release takes 10–20 minutes to reach pumps and phones.

Notes: `scripts/release.sh` needs a clean `main` that is pushed, and the signing keys (`keys/firmware_signing_key.pem`, `tanklink_app/android/key.properties` and keystore). It bumps the versions itself, so don't. All old GitHub releases were deleted once to save space (the git tags remain), so a new version must be higher than any old tag. Pump and tank firmware are separate releases; the app needs no tank release unless the LoRa/BLE contract changed.

## The report service (Cloudflare Worker)

`report_worker/` is deployed with `cd report_worker && npx wrangler deploy` (needs a logged-in `wrangler`; changes go live for everyone). Secrets: `GITHUB_TOKEN`, `APP_KEY`, `REFRESH_KEY` (`wrangler secret put`). Routes: `POST /v1/report`, `GET /v1/releases` (10-minute cache), `GET /v1/firmware/pump/latest?hw=&proto=` and `GET /v1/firmware/pump/download/<ver>.bin` (the pump fetches firmware **through** the Worker because GitHub's download host isn't reachable from every network), `GET /` (landing page, `report_worker/public/index.html`), `GET /app` (install QR redirect), `POST /v1/refresh` (refresh the cache now; needs the `x-refresh-key` header; `scripts/refresh_worker.sh` reads the key from the gitignored `report_worker/.refresh_key`). See `report_worker/README.md`.

## The pump's Wi-Fi, updates and alerts: things that bit us

- **Wi-Fi TX power is capped at 8.5 dBm** (`PUMP_WIFI_TX_POWER` in `pump_wifi.c`). At the default 20 dBm the SuperMini's antenna and supply made the router miss the pump's frames: every join ended in "auth expired" (reason 2). Only a failed key exchange is shown as "wrong password".
- **HTTPS needs the cross-signed roots option** (`CONFIG_MBEDTLS_CERTIFICATE_BUNDLE_CROSS_SIGNED_VERIFY`): both Cloudflare and GitHub send a chain ending in a cross-signed root.
- **Memory is tight.** With BLE and Wi-Fi up about 80 KB of heap is free; the pump's own HTTPS download dips to about 40 KB. Wi-Fi code runs from flash (IRAM options off), station mode only, small buffers; see `docs/CONFIGURATION.md` ("Memory") and keep `DIAG: heap` in mind after any change. The OTA image is about 1.5 MB of the 1.75 MB slot.
- **Update lock.** While an update runs (including download retries or a phone-sent one) `pump_update_in_progress()` is true: the pump won't start, pair or reset, and a start press is silent (no red light code). The app mirrors it (`PumpSession.pumpUpdating`): banner, greyed buttons.
- **Checks and installs.** Check every 3 hours (first one 1–61 min after Wi-Fi), retry 15 min doubling after a failure, deferred while the pump runs or pairing is open. Automatic install (on by default; nothing happens until Wi-Fi is set up) only when the pump has been idle 10 minutes and up 10 minutes, no schedule in the next hour, and an auto-fill tank isn't low. The download goes to `pump_ota` like any update, so the sha256, the signature check and the pump-off rule all apply.
- **Alerts** use one number (`seq`) and a tag per alert on every channel; the phone's `AlertNotifier.kt` shows each once, and stays quiet while the app is on screen (the app shows it). Only Bluetooth is built.
- **The pump's name lives on the pump** (Settings characteristic, Cmd `0xAE`); the app only renames the connected pump. Names saved on a phone before are not migrated.
- **App parsers are strict**: they need the full payload of the current protocol minor. Don't add tolerance for shorter, older payloads.

## Time on the pump

The pump keeps **local** time (whatever the phone sends, not UTC) in `pump_clock.c`, anchored to the DS3231 (`pump_rtc.c`) at boot and re-read hourly. Only two things need wall-clock time: **fill schedules** and the **tank's last-seen time**, which `lora_link.c` saves to NVS per sensor (`tl_tank/last<N>`) so a restart knows the real age. Everything else (auto-off, pairing windows, button holds) uses time since boot on purpose.

A fill cut short by a power cut or restart is detected by `pump_runlog.c` (a "running" record in NVS that a normal stop deletes) and shown in the app as a notice. The pump never restarts a fill on its own after power returns; that is a deliberate safety choice. Without a DS3231, or with its "oscillator stopped" flag set, the pump has no time until the app syncs.

## Hardware gotchas

- ESP32-C3 GPIO18/19 are USB D−/D+. Don't put relays or buttons there.
- Strap pins (GPIO2, 8, 9) affect boot. The pump button is on GPIO9 in parallel with BOOT, which is fine because it is only pressed after boot.
- Pump relays (GPIO0/1) are active-low by default and set to idle first thing in `app_main` (`relay_control_early_safe()`), so the motor never clicks on during reset.
- Tank: 10 kΩ pull-ups on NSS/SCK/MOSI are required or the SX1278 draws ~2 mA in deep sleep. See `tank_node/README.md`.
- The first flash after a partition-table change must be over USB with `erase-flash`, which clears pairing.
- The pump's serial port on this Mac is `/dev/cu.usbmodem2101`. A running serial capture holds the port and makes `idf.py flash` fail with "serial noise": stop it first.
- Firmware is signed. Builds need `keys/firmware_signing_key.pem` (gitignored, never commit it), and boards refuse BLE updates signed with another key. See `docs/firmware-build-setup.md#signing-key`.

## Testing reality

There is no hardware-in-the-loop setup. Firmware changes can be compile-checked, but behaviour needs real boards. Say so in your summary rather than claiming it was tested. For the app, `flutter analyze` and `flutter test` are the automated checks.

On this Mac you can flash the pump over USB (`idf.py -p /dev/cu.usbmodem2101 flash`) and install on the Android phone over wireless adb (`adb install -r`; give it a timeout, it can hang if the phone is locked). A release-signed APK installs over a released app; a debug build does not (different key). Debug builds have a "Test update over Wi-Fi" button (`runTestWifiUpdate`) that sends the image at `/sdcard/Android/data/com.tanklink.tanklink/files/pump_test.bin`.

## Conventions

- Commit subjects are plain sentences: `Fix tank select ...`, `Pump 0.9.0: ...`, `TankLink app 1.0.9: ...` for version bumps.
- Don't commit `sdkconfig`, `build/`, `managed_components/`, `dependencies.lock`, `key.properties`, or keystores (all gitignored). Pin and feature defaults belong in `sdkconfig.defaults` and `Kconfig.projbuild`.
- A local `sdkconfig` overrides `sdkconfig.defaults`. After changing defaults, check the local `sdkconfig` picked them up (or delete it and rebuild).
- **No old-version handling.** The project is in development: don't add migrations of saved NVS data, fallbacks for older firmware or apps, or compatibility shims. A changed NVS layout fails its size/magic check and loads defaults; a changed BLE layout keeps the protocol version as is. Say in the release notes what has to be re-paired or set again.
- **Never commit test-only edits** (a temporary firmware version label, hard-coded Wi-Fi credentials, shortened timers). Stage files by name, not `git add -A`, when such edits are in the tree; a temporary version label was once committed by accident.
- **No fallback code.** Besides old-version handling: no silent catch-and-continue around things that should work, no tolerant parsing, no stale-data fallbacks.
- User-facing app text is short and plain. Help text that describes the button or wiring must match the firmware.
