# Pump node wiring (ESP32-C3 SuperMini)

Canonical copy (pump + tank): [`../docs/PINMAPS.md`](../docs/PINMAPS.md).

## LoRa-only bring-up

Wire **only** the RA-02 for the first link test. Everything else can stay unconnected; firmware soft-fails missing peripherals.

| RA-02 | ESP32-C3 GPIO |
| --- | --- |
| SCK | 10 |
| MOSI | 3 |
| MISO | 2 |
| NSS | 5 |
| RESET | 4 |
| DIO0 | 8 |
| VCC | 3V3 |
| GND | GND |

Match tank frequency **433 MHz**. Tank wiring: see [`../tank_node/WIRING.md`](../tank_node/WIRING.md).

## Full board (when ready)

| Function | GPIO |
| --- | --- |
| Relay START (IN1) | 0 |
| Relay STOP (IN2) | 1 |
| I2C SDA (DS3231) | 6 |
| I2C SCL (DS3231) | 7 |
| Button (single; running: press = OFF · off: hold ~1 s + release = ON · ~5 s = BLE pair) | 9 |
| NeoPixel | 20 |
| Buzzer | 21 |

Relay module (active-low opto): remove JD-VCC jumper, JD-VCC = 5 V, VCC = 3V3. See [`../docs/PINMAPS.md`](../docs/PINMAPS.md).
