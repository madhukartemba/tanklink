# TankLink

Local rooftop **tank ↔ pump** control — no cloud required.

- **Phone ↔ pump:** BLE (claim/pair, On/Off, settings)
- **Tank ↔ pump:** LoRa (RA-02 / SX1278) — planned for float/level events
- **Hardware:** ESP32-C3 (pump + tank), Flutter app

| Folder | Role |
| --- | --- |
| [`pump_node/`](pump_node/) | ESP32-C3 pump controller (BLE GATT, relays stub, LoRa stub) |
| [`tank_node/`](tank_node/) | ESP32-C3 tank sensor (placeholder) |
| [`tanklink_app/`](tanklink_app/) | Flutter app — multi-pump, slide-to-start, settings |

## Quick start

### Firmware (ESP-IDF)

```bash
. "$HOME/esp/esp-idf/export.sh"
cd pump_node
idf.py set-target esp32c3
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

Hold the board button ~5 s to enter pairing. Advertise name is `TankLink-XXXX` (MAC suffix).

`idf.py erase-flash` clears NVS pairing.

See [`pump_node/README.md`](pump_node/README.md) for GATT notes.

### App (Flutter)

```bash
cd tanklink_app
flutter pub get
flutter run
```

## Firmware updates (BLE OTA)

Pump firmware can be updated from the app over BLE (dual OTA partitions).

1. Bump `TANKLINK_FW_VERSION` and build `pump_node`
2. Publish a GitHub release tagged `pump-vX.Y.Z` with `pump_node.bin` + `firmware-manifest.json`
3. See [`docs/firmware-release.md`](docs/firmware-release.md) and `./scripts/make_pump_manifest.sh`

First flash after the OTA partition change must be over **USB**. Later updates use the app.

## Status (high level)

- [x] BLE claim / auth / multi-pump
- [x] Pump On/Off + auto-off + buzzer settings
- [x] NeoPixel status + slide-to-start UI
- [x] BLE OTA + GitHub Releases check
- [ ] Relay wiring / starter control
- [ ] Tank floats + RA-02 LoRa link
- [ ] Optional DS3231 schedules on pump
- [ ] Tank solar (small panel + CN3065 + LiPo)

## License

Private / personal use unless otherwise noted.
