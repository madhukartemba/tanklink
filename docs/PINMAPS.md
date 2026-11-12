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

Firmware: `tank_node/` · `sdkconfig.defaults` · `tank_boot_pins.h`

### C3 + RA-02 rules (Seeed / community)

| Rule | Why |
| --- | --- |
| **Never put LoRa MISO on D9** | SX1278 pulls MISO low at power-up → forces download boot |
| **SCK on D8 is OK** | Default XIAO SPI; add **10 kΩ SCK→3V3** so GPIO8 straps HIGH |
| **RESET on D9 is OK** | Idle-high (normal boot); hold **BOOT** to flash |
| **10 kΩ NSS→3V3** | Required — keeps radio deselected at boot and in deep sleep |

### Pin table

| Function | XIAO | GPIO | Wiring |
| --- | --- | --- | --- |
| Battery ADC | D0 | 2 | BAT+ → **120 k** → D0 → **120 k** → GND; 100 nF |
| Button | D1 | 3 | To GND, active low |
| Float FULL | D2 | 4 | To GND; opens when full |
| Float ALMOST EMPTY | D3 | 5 | To GND; opens when almost empty |
| Status LED | D4 | 6 | → 1–2.2 kΩ → LED → GND + **10 kΩ D4→GND** |
| LoRa DIO0 | D5 | 7 | RA-02 DIO0 (optional; IRQ also polled over SPI) |
| LoRa MISO | D6 | 21 | RA-02 MISO (**not** D9) |
| LoRa NSS/CS | D7 | 20 | RA-02 NSS + **10 kΩ → 3V3** |
| LoRa SCK | D8 | 8 | RA-02 SCK + **10 kΩ → 3V3** |
| LoRa RESET | D9 | 9 | RA-02 RESET |
| LoRa MOSI | D10 | 10 | RA-02 MOSI + **10 kΩ → 3V3** |

RA-02: VCC→3V3, GND→GND, U.FL antenna, **433 MHz**.

### Deep sleep (~50 µA on BAT±, USB unplugged)

- **10 kΩ → 3V3** on NSS, SCK, and MOSI (no digital `gpio_deep_sleep_hold` — that leaked ~mA on C3).
- **10 kΩ D4→GND** kills GPIO6/MTCK boot glimmer (ROM JTAG pull-up).
- NimBLE only for BLE OTA; unpaired nodes use **button wake only** (no 10 min timer).
- Measure on **BAT±** with USB disconnected.
