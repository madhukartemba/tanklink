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
| I2C SDA (DS3231) | 6 |
| I2C SCL (DS3231) | 7 |
| Start (hold ~1 s = ON; hold both ~5 s = BLE pair) | 0 |
| Stop (hold ~1 s = OFF / exit BLE pair) | 1 |
| Relay START | 18 |
| Relay STOP | 19 |
| NeoPixel | 20 |
| Buzzer | 21 |
| Relays: GPIO 18 (START) & GPIO 19 (STOP), active-low | |
