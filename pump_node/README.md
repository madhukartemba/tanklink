# pump_node (ESP32-C3 SuperMini)

TankLink pump controller — BLE GATT claim/pair, OnOff, settings, **BLE OTA**.

- Advertise as `TankLink-XXXX` (MAC serial)
- Unpaired: Claim while pairing window open (5s button hold)
- Paired: Auth with token, then Cmd / Settings / OTA
- Dual OTA partitions (`partitions_ota.csv`) — first install via USB
- LoRa / relays: stub

## Build / flash

```bash
. "$HOME/esp/esp-idf/export.sh"
cd pump_node
idf.py set-target esp32c3
idf.py build
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash monitor
```

`erase-flash` clears pairing (back to UNPAIRED). Flash size **4MB**.

Release assets: see [`docs/firmware-release.md`](../docs/firmware-release.md).

## GATT (summary)

See `tanklink_uuid.h`. Service `7f1a0001-ac01-4c8c-9b2e-74616e6b6c6e`.

OTA: `0008` CTRL, `0009` DATA, `000a` STATUS (auth required; pump must be OFF).
