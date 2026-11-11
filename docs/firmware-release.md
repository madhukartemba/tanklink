# Pump firmware releases

## Version bump

1. Edit `TANKLINK_FW_VERSION` in [`pump_node/main/tanklink_uuid.h`](../pump_node/main/tanklink_uuid.h) (semver `X.Y.Z`).
2. Build:

```bash
. "$HOME/esp/esp-idf/export.sh"
cd pump_node
idf.py build
```

3. Create GitHub release tag **`pump-vX.Y.Z`** (example: `pump-v0.4.0`).

## Required assets

| File | Source |
| --- | --- |
| `pump_node.bin` | `pump_node/build/pump_node.bin` |
| `firmware-manifest.json` | generated below |

### `firmware-manifest.json`

```json
{
  "component": "pump_node",
  "version": "0.4.0",
  "sha256": "<sha256 hex of pump_node.bin>",
  "min_app": "1.0.0"
}
```

Generate SHA on macOS:

```bash
shasum -a 256 pump_node/build/pump_node.bin
```

Helper:

```bash
./scripts/make_pump_manifest.sh 0.4.0
```

## First flash after OTA partition change

Dual OTA layout requires a **USB** flash once (partition table + otadata + app). Later updates use BLE from the app.

```bash
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash
```

`erase-flash` clears NVS pairing — re-pair in the app afterward.
