# Tank node (Seeed XIAO ESP32-C3)

Battery-powered tank sensor: two fail-safe floats, button, LED, battery ADC, RA-02 LoRa.

Firmware `0.2.0`. Deep sleep with **10 min** heartbeat, wake on float change / button.
Short press: status TX, then **BLE OTA advertise ~10 s**. Hold **~5 s** to send LoRa PAIR (includes BLE token).

See [WIRING.md](WIRING.md) for the pin map.

## Behaviour

- **Deep sleep** most of the time (floats, button, and timer can wake).
- **Heartbeat:** timer wake every `CONFIG_TANK_HEARTBEAT_SEC` (default 300 s) → status TX so the pump knows the tank is alive.
- **State change:** float level change → status TX.
- **ACK:** after each TX the tank listens for a pump ACK (same `seq`). Retries `CONFIG_TANK_TX_RETRIES` times (default 3), then sleeps.
- **Button short press:** wake → status TX (with button flag) + ACK wait.
- **Button hold (~3 s):** clear local pairing state, pairing LED pattern, send LoRa **pair** with ACK retries, then sleep. Pump-side ACK/pairing RX comes later.

### LED patterns

| Event | Pattern |
| --- | --- |
| Boot | Soft fade pulses |
| Status TX success (after ACK) | One soft pulse |
| No ACK after retries | Error code **3** long hard blinks (twice) |
| Pairing | Soft breathing, then success pulse or error codes 4/5 |

Float polarity: **HIGH = asserted** (full or empty). Open/disconnect matches the safe default. The almost-empty float is **optional** and disabled by default (`CONFIG_TANK_ENABLE_EMPTY_FLOAT`); enable it only when wired.

## Build / flash

```bash
. "$HOME/esp/esp-idf/export.sh"
cd tank_node
idf.py set-target esp32c3
idf.py build
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

XIAO: hold BOOT while resetting if the port does not appear after deep sleep.
