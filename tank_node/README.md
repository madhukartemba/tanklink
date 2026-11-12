# Tank node (Seeed XIAO ESP32-C3)

Battery-powered tank sensor: FULL + almost-empty floats, button, LED, battery ADC, RA-02 LoRa.

See `main/tank_version.h`. Deep sleep **10 min** heartbeat. Short press → status + BLE OTA ~10 s. Hold ~5 s → LoRa PAIR.

**Wiring:** [WIRING.md](WIRING.md) · [docs/PINMAPS.md](../docs/PINMAPS.md)

**Must-have:** 10 kΩ on **NSS** and **SCK** to 3V3. **MISO on D6 only** (never D9).

**Sleep:** ~50 µA on BAT± (USB unplugged). BLE only for OTA; no digital-pin `gpio_deep_sleep_hold`.

## Build / flash

```bash
. "$HOME/esp/esp-idf/export.sh"
cd tank_node
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash
```

Hold **BOOT** + tap **RESET** if the port does not enter download mode.
