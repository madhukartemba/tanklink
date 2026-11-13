# Pump node wiring (ESP32-C3 SuperMini)

Canonical copy (pump + tank): [`../docs/PINMAPS.md`](../docs/PINMAPS.md).

## LoRa (RA-02) — same GPIO plan as tank node

Add **10 kΩ from NSS, SCK, and MOSI to 3V3** on the pump board (SuperMini GPIO8 is also the onboard LED).

| RA-02 | ESP32-C3 GPIO |
| --- | --- |
| SCK | 8 |
| MOSI | 10 |
| MISO | 21 |
| NSS | 20 |
| RESET | 9 |
| DIO0 | 6 |
| VCC | 3V3 |
| GND | GND |

Match tank frequency **433 MHz**. Tank silkscreen names: [`../tank_node/WIRING.md`](../tank_node/WIRING.md).

## Full SuperMini header

| Function | GPIO |
| --- | --- |
| Button (one wire to GND) | 0 |
| Buzzer (+) — active HIGH | 1 |
| DS3231 SDA | 2 |
| DS3231 SCL | 3 |
| Relay START coil driver | 4 |
| Relay STOP coil driver | 5 |
| NeoPixel DIN | 7 |

### Button (GPIO 0 only)

- **~1 s hold** → pump ON if off, OFF if on (plus starter relay pulse when wired).
- **~5 s hold** → BLE phone pairing (keep holding).
- **~15 s total** → factory reset (keep holding after pairing cue).

There is no separate STOP button; use a long hold while running or the app.

Everything except LoRa soft-fails when unwired (bring up the radio first if you like).
