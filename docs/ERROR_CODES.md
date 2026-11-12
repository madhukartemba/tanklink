# TankLink error codes

Human-readable codes used by the tank sensor LED and the phone app.

## Tank sensor LED codes

The status LED blinks the **error number** twice (smooth pulses), with a longer pause between the two groups.

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
| Boot | Soft fade in/out |
| Hold to pair | Brightness ramps 0→100 over ~3 s, then breathing flash in pairing mode |
| Pairing success | Two calm fade pulses |
| Short press (paired) | TX pulse, then success or code **3** |
| Short press (unpaired) | Code **1** |
| Cancel pairing | Code **4** |
| Pairing timeout | Code **5** |

Pairing mode lasts **60 s** by default (`CONFIG_TANK_PAIR_WINDOW_MS`). Press the button once to cancel.

## Pump / app (BLE)

These are not LED blink codes; they appear in the app when a BLE command fails.

| Situation | Typical message |
| --- | --- |
| Pump not in phone-pairing window | Claim rejected — hold Start+Stop 5 s |
| Not authenticated | Cmd rejected |
| Tank pair window / LoRa down | Tank pair failed |
| Unpair tank | Unpair tank failed |

## Related docs

- Pin maps: [`PINMAPS.md`](PINMAPS.md)
- Tank wiring: [`../tank_node/WIRING.md`](../tank_node/WIRING.md)
