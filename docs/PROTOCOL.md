# TankLink protocols (BLE + LoRa)

Byte-level reference for the app ↔ pump BLE link, the app ↔ tank BLE OTA link, and the tank ↔ pump LoRa link. The C headers and handlers are the source of truth. This file just collects them in one place. If they disagree, trust the code and fix this file.

All multi-byte integers are **little-endian**. "Authed" means the connection has written the correct 16-byte token to **Auth** since connecting.

Source files: `pump_node/main/tanklink_uuid.h`, `pump_node/main/gatt_svr.c`, `tank_node/main/tanklink_ble_uuid.h`, `tank_node/main/tank_gatt.c`, `components/tanklink_lora/include/tanklink_lora_proto.h`, `tanklink_app/lib/ble/tanklink_uuids.dart`, `tanklink_app/lib/ble/pump_session.dart`.

## BLE UUIDs

All UUIDs are `7f1a00XX-ac01-4c8c-9b2e-74616e6b6c6e`.

| XX | Name | Pump | Tank |
| --- | --- | --- | --- |
| 01 | Service | ✓ | ✓ |
| 02 | Info | ✓ | ✓ |
| 03 | Pair | ✓ | |
| 04 | Auth | ✓ | ✓ |
| 05 | State | ✓ | |
| 06 | Cmd | ✓ | |
| 07 | Settings | ✓ | |
| 08 | OtaCtrl | ✓ | ✓ |
| 09 | OtaData | ✓ | ✓ |
| 0a | OtaStatus | ✓ | ✓ |
| 0b | Tank (status of the paired tank) | ✓ | |
| 0c | Schedule | ✓ | |
| 0d | Tanks (slot list) | ✓ | |

Advertised names: pump `TankLink-XXXX` (last 4 hex of MAC), tank `TL-Tank-XXXX`. The tank also puts its `tank_id` in manufacturer data under company ID `0xFFFF`.

## Pump characteristics

### Info (read, no auth)

`paired(1) device_id(6) fw_version(NUL-terminated string) auto_off_min(1) flags(1) run_secs(u32)`

`flags`: bit 0 = BLE pairing window open, bit 1 = this connection is authed.

### Pair (write + notify, no auth)

Write anything while the pairing window is open (hold the button ~5 s) to claim the pump. The pump makes a new 16-byte token, notifies it on this characteristic, and marks the connection authed. The app stores the token. A write outside the window is rejected with *write not permitted*.

### Auth (write)

Write the 16-byte token. Success marks the connection authed. A wrong token is rejected with *write not permitted*.

### State (read + notify)

`pump_on(1)`, 0 or 1.

### Cmd (write, authed)

Byte 0 is the opcode.

| Opcode | Meaning | Extra bytes |
| --- | --- | --- |
| `0x00` / `0x01` | Pump off / on | — |
| `0xA1` | Open LoRa tank-pair window (60 s default) | — |
| `0xA2` | Unpair tank | — |
| `0xA4` | Select active tank slot (rejected for a different slot while running) | `slot(1)` |
| `0xA5` | Rename tank slot | `slot(1) name(≤16, UTF-8)` |
| `0xB1` | Test beep | — |
| `0xE0` | Clear last error | — |
| `0xF0` | Unpair this phone (clears token) | — |
| `0xF1` | Factory reset | — |

Any other opcode is treated as on/off (non-zero = on). Maximum write length is 18 bytes.

### Settings (read no auth, write authed)

Read:

`auto_off_min(1) run_secs(u32) serial(4 chars + NUL) buzzer_flags(1) buzzer_tone(1) led_brightness(1) starter_type(1) relay_pulse_ms(u16) sensor_mode(1)`

Write: a prefix of `auto_off_min(1) buzzer_flags(1) buzzer_tone(1) led_brightness(1) starter_type(1) relay_pulse_ms(u16) sensor_mode(1)`. The pump applies whatever fields are present: length 1 sets auto-off only, ≥3 adds the buzzer, ≥4 LED, ≥5 starter, ≥7 pulse, ≥8 sensor mode.

