# Tank node (Seeed XIAO ESP32-C3)

Solar-charged tank sensor: FULL + almost-empty floats, button, LED, battery ADC, RA-02 LoRa. A 5 V solar supply on VIN charges the LiPo through the XIAO's charger ([WIRING.md](WIRING.md#power-and-solar)).

See `main/tank_version.h`. Paired: deep sleep **5 min** heartbeat. Unpaired: button wake only. Short press (including a tap that is already released) → status + BLE OTA ~10 s. Hold 3 s → LoRa PAIR starts while the button is still held. Holding 3 s during the BLE window also starts pairing.

**Wiring:** [WIRING.md](WIRING.md) · [docs/PINMAPS.md](../docs/PINMAPS.md)

**Must-have:** 10 kΩ **NSS + SCK + MOSI → 3V3**; LED **D5** + DIO0 **D4** (swapped); **MISO on D6** (never D9); battery **120 k/120 k**.

**Sleep:** ~50 µA on BAT± (USB unplugged). BLE only for OTA; no digital-pin `gpio_deep_sleep_hold`.

## Build / flash

Requires **ESP-IDF v6.1.0** (tag `v6.1`). See [`docs/firmware-build-setup.md`](../docs/firmware-build-setup.md).

```bash
. "$HOME/esp/esp-idf/export.sh"
cd tank_node
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash
```

Hold **BOOT** + tap **RESET** if the port does not enter download mode.
