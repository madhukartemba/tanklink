# TankLink — guide for coding agents

Read this first. It covers how the parts fit together, where the shared contracts live, and the traps that have caused bad releases before.

## What this is

A local (no cloud) water-tank pump controller with three parts:

| Part | Folder | Hardware / stack | Talks to |
| --- | --- | --- | --- |
| Pump node | [`pump_node/`](pump_node/) | ESP32-C3 SuperMini, ESP-IDF v6.1, NimBLE | App over **BLE**, tank over **LoRa** |
| Tank node | [`tank_node/`](tank_node/) | Seeed XIAO ESP32-C3, ESP-IDF v6.1, battery, deep sleep | Pump over **LoRa**, app over **BLE** (OTA only) |
| App | [`tanklink_app/`](tanklink_app/) | Flutter, `flutter_blue_plus`, Android sideload | Pump over BLE, GitHub Releases for updates |
| Shared LoRa driver | [`components/tanklink_lora/`](components/tanklink_lora/) | SX1278 (RA-02, 433 MHz) driver + packet format | Used by both firmware nodes |
| Report service | [`report_worker/`](report_worker/) | Cloudflare Worker | Receives "Report a problem" from the app (issues in a private GitHub repo) and serves the cached release list for update checks |

Flow: the tank wakes on a float change or a 5-minute heartbeat, sends a LoRa STATUS packet with raw float pin levels, and sleeps. A pump pairs up to 4 tank sensors; each sensor's float mode says what its pins mean (full / almost-empty / second tank), giving up to 8 tanks. The pump fills one **selected** tank at a time (the user sets a valve or lever to match); only that tank's float can block a start or stop a fill. It drives the starter relays and serves state to the app over BLE. The app is the only UI besides the single pump button.

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
| BLE alerts with the app closed (plan) | [`docs/plan-ble-alerts.md`](docs/plan-ble-alerts.md) |
| Local Wi-Fi: control and pump updates over Wi-Fi (plan) | [`docs/plan-local-wifi.md`](docs/plan-local-wifi.md) |

## Code map

Pump (`pump_node/main/`):

| File | Job |
| --- | --- |
| `main.c` | Boot order, NimBLE host and GAP events, advertising |
| `pump_control.c` | Pump on/off (each call says why: `pump_cause_t`), start checks, run time, last error, schedules, per-tank auto-off |
| `pump_history.c`, `pump_battery_log.c` | Last 200 fills with stop reason (read in pages); each sensor's daily battery low/high |
| `gatt_svr.c` | BLE service table, one handler per characteristic, connections, notifications |
| `gatt_payloads.c` | Byte layout of every characteristic read |
| `relay_control.c`, `board.c` | Starter relays; button and LED wiring |
| `lora_link.c` | Tank link: pairing, STATUS/ACK, per-sensor token and last-seen record |
| `pump_tanks.c` | Paired sensors (up to 4, each with its float mode), tank slots (up to 8), the selected tank. Keeps the invariants in `pump_tanks.h` |
| `pump_sched.c`, `pump_config.c`, `pump_pair.c` | Saved state in NVS: schedules, settings, phone pairing |
| `pump_clock.c`, `pump_rtc.c`, `pump_runlog.c` | Local time, DS3231, interrupted-fill detection |
| `pump_ota.c` | Firmware update over BLE |

App (`tanklink_app/lib/`):

| Folder / file | Job |
| --- | --- |
| `ble/protocol.dart` | Byte layouts (pure, unit tested) |
| `ble/models.dart` | Saved pumps, tank slots, schedules |
| `ble/pump_session.dart` | Connection, state the screens read, commands |
| `ble/ota_upload.dart` | The shared OTA transfer for pump and tank |
| `update/` | GitHub release checks, downloads, update flows |
| `screens/`, `screens/home/`, `screens/settings/` | UI. One widget family per file |
| `util/format.dart` | Shared labels |
| `util/water_use.dart`, `screens/usage_screen.dart` | Water and power: litres, energy and cost from run time (unit tested) and the charts. Flow, power, price and the 200-fill history all live on the pump |
| `diag/` | App log (`app_log.dart`), report text and redaction (`report_builder.dart`, unit tested), sending and offline queue (`report_sender.dart`) |
| `screens/report_problem_screen.dart` | Report a problem; opened from Settings, error banners and failed updates |

