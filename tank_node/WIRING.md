# Tank node wiring (Seeed XIAO ESP32-C3 + RA-02)

Full notes: [`../docs/PINMAPS.md`](../docs/PINMAPS.md).

| Function | XIAO | GPIO | Wiring |
| --- | --- | --- | --- |
| Battery ADC | D0 | 2 | BAT+ → **120 k** → D0 → **120 k** → GND; 100 nF |
| Button | D1 | 3 | To GND; press = LOW |
| Float FULL | D2 | 4 | To GND; opens when full |
| Float ALMOST EMPTY | D3 | 5 | To GND; opens when almost empty |
| Status LED | D4 | 6 | → 1–2.2 kΩ → LED → GND; **10 kΩ D4→GND** kills boot glimmer |
| LoRa DIO0 | D5 | 7 | RA-02 DIO0 |
| LoRa MISO | D6 | 21 | RA-02 MISO — **never D9** |
| LoRa NSS/CS | D7 | 20 | RA-02 NSS + **10 kΩ → 3V3** |
| LoRa SCK | D8 | 8 | RA-02 SCK + **10 kΩ → 3V3** |
| LoRa RESET | D9 | 9 | RA-02 RESET |
| LoRa MOSI | D10 | 10 | RA-02 MOSI + **10 kΩ → 3V3** |

RA-02: VCC→3V3, GND→GND, antenna on U.FL.

### Required pull-ups / LED pulldown

For ~50 µA sleep and clean boot:

1. **NSS (D7) → 10 kΩ → 3V3**  
2. **SCK (D8) → 10 kΩ → 3V3**  
3. **MOSI (D10) → 10 kΩ → 3V3**  
4. **LED (D4) → 10 kΩ → GND** (fights GPIO6/MTCK ROM pull-up)

### Deep sleep

Expect ~**50 µA** on BAT± with USB unplugged. External NSS/SCK pull-ups are required; firmware does not use digital GPIO hold (leaks ~mA on C3).

### Flash

Hold **BOOT**, tap **RESET**, keep holding **BOOT** until flash starts (D9 is shared with BOOT/RESET net idle-high).
