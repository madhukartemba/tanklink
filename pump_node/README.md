# pump_node (ESP32-C3 SuperMini)

TankLink pump controller — **simple BLE GATT** (phone claim/pair + OnOff stub).

- Advertise as `TankLink-Pump`
- Unpaired: first Claim wins and stores owner token in NVS
- Paired: Auth with token, then PumpCmd 0/1 (relays not wired yet)
- LoRa / relays: stub only
- NeoPixel / button: off by default (bare board)

## Build / flash

```bash
. "$HOME/esp/esp-idf/export.sh"
cd /Users/madhukartemba/Desktop/tanklink/pump_node
idf.py fullclean
idf.py set-target esp32c3
idf.py build
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash monitor
```

`erase-flash` clears pairing (back to UNPAIRED).

## GATT (summary)

See `tanklink_uuid.h`. Service `7f1a0001-ac01-4c8c-9b2e-74616e6b6c6e`.
