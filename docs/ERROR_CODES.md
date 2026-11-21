# TankLink error codes

Human-readable codes used by the tank sensor LED, pump NeoPixel, and the phone app.

## Tank sensor LED codes

The status LED shows the **error number** as **short flashes** with a long dark gap between them, twice. A longer dark gap separates the two counts, so you can count the flashes. Soft fade pulses are used for boot, **one** success pulse after a full TX+ACK, and pairing — not for error codes. Per-retry TX pulses are not used.

| Code | Name | When |
| --- | --- | --- |
| **1** | Not paired | Short button press while this tank is not paired to a pump. Hold 3 s with the pump’s “Pair tank sensor” window open to pair. |
| **2** | LoRa missing | Radio did not initialize (wiring / power / module). |
| **3** | No ACK | Paired, but the pump did not acknowledge a status TX (out of range, pump off, or wrong bind). |
| **4** | Pairing cancelled | Pairing mode was cancelled with a short button press. |
| **5** | Pairing timed out | Hold-to-pair window expired without a successful pump ACK. |
| **6** | Battery sense | The battery ADC did not start. The code is sent to the pump on later packets and shown in the app. |
| **7** | Update failed | A firmware update over BLE stopped or was refused (lost link, wrong hash or signature, or no progress for 20 s). Shown once the update window closes. The tank keeps its old firmware. |

### Button / LED behaviour (tank)

| Action | LED |
| --- | --- |
| Boot | Soft fade pulses |
| Hold to pair | Dark for the first 0.6 s (a normal press shows no light), then brightness ramps to full at 3 s. Pairing starts at 3 s, while the button is still held, then a slow, smooth breathe (about 2.4 s per breath) for the ~30 s window |
| Pairing success | Soft success pulse |
| Short press (paired) | No light while the tank listens for an update over BLE (~10 s), including a tap that is already released when the chip wakes. After TX+ACK: **one** soft success pulse; on failure code **3**. Another short press during the window sends LoRa again. Holding 3 s during the window starts pairing without waiting for release |
| Heartbeat / float / boot TX (paired) | After full TX+ACK: **one** soft success pulse; on failure code **3** |
| Short press (unpaired) | Code **1** long blinks |
| Cancel pairing | Code **4** long blinks |
| Pairing timeout | Code **5** long blinks |

Pairing mode lasts **30 s** by default (`CONFIG_TANK_PAIR_WINDOW_MS`). Press the button once to cancel.

## Pump NeoPixel codes

Same flash pattern as the tank: **N short red flashes**, a long pause, then the same count again. Soft animations (idle glow, pump-on wave, blue pairing sweep, OTA fill with a running light; the standby glow pulses once on activity) are unrelated to these codes. The last code is also shown in the app on the home screen. A tank sensor's own code is a second banner.

| Code | Name | When |
| --- | --- | --- |
| **1** | Tank full | Start denied because the selected tank reports full (or a full packet for it while running forces stop). Other tanks being full never blocks or stops the pump. |
| **2** | LoRa missing | RA-02 did not initialize at boot — tank link offline until fixed. |
| **3** | Tank offline | The selected tank's sensor missed its heartbeat window (out of range / power). Cleared when a packet returns or another tank is selected. |
| **4** | Blocked | Start denied while the BLE pairing lockout is active. (A start during a firmware update is not an error: the update light stays on and the press is just ignored.) |
| **5** | Not paired | Local Start held while the pump has no phone owner token. |
| **6** | I2C failed | The I2C bus for the DS3231 did not start. |
| **7** | Clock chip missing | The I2C bus started, but the DS3231 did not answer. |
| **8** | Clock lost power | The DS3231 oscillator-stopped flag is set: its CR2032 coin cell is flat or missing. The code clears when the phone sets the time, but the pump keeps reporting "clock lost power since start" (Tank status byte 54), so the app shows a *Clock battery flat* banner until the pump next starts with a good clock. |
| **9** | Clock chip not answering | A later read or write of the DS3231 failed. |

### Factory reset (not an error code)

Hold the pump **button** for BLE pairing (~5 s, blue progress), then **keep holding** (~10 s more, red progress). On completion the strip flashes green and the pump reboots with pairing, tank bind, and settings cleared. From the app: Settings → Factory reset → type `RESET`.

## Interrupted fill (app notice, not an error code)

If the pump loses power, browns out, or restarts **while running**, it does **not** start again by itself (it pulses Stop at boot). Instead it saves a notice that the app shows on the home screen until you dismiss it:

| Notice | Cause |
| --- | --- |
| Fill stopped by a power cut | Supply went away (power-on reset) |
| Fill stopped by a power dip | Supply dropped below the brownout level, e.g. when the motor started on a shared supply |
| Fill stopped by a pump restart | Crash, watchdog or software reset |

It shows how long the pump ran, about when it stopped, and when power came back. A normal stop (app, button, tank full, auto-off) never creates one.

## Almost-empty float (optional)

The almost-empty float is **optional**. The tank always sends both pin levels. Settings → Empty float is stored on the pump: off ignores the empty pin; on treats both pins high as full and the empty pin low as almost empty. Full still stops the pump.

## Pump / app (BLE)

These are not LED blink codes; they appear in the app when a BLE command fails.

| Situation | Typical message |
| --- | --- |
| Pump not in phone-pairing window | Add pump shows how to turn on pairing mode and waits for it |
| Not authenticated | Cmd rejected |
| Tank pair window / LoRa down | Tank pair failed |
| Unpair tank | Unpair tank failed |
| Tank full (start) | NeoPixel / home banner code **1** |

## Related docs

- Pin maps: [`PINMAPS.md`](PINMAPS.md)
- Tank wiring: [`../tank_node/WIRING.md`](../tank_node/WIRING.md)
