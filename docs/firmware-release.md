# Firmware releases

## Pump (`pump-v*`)

1. Edit `TANKLINK_FW_VERSION` in [`pump_node/main/tanklink_uuid.h`](../pump_node/main/tanklink_uuid.h) (semver `X.Y.Z`).
2. Build:

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

```json
{
  "component": "pump_node",
  "version": "0.4.0",
  "sha256": "<sha256 hex of pump_node.bin>",
  "min_app": "1.0.0"
}
```

## Tank (`tank-v*`)

1. Edit `TANK_FW_*` in [`tank_node/main/tank_version.h`](../tank_node/main/tank_version.h).
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

## First flash after OTA partition change

Dual OTA layout requires a **USB** flash once (partition table + otadata + app). Later updates use BLE from the app.

```bash
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash
```

`erase-flash` clears NVS pairing — re-pair in the app afterward.
