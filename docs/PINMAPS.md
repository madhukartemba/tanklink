# TankLink pin maps

Canonical GPIO maps for the two boards. Firmware defaults live in each node’s `sdkconfig.defaults`; keep those in sync when changing this file.

## Pump — ESP32-C3 SuperMini + RA-02

Firmware: `pump_node/` · defaults: `pump_node/sdkconfig.defaults`

### LoRa (RA-02 @ 433 MHz)

| RA-02 | GPIO |
| --- | --- |
| SCK | 10 |
| MOSI | 3 |
| MISO | 2 |
| NSS | 5 |
| RESET | 4 |
| DIO0 | 8 |
| VCC | 3V3 |
| GND | GND |

### Other (optional; soft-fail if unwired)

| Function | GPIO |
| --- | --- |
| Start (hold ~1 s = ON; both ~5 s = BLE pair; keep both ~10 s more = factory reset) | 0 |
| Stop (hold ~1 s = OFF / exit BLE pair; dual-hold as above) | 1 |
| I2C SDA (DS3231) | 6 |
| I2C SCL (DS3231) | 7 |
| Relay START | 18 |
| Relay STOP | 19 |
| NeoPixel | 20 |
| Buzzer | 21 |

Relays default to unassigned (`-1`) until wired.

---

## Tank — Seeed XIAO ESP32-C3 + RA-02

Firmware: `tank_node/` · defaults: `tank_node/sdkconfig.defaults`

Fail-safe floats: **pull-up**, common to **GND**, contact **opens** when asserted (disconnected wire = safe default).

| Function | XIAO | GPIO |
| --- | --- | --- |
| Battery ADC | D0 | 2 |
| Button (short = TX, hold ≈3 s = pair) | D1 | 3 |
| Float FULL (HIGH = full / disconnect) | D2 | 4 |
| Float ALMOST EMPTY (optional; enable in Kconfig) | D3 | 5 |
| Status LED | D4 | 6 |
| LoRa DIO0 | D5 | 7 |
| LoRa SCK | D8 | 8 |
| LoRa RESET | D9 | 9 |
| LoRa MOSI | D10 | 10 |
| LoRa NSS/CS | D7 | 20 |
| LoRa MISO | D6 | 21 |

RA-02: **VCC → 3V3**, GND → GND, antenna on module U.FL. Frequency **433 MHz** (must match pump).

**Status LED:** D4 → **1–2.2 kΩ** → LED anode, cathode → GND (active-high). Firmware drives the pin low ASAP on wake and holds it low in deep sleep. A brief ROM-boot glimmer on D4/GPIO6 (MTCK) can still happen before the app runs; wiring the LED active-low (anode→3V3, cathode→GPIO via resistor) removes that if it bothers you.

**Battery:** BAT+ → **100 kΩ** → D0 → **100 kΩ** → GND, **100 nF** D0–GND.

**Boot note:** GPIO9 is the download strap — do **not** put LoRa MISO on D9. RESET on D9 is fine (idle high).

**Pairing:** In the app, open pump settings → **Pair tank sensor**, then hold the tank button ~3 s. First PAIR packet auto-binds (one tank per pump).
