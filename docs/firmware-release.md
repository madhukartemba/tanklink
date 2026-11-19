# Firmware releases

Android app sideload updates: [`app-release.md`](app-release.md) (`app-v*`).

## The release script

`scripts/release.sh` releases any of pump, tank and app in one command: it bumps the versions, commits, rebuilds, checks each binary contains its version and differs from the last release, checks the APK is signed with the upload key, pushes, and creates the GitHub releases.

```bash
mkdir -p /tmp/notes   # pump.md, tank.md, app.md for what you release
./scripts/release.sh --pump 0.14.0 --app 1.3.0 --notes /tmp/notes -m "Pump 0.14.0, TankLink app 1.3.0: ..."
```

Run with `--dry-run` first: it does every build and check, then restores the version files without committing or publishing. Needs a clean `main` in sync with `origin`. The manual steps below are what it automates.

## Pump (`pump-v*`)

1. Edit `TANKLINK_FW_MAJOR` / `_MINOR` / `_PATCH` in [`pump_node/main/tanklink_uuid.h`](../pump_node/main/tanklink_uuid.h). If the board changed, bump `PUMP_HW_REV` in `sdkconfig.defaults`. If the BLE protocol changed, bump `TANKLINK_PROTO_MAJOR` or `_MINOR` (see [`PROTOCOL.md`](PROTOCOL.md#versioning)).
2. Build with **ESP-IDF v6.1.0** (tag `v6.1`; see [`firmware-build-setup.md`](firmware-build-setup.md)):

```bash
. "$HOME/esp/esp-idf/export.sh"
cd pump_node
idf.py build
```

3. Create GitHub release tag **`pump-vX.Y.Z`** (example: `pump-v0.4.0`).

| File | Source |
| --- | --- |
| `pump_node.bin` | `pump_node/build/pump_node.bin` |
| `firmware-manifest.json` | `./scripts/make_pump_manifest.sh X.Y.Z` |

The script refuses a binary that doesn't contain `X.Y.Z`, and fills in the protocol major and board revision from the build:

```json
{
  "component": "pump_node",
  "version": "0.12.0",
  "sha256": "<sha256 hex of pump_node.bin>",
  "proto_major": 1,
  "hw_revs": [1]
}
```

The app only offers a release whose `proto_major` equals its own and whose `hw_revs` lists the connected board. To ship one binary for several board revisions, edit `hw_revs` by hand (for example `[1, 2]`) after checking it really runs on each.

## Tank (`tank-v*`)

1. Edit `TANK_FW_MAJOR` / `_MINOR` / `_PATCH` in [`tank_node/main/tank_version.h`](../tank_node/main/tank_version.h) (the version string is built from them). Bump `TANK_HW_REV` for a new board.
2. Build `tank_node`, then:

```bash
./scripts/make_tank_manifest.sh X.Y.Z
```

3. Create GitHub release tag **`tank-vX.Y.Z`** with assets `tank_node.bin` + `firmware-manifest.json` (`component: tank_node`).

### Tank BLE OTA notes

- First USB flash after dual-OTA partition change: `erase-flash` then flash (clears NVS).
- Re-pair the tank once so the BLE OTA token reaches the pump/app.
- Short-press the tank button to open a ~10 s BLE advertise window; the app scans for `TL-Tank-XXXX` / `tank_id` and pushes the image.
- From **0.2.4+**: deep sleep ~50 µA on BAT± (USB out); NimBLE only during OTA.
- From **0.2.5**: TX retries=5; unpaired = button-only sleep (no 10 min wake); **10 kΩ** on NSS+SCK+MOSI; battery divider **120 k/120 k**.
- From **0.2.6**: LED **D5** + DIO0 **D4** (swapped off MTCK); soft breathe during BLE OTA.
- From **0.2.7**: success/fail LED on every status TX again; short press during the BLE window sends LoRa again; hold still pairs.
- From **0.2.8**: wake on any float change (both edges); tank sends raw FULL/EMPTY pin levels; interpretation and empty-float on/off are decided by the pump (Settings → Empty float, pump 0.8.2+).
- From **0.2.9**: button and both float pins stay internally pulled up in deep sleep (IDF no longer installs a pull-down when a pin is armed to wake on HIGH), so opening a closed float can wake the chip.
- From **0.3.2**: a tap opens the BLE window even if the button is already up; pairing starts at 3 s without waiting for release, including during the BLE window. Error flashes are short with a long gap. Battery-sense failure is code 6 and is sent on LoRa.

## First flash after OTA partition change

Dual OTA layout requires a **USB** flash once (partition table + otadata + app). Later updates use BLE from the app.

```bash
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash
```

`erase-flash` clears NVS pairing — re-pair in the app afterward.
