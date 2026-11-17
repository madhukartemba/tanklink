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

Flow: the tank wakes on a float change or a 10-minute heartbeat, sends a LoRa STATUS packet with raw float pin levels, and sleeps. The pump decides what those pins mean (full / almost-empty / second tank), drives the starter relays, and serves state to the app over BLE. The app is the only UI besides the single pump button.

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

## Shared contracts — change all copies together

These values are duplicated by hand. There is no codegen. If you change one, change the others in the same commit.

| Contract | Pump (C) | Tank (C) | App (Dart) |
| --- | --- | --- | --- |
| BLE UUIDs, Cmd opcodes, OTA opcodes/status, payload lengths | `pump_node/main/tanklink_uuid.h` | `tank_node/main/tanklink_ble_uuid.h` | `tanklink_app/lib/ble/tanklink_uuids.dart` |
| LoRa packet format | `components/tanklink_lora/include/tanklink_lora_proto.h` (shared) | same | — |
| BLE payload parsing | `pump_node/main/gatt_svr.c` | `tank_node/main/tank_gatt.c` | `tanklink_app/lib/ble/pump_session.dart` |

Compatibility rule: BLE payloads only grow at the end. Never reorder or resize existing fields. Older apps ignore extra bytes, and the pump accepts shorter Settings writes (see `PROTOCOL.md`). Bump `TANKLINK_LORA_VER` for any LoRa layout change, and say in the release notes that pump and tank must be updated together.

## Versions

| Component | Where | Tag |
| --- | --- | --- |
| Pump | `TANKLINK_FW_VERSION` in `pump_node/main/tanklink_uuid.h` | `pump-vX.Y.Z` |
| Tank | `TANK_FW_*` in `tank_node/main/tank_version.h` (all four defines) | `tank-vX.Y.Z` |
| App | `version: X.Y.Z+N` in `tanklink_app/pubspec.yaml`; `N` (Android versionCode) must go up every release | `app-vX.Y.Z` |

The app finds updates by listing GitHub releases and picking the **highest semver** per tag prefix, not the newest by date. It verifies the `sha256` in each release's manifest JSON before installing or flashing.

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
flutter test            # one smoke test; see the note below
flutter build apk --release
```

**Signing:** without `tanklink_app/android/key.properties`, Gradle signs release builds with the machine's debug key (`~/.android/debug.keystore`). Every `app-v*` release so far (through 1.0.9) was signed that way, with certificate SHA-256 `4eaeb0bf…afa381`. Android refuses an update signed by a different key, so a build from another machine, or a switch to a real upload key, makes existing installs uninstall first. Check before publishing:

```bash
apksigner verify --print-certs tanklink_app/build/app/outputs/flutter-apk/app-release.apk | grep SHA-256
```

`flutter test` currently fails offline: the smoke test pumps the full app, and the update checker's HTTP call gets a 400 in the test environment. The failure comes from that, not your change.

## Release checklist (agents have got this wrong before)

1. Bump the version in source and commit it.
2. **Rebuild.** Never upload whatever is already in `build/`. It may be an older build.
3. Run the manifest script (`scripts/make_*_manifest.sh X.Y.Z`) and **check the sha256 differs from the previous release's manifest.** If it matches, you are about to re-ship the old binary.
4. Check that the binary contains the new version: `strings pump_node/build/pump_node.bin | grep -x X.Y.Z`.
5. Push the commit, then `gh release create <tag> --target <full 40-char sha>` (a short SHA fails with *target_commitish is invalid*) with exactly the asset names the app expects:
   - pump: `pump_node.bin`, `firmware-manifest.json`
   - tank: `tank_node.bin`, `firmware-manifest.json`
   - app: `TankLink.apk`, `app-manifest.json`
6. Release notes: a short `## Changes` list, then which pump / tank / app versions go with it. Call out wiring changes and anything that must be updated together.

## Time on the pump

The pump keeps **local** time (whatever the phone sends, not UTC) in `pump_clock.c`, anchored to the DS3231 (`pump_rtc.c`) at boot and re-read hourly. Only two things need wall-clock time: **fill schedules** and the **tank's last-seen time**, which `lora_link.c` saves to NVS (`tl_tank/last`) so a restart knows the real age. Everything else (auto-off, pairing windows, button holds) uses time since boot on purpose.

A fill cut short by a power cut or restart is detected by `pump_runlog.c` (a "running" record in NVS that a normal stop deletes) and shown in the app as a notice. The pump never restarts a fill on its own after power returns; that is a deliberate safety choice. Without a DS3231, or with its "oscillator stopped" flag set, the pump has no time until the app syncs.

## Hardware gotchas

- ESP32-C3 GPIO18/19 are USB D−/D+. Don't put relays or buttons there.
- Strap pins (GPIO2, 8, 9) affect boot. The pump button is on GPIO9 in parallel with BOOT, which is fine because it is only pressed after boot.
- Pump relays (GPIO0/1) are active-low by default and set to idle first thing in `app_main` (`relay_control_early_safe()`), so the motor never clicks on during reset.
- Tank: 10 kΩ pull-ups on NSS/SCK/MOSI are required or the SX1278 draws ~2 mA in deep sleep. See `tank_node/README.md`.
- The first flash after a partition-table change must be over USB with `erase-flash`, which clears pairing.

## Testing reality

There is no hardware-in-the-loop setup. Firmware changes can be compile-checked, but behaviour needs real boards. Say so in your summary rather than claiming it was tested. For the app, `flutter analyze` and `flutter test` are the automated checks.

## Conventions

- Commit subjects are plain sentences: `Fix tank select ...`, `Pump 0.9.0: ...`, `TankLink app 1.0.9: ...` for version bumps.
- Don't commit `sdkconfig`, `build/`, `managed_components/`, `dependencies.lock`, `key.properties`, or keystores (all gitignored). Pin and feature defaults belong in `sdkconfig.defaults` and `Kconfig.projbuild`.
- A local `sdkconfig` overrides `sdkconfig.defaults`. After changing defaults, check the local `sdkconfig` picked them up (or delete it and rebuild).
- User-facing app text is short and plain. Help text that describes the button or wiring must match the firmware.
