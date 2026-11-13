# TankLink pin maps

Canonical GPIO maps for the two boards. Firmware defaults live in each node’s `sdkconfig.defaults`; keep those in sync when changing this file.

## Pump — ESP32-C3 SuperMini + RA-02

Firmware: `pump_node/` · defaults: `pump_node/sdkconfig.defaults`

LoRa SPI matches the **tank** layout (same ESP32-C3 + RA-02 rules).

### LoRa (RA-02 @ 433 MHz)

| RA-02 | GPIO | Notes |
| --- | --- | --- |
| SCK | 8 | **10 kΩ → 3V3** (onboard LED pin — pull-up required) |
| MOSI | 10 | **10 kΩ → 3V3** |
| MISO | 21 | **Never** GPIO 9 (download-mode trap) |
| NSS | 20 | **10 kΩ → 3V3** |
| RESET | 9 | idle high |
| DIO0 | 6 | not GPIO 8 (LED) |
| VCC | 3V3 | |
| GND | GND | |

### SuperMini (header GPIO)

| Function | GPIO | Notes |
| --- | --- | --- |
| Button (→ GND, active low) | **0** | Hold ~1 s: ON if idle / OFF if running; hold ~5 s: BLE pair; ~15 s total: factory reset |
| Buzzer (active high) | **1** | |
| DS3231 SDA | **2** | I²C |
| DS3231 SCL | **3** | I²C |
| Relay START | **4** | momentary pulse |
| Relay STOP | **5** | momentary pulse |
| NeoPixel (WS2812) | **7** | data |
| *(LoRa)* | 6, 8, 9, 10, 20, 21 | see above |

No second front-panel button. STOP is via hold on **GPIO 0** while the pump is on, or via app/LoRa auto rules.

GPIO **18 / 19** are USB D−/D+ — not on the SuperMini header.

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
| LoRa DIO0 | **D4** | **6** | RA-02 DIO0 (OK on MTCK; don’t put LED here) |
| Status LED | **D5** | **7** | → 1–2.2 kΩ → LED → GND |
| LoRa MISO | D6 | 21 | RA-02 MISO (**not** D9) |
| LoRa NSS/CS | D7 | 20 | RA-02 NSS + **10 kΩ → 3V3** |
| LoRa SCK | D8 | 8 | RA-02 SCK + **10 kΩ → 3V3** |
| LoRa RESET | D9 | 9 | RA-02 RESET |
| LoRa MOSI | D10 | 10 | RA-02 MOSI + **10 kΩ → 3V3** |

RA-02: VCC→3V3, GND→GND, U.FL antenna, **433 MHz**.

### Deep sleep (~50 µA on BAT±, USB unplugged)

- **10 kΩ → 3V3** on NSS, SCK, and MOSI (no digital `gpio_deep_sleep_hold` — that leaked ~mA on C3).
- Status LED on **D5**; DIO0 on **D4** (swapped) — GPIO6/MTCK ROM pull-up must not drive an LED.
- NimBLE only for BLE OTA; unpaired nodes use **button wake only** (no 10 min timer).
- Measure on **BAT±** with USB disconnected.
