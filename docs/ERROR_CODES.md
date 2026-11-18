# TankLink error codes

Human-readable codes used by the tank sensor LED, pump NeoPixel, and the phone app.

## Tank sensor LED codes

The status LED shows the **error number** as **long hard blinks** (on/off, not soft pulses), twice, with a longer pause between the two groups. Soft fade pulses are used for boot, **one** success pulse after a full TX+ACK, and pairing — not for error codes. Per-retry TX pulses are not used.

| Code | Name | When |
| --- | --- | --- |
| **1** | Not paired | Short button press while this tank is not paired to a pump. Hold ~3 s with the pump’s “Pair tank sensor” window open to pair. |
| **2** | LoRa missing | Radio did not initialize (wiring / power / module). |
| **3** | No ACK | Paired, but the pump did not acknowledge a status TX (out of range, pump off, or wrong bind). |
| **4** | Pairing cancelled | Pairing mode was cancelled with a short button press. |
| **5** | Pairing timed out | Hold-to-pair window expired without a successful pump ACK. |

### Button / LED behaviour (tank)

| Action | LED |
| --- | --- |
| Boot | Soft fade pulses |
| Hold to pair | Brightness ramps 0→100 over ~5 s, then soft breathing pulses (~30 s window) |
| Pairing success | Soft success pulse |
| Short press (paired) | One short blink (BLE OTA listen ~10 s); after TX+ACK: **one** soft success pulse; on failure code **3**. Another short press during the window sends LoRa again; hold still enters pairing |
| Heartbeat / float / boot TX (paired) | After full TX+ACK: **one** soft success pulse; on failure code **3** |
| Short press (unpaired) | Code **1** long blinks |
| Cancel pairing | Code **4** long blinks |
| Pairing timeout | Code **5** long blinks |

Pairing mode lasts **30 s** by default (`CONFIG_TANK_PAIR_WINDOW_MS`). Press the button once to cancel.

## Pump NeoPixel codes

Same blink pattern as the tank: **N long hard red blinks**, pause, repeat twice. Soft animations (idle glow, pump-on wave, blue/amber pairing) are unrelated to these codes. The last code is also shown in the app on the home screen.

| Code | Name | When |
| --- | --- | --- |
| **1** | Tank full | Start denied because the selected tank reports full (or a full packet for it while running forces stop). Other tanks being full never blocks or stops the pump. |
| **2** | LoRa missing | RA-02 did not initialize at boot — tank link offline until fixed. |
| **3** | Tank offline | The selected tank's sensor missed its heartbeat window (out of range / power). Cleared when a packet returns or another tank is selected. |
| **4** | Blocked | Start denied during OTA or while BLE pairing lockout is active. |
| **5** | Not paired | Local Start held while the pump has no phone owner token. |

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
| Pump not in phone-pairing window | Claim rejected — hold the pump button 5 s |
| Not authenticated | Cmd rejected |
| Tank pair window / LoRa down | Tank pair failed |
| Unpair tank | Unpair tank failed |
| Tank full (start) | NeoPixel / home banner code **1** |

## Related docs

- Pin maps: [`PINMAPS.md`](PINMAPS.md)
- Tank wiring: [`../tank_node/WIRING.md`](../tank_node/WIRING.md)
