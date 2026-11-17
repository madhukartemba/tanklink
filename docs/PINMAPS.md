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

SuperMini header pins: GPIO 0–10, 20, 21 — all 13 used.

| Function | GPIO | Notes |
| --- | --- | --- |
| Relay START (IN1) | 0 | Not a strap pin; floats at reset → relay off during boot |
| Relay STOP (IN2) | 1 | Same |
| I2C SCL (DS3231) | 6 | 100 kHz. Most modules have 4.7 kΩ pull-ups; the ESP32 internal pull-ups are on too |
| I2C SDA (DS3231) | 7 | Address 0x68. If it isn't found, the boot log scans the bus and says whether SDA/SCL look swapped |
| Button (single) | 9 | Active-low to GND, parallel with onboard BOOT. Holding at power-up = download mode |
| NeoPixel | 20 | |
| Buzzer | 21 | UART0 TX — may chirp during ROM boot log |

**Button:** running → press = OFF · off → hold ~1 s, release = ON · hold ~5 s = BLE pair · keep holding ~10 s more = factory reset.

**DS3231 battery:** many modules charge the coin cell through a resistor + diode. Use an LIR2032, or remove that resistor if you fit a plain CR2032.

**Don't use** GPIO18/19 (USB D−/D+, not on headers) or GPIO9 for relays (pulled HIGH at boot).

### Relay module (2-ch opto, active-low, JD-VCC)

| Module | Connect to |
| --- | --- |
| JD-VCC jumper | **Remove** (never bridge VCC–GND) |
| JD-VCC / GND (3-pin) | 5 V / GND (coil supply) |
| VCC (4-pin) | **3V3** |
| IN1 / IN2 | GPIO0 / GPIO1 (optional 10 kΩ → 3V3 each) |
| GND (4-pin) | C3 GND (omit for full isolation) |

Firmware: `CONFIG_PUMP_RELAY_ACTIVE_HIGH` **off** (IN LOW = relay ON).

Contacts: START relay **COM+NO** in parallel with starter Start button; STOP relay **COM+NC** in series with starter Stop button.

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