- `buzzer_flags`: bit 0 enabled, bit 1 on button, bit 2 on pump start/stop, bit 3 on auto-off.
- `starter_type`: 0 = none (logical on/off only), 1 = two-button starter (Start/Stop momentary relays).
- `sensor_mode`: 0 = second float off, 1 = almost-empty float, 2 = two tanks (sensor 2 is a second tank's full float). Leaving mode 2 while running fails. Leaving mode 2 deletes slot 1 and any schedules pointing at it.

### Tank (read + notify)

35 bytes. Older apps read only the first 19.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | bound |
| 1 | 1 | LoRa pairing window open |
| 2 | 6 | tank_id (tank MAC) |
| 8 | 3 | tank fw major, minor, patch |
| 11 | 1 | flags (LoRa flags, see below) |
| 12 | 1 | battery % |
| 13 | 1 | online (bound and heard within the stale window) |
| 14 | 2 | seconds since last packet (`0xFFFF` = never) |
| 16 | 1 | RSSI dBm (int8) |
| 17 | 1 | SNR dB (int8) |
| 18 | 1 | pump last error code (see `ERROR_CODES.md`) |
| 19 | 16 | tank BLE OTA token (zeros if unknown) |

The app uses the token at offset 19 to authenticate to the tank directly for tank OTA.

### Schedule (read/write/notify, authed)

Read and notify: `clock_valid(1) hour(1) minute(1) count(1)` followed by `count` × `enabled(1) hour(1) minute(1) slot(1)`.

Write:

- `0x01 year(u16) month(1) day(1) hour(1) minute(1) second(1) weekday(1)`: 9 bytes (weekday is ignored). Sets the pump clock from the phone. The pump has no RTC, so the clock is lost on reboot until the app sets it again.
- `0x02 count(1)` followed by `count` × `enabled hour minute slot`: replaces the whole list. Maximum 4 entries.

### Tanks (read + notify, authed)

`mode(1) active_slot(1) raw_flags(1) count(1)` followed by `count` × `slot_index(1) sensor(1) name(16, NUL-padded)`.

`sensor`: 0 = the tank's sensor 1 pin, 1 = sensor 2 pin. `raw_flags` is the last LoRa flags byte.

### OTA (pump and tank)

The pump must be off and the connection authed.

- **OtaCtrl** (write): `0x01 size(u32) sha256(32)` start, `0x02` abort, `0x03` finish (verify hash, set boot partition, reboot).
- **OtaData** (write): `offset(u32) payload(…)`, at most 512 bytes total per write.
- **OtaStatus** (read + notify): `state(1) error(1) offset(u32)`.

| State | | Error | |
| --- | --- | --- | --- |
| 0 | idle | 0 | ok |
| 1 | ready | 1 | not authed |
| 2 | writing | 2 | pump is on |
| 3 | verify ok | 3 | bad parameter |
| 4 | rebooting | 4 | flash error |
| 5 | error | 5 | hash mismatch |
| | | 6 | wrong state |
| | | 7 | busy |

## Tank characteristics

The tank only runs BLE during a ~10 s window after a short button press, for OTA.

- **Info** (read): `paired(1)=1 tank_id(6) fw_version(NUL-terminated)`.
- **Auth** (write): the 16-byte tank token. The tank made this token and sent it to the pump in its LoRa PAIR packet. The app reads it from the pump's Tank characteristic.
- **OtaCtrl / OtaData / OtaStatus**: same as the pump.

## LoRa (tank ↔ pump)

433 MHz, SX1278. Packed struct `tanklink_lora_status_t`, 17 bytes:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | magic `'T' 'L'` (`0x54 0x4C`) |
| 2 | 1 | version (currently **4**; the pump accepts only `VER_MIN..VER`) |
| 3 | 1 | type: `0x01` STATUS, `0x02` PAIR, `0x03` ACK |
| 4 | 1 | flags |
| 5 | 1 | battery % |
| 6 | 2 | seq |
| 8 | 6 | tank_id (tank MAC) |
| 14 | 3 | fw major, minor, patch |

PAIR packets append the 16-byte tank BLE token, for 33 bytes total.

Flags: bit 0 = sensor 1 pin HIGH, bit 1 = sensor 2 pin HIGH, bit 2 = button, bit 3 = tank in pairing mode. Pins have internal pull-ups. The **pump** decides what a level means (full / empty / second tank), not the tank.

Exchange:

1. The tank sends STATUS (or PAIR when the button is held ~5 s).
2. The pump accepts PAIR only while its tank-pair window is open (Cmd `0xA1`). It accepts STATUS only from the bound `tank_id`.
3. The pump replies ACK with the same layout, `type = 0x03`, and the same `seq`. The tank retries up to 5 times without an ACK.
4. The pump ignores repeated `seq` values for state changes but still updates RSSI/SNR.
