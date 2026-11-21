# pump_node (ESP32-C3 SuperMini)

TankLink pump controller — BLE GATT claim/pair, OnOff, settings, **BLE OTA**.

- Advertise as `TankLink-XXXX` (MAC serial)
- Unpaired: Claim while BLE pairing window open (hold the button ~5 s)
- Paired: Auth with token, then Cmd / Settings / OTA
- Dual OTA partitions (`partitions_ota.csv`) — first install via USB
- LoRa RX done; relays configurable

## Build / flash

Requires **ESP-IDF v6.1.0** (tag `v6.1`). See [`docs/firmware-build-setup.md`](../docs/firmware-build-setup.md).

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

## Wi-Fi (optional)

No wiring change. The pump can join a 2.4 GHz home network, set up from the app over Bluetooth (Settings → Wi-Fi). Without a saved network, Wi-Fi never starts and the pump behaves as before. With it, the app controls the pump over Wi-Fi when it can, the pump sets its clock over SNTP, and it can download its own firmware updates. See `docs/plan-local-wifi.md` and `docs/PROTOCOL.md` ("Wifi" and "Wi-Fi transport").