## Shared contracts — change all copies together

These values are duplicated by hand. There is no codegen. If you change one, change the others in the same commit.

| Contract | Pump (C) | Tank (C) | App (Dart) |
| --- | --- | --- | --- |
| BLE UUIDs, Cmd opcodes, OTA opcodes/status, payload lengths | `pump_node/main/tanklink_uuid.h` | `tank_node/main/tanklink_ble_uuid.h` | `tanklink_app/lib/ble/tanklink_uuids.dart` |
| LoRa packet format | `components/tanklink_lora/include/tanklink_lora_proto.h` (shared) | same | — |
| Sign-in answer, LoRa tag, tank OTA token | `components/tanklink_lora/tanklink_crypto.c` (shared) | same | `authResponse` in `tanklink_app/lib/ble/protocol.dart` (covered by `test/auth_test.dart`) |
| Report body (`POST /v1/report`) | — | — | `tanklink_app/lib/diag/report_builder.dart` (`toJson`) ↔ `report_worker/src/index.js` |
| BLE payload layouts | `pump_node/main/gatt_payloads.c` (reads) and the handlers in `gatt_svr.c` (writes) | `tank_node/main/tank_gatt.c` | `tanklink_app/lib/ble/protocol.dart` (covered by `test/protocol_test.dart`) |
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
6. Release notes: a short `## Changes` list, then which pump / tank / app versions go with it. Call out wiring changes and anything that must be updated together.

## Time on the pump

The pump keeps **local** time (whatever the phone sends, not UTC) in `pump_clock.c`, anchored to the DS3231 (`pump_rtc.c`) at boot and re-read hourly. Only two things need wall-clock time: **fill schedules** and the **tank's last-seen time**, which `lora_link.c` saves to NVS per sensor (`tl_tank/last<N>`) so a restart knows the real age. Everything else (auto-off, pairing windows, button holds) uses time since boot on purpose.

A fill cut short by a power cut or restart is detected by `pump_runlog.c` (a "running" record in NVS that a normal stop deletes) and shown in the app as a notice. The pump never restarts a fill on its own after power returns; that is a deliberate safety choice. Without a DS3231, or with its "oscillator stopped" flag set, the pump has no time until the app syncs.

## Hardware gotchas

- ESP32-C3 GPIO18/19 are USB D−/D+. Don't put relays or buttons there.
- Strap pins (GPIO2, 8, 9) affect boot. The pump button is on GPIO9 in parallel with BOOT, which is fine because it is only pressed after boot.
- Pump relays (GPIO0/1) are active-low by default and set to idle first thing in `app_main` (`relay_control_early_safe()`), so the motor never clicks on during reset.
- Tank: 10 kΩ pull-ups on NSS/SCK/MOSI are required or the SX1278 draws ~2 mA in deep sleep. See `tank_node/README.md`.
- The first flash after a partition-table change must be over USB with `erase-flash`, which clears pairing.
- Firmware is signed. Builds need `keys/firmware_signing_key.pem` (gitignored, never commit it), and boards refuse BLE updates signed with another key. See `docs/firmware-build-setup.md#signing-key`.

## Testing reality

There is no hardware-in-the-loop setup. Firmware changes can be compile-checked, but behaviour needs real boards. Say so in your summary rather than claiming it was tested. For the app, `flutter analyze` and `flutter test` are the automated checks.

## Conventions

- Commit subjects are plain sentences: `Fix tank select ...`, `Pump 0.9.0: ...`, `TankLink app 1.0.9: ...` for version bumps.
- Don't commit `sdkconfig`, `build/`, `managed_components/`, `dependencies.lock`, `key.properties`, or keystores (all gitignored). Pin and feature defaults belong in `sdkconfig.defaults` and `Kconfig.projbuild`.
- A local `sdkconfig` overrides `sdkconfig.defaults`. After changing defaults, check the local `sdkconfig` picked them up (or delete it and rebuild).
- **No old-version handling.** The project is in development: don't add migrations of saved NVS data, fallbacks for older firmware or apps, or compatibility shims. A changed NVS layout fails its size/magic check and loads defaults; a changed BLE layout keeps the protocol version as is. Say in the release notes what has to be re-paired or set again.
- User-facing app text is short and plain. Help text that describes the button or wiring must match the firmware.
