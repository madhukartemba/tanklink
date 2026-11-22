# Tank node (Seeed XIAO ESP32-C3)

Solar-charged tank sensor: FULL + almost-empty floats, button, LED, battery ADC, RA-02 LoRa. A 5 V solar supply on VIN charges the LiPo through the XIAO's charger ([WIRING.md](WIRING.md#power-and-solar)).

See `main/tank_version.h`. Paired: deep sleep **5 min** heartbeat. Unpaired: button wake, plus a timer wake once a day. Short press (including a tap that is already released) → status + BLE OTA ~10 s. Hold 3 s → LoRa PAIR starts while the button is still held. Holding 3 s during the BLE window also starts pairing.

**Wiring:** [WIRING.md](WIRING.md) · [docs/PINMAPS.md](../docs/PINMAPS.md)

**Must-have:** 10 kΩ **NSS + SCK + MOSI → 3V3**; LED **D5** + DIO0 **D4** (swapped); **MISO on D6** (never D9); battery **120 k/120 k**.

**Always back to sleep, no reset needed.** The tank sits sealed in its enclosure, so only its own button can be pressed. Every wake ends in deep sleep, and every sleep has a timer wake, so no state leaves it asleep (or awake) for good:

- **Button down when it goes to sleep** (held, or stuck): it is not armed as a wake source (it would wake the tank at once), and while it stays down it is not read as a press, so a float or timer wake can't take it for a hold and start pairing. Once released it works again; unpaired, the tank checks every 15 minutes while the button is down.
- **Unpaired, or the saved pairing unreadable:** button wake plus a daily timer wake.
- **A float that keeps flapping:** after 12 float wakes in 10 minutes, floats stop waking the tank until that window has passed; the 5-minute heartbeat still reports them.
- **Crash, hang or brownout:** the next start sleeps one heartbeat with the radio off, then tries again. Each one in a row doubles that sleep (up to 16 heartbeats, 80 minutes), so a fault that repeats can't keep it awake. A normal wake clears it. The count lives in RTC memory, so it survives deep sleep and restarts.
- **A hang:** a wake still running after 10 minutes restarts (the longest real wake, an update, takes about 3), and counts as trouble above.
- **No light for unattended sends:** a heartbeat or float change the pump didn't answer doesn't blink its error code (that kept the tank awake ~8 s). Codes show after a button press.

**Sleep:** ~50 µA on BAT± (USB unplugged). BLE only for OTA; no digital-pin `gpio_deep_sleep_hold`.

## Build / flash

Requires **ESP-IDF v6.1.0** (tag `v6.1`). See [`docs/firmware-build-setup.md`](../docs/firmware-build-setup.md).

```bash
. "$HOME/esp/esp-idf/export.sh"
cd tank_node
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash
```

Hold **BOOT** + tap **RESET** if the port does not enter download mode.
