# Tank node wiring (Seeed XIAO ESP32-C3 + RA-02)

Fail-safe floats: **pull-up**, common to **GND**, contact **opens** when asserted so a disconnected wire reads the safe default.

| Function | XIAO | GPIO | Wiring |
| --- | --- | --- | --- |
| Battery ADC | D0 | 2 | Divider from BAT+ (e.g. 100k/100k) → D0, 100 nF to GND |
| Button | D1 | 3 | To GND; internal pull-up; press = LOW (wake) |
| Float FULL | D2 | 4 | To GND; **opens when full** → HIGH = full / disconnect |
| Float ALMOST EMPTY | D3 | 5 | To GND; **opens when empty** → HIGH = empty / disconnect |
| Status LED | D4 | 6 | D4 → 1–2.2 kΩ → LED → GND |
| LoRa DIO0 | D5 | 7 | RA-02 DIO0 |
| LoRa RESET | D6 | 21 | RA-02 RESET |
| LoRa NSS/CS | D7 | 20 | RA-02 NSS |
| LoRa SCK | D8 | 8 | RA-02 SCK |
| LoRa MISO | D9 | 9 | RA-02 MISO |
| LoRa MOSI | D10 | 10 | RA-02 MOSI |

RA-02: **VCC → 3V3**, GND → GND, antenna on module U.FL.

### Float orientation

- Mid-tank: both floats **closed** → both pins **LOW**
- Full: full float **open** → D2 **HIGH** (disconnect also looks full → stop fill)
- Almost empty: empty float **open** → D3 **HIGH** (disconnect also looks empty)

### Button

- Short press: wake → status TX → wait for pump ACK (retries) → sleep  
- Hold ~3 s: pairing restart TX + ACK retries → sleep  

Until the pump answers ACKs, the tank will show the **failure** LED pattern (5 fast blinks) after retries, then still sleep.
