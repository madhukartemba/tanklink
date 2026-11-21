# TankLink protocols (BLE + LoRa)

Byte-level reference for the app ↔ pump BLE link, the app ↔ tank BLE OTA link, and the tank ↔ pump LoRa link. The C headers and handlers are the source of truth. This file just collects them in one place. If they disagree, trust the code and fix this file.

All multi-byte integers are **little-endian**. "Authed" means the connection has answered the **Auth** challenge with a valid phone token since connecting (or claimed the pump on this connection). Only Info, State, OtaStatus and the Pair/Auth writes work without it. Notifications of authed characteristics only go to authed connections.

Source files: `pump_node/main/tanklink_uuid.h`, `pump_node/main/gatt_payloads.c`, `pump_node/main/gatt_svr.c`, `tank_node/main/tanklink_ble_uuid.h`, `tank_node/main/tank_gatt.c`, `components/tanklink_lora/include/tanklink_lora_proto.h`, `tanklink_app/lib/ble/tanklink_uuids.dart`, `tanklink_app/lib/ble/protocol.dart`.

## Versioning

Every link carries a protocol version, and every board reports its hardware revision. The goal is that any app can always identify and update any board, and that additions never need both sides updated at once.

| | Where | Current |
| --- | --- | --- |
| BLE protocol (app ↔ pump, app ↔ tank) | `TANKLINK_PROTO_MAJOR` / `_MINOR` in both BLE headers, `TankLinkUuids.protoMajor` in the app | pump 1.3 |
| LoRa protocol (tank ↔ pump) | `TANKLINK_LORA_VER` | 5 |
| Pump board revision | Kconfig `PUMP_HW_REV` | 1 |
| Tank board revision | Kconfig `TANK_HW_REV` | 1 |

**Minor change** (add a field, opcode or characteristic): append new fields at the end of a payload and bump the minor. Readers take the fields they know and ignore extra bytes. Writers keep sending the fields older readers expect. No coordinated update is needed.

**Major change** (move, resize or remove a field, change what a value means): bump the major. The app compares the pump's major with its own:

- Same major: normal use.
- Pump major is lower: the app says *Update the pump firmware* and allows only a firmware update.
- Pump major is higher: the app says *Update the app* and allows only a firmware update.

The app has one major for pump and tank, because firmware manifests of both are filtered by it. The tank's major follows the pump's even when nothing on the tank changed.

**Frozen across every major**, so the check above and OTA always work: the service UUID, the Info layout (append-only), Pair, Auth, OtaCtrl, OtaData and OtaStatus.

**Hardware revision**: set per build in Kconfig and reported in Info (pump) and every LoRa packet (tank, relayed to the app in the Tank characteristic). Bump it when a board change needs different firmware. Each firmware manifest lists the revisions the binary fits (`hw_revs`), and the app only offers a release whose `hw_revs` contains the connected board's revision and whose `proto_major` equals its own.

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
| 0b | Tank (the selected tank's sensor) | ✓ | |
| 0c | Schedule | ✓ | |
| 0d | Tanks (slot list) | ✓ | |
| 0e | Sensors (paired tank sensors) | ✓ | |
| 0f | History (last fills) | ✓ | |
| 10 | Battery (daily battery per sensor) | ✓ | |
| 11 | Wifi (network setup and status, minor 4) | ✓ | |
| 12 | Alert key (minor 6) | ✓ | |
| 13 | Alert log (minor 6) | ✓ | |

Advertised names: pump `TankLink-XXXX` (last 4 hex of MAC), tank `TL-Tank-XXXX`. The tank also puts its `tank_id` in manufacturer data under company ID `0xFFFF`.

**Pump advertising** (minor 2): flags, the complete name, and manufacturer data under company ID `0xFFFF` with one **state byte**: bit 0 = a phone can add it now (pairing window open), bit 1 = paired. The service UUID is in the scan response. The pump re-advertises whenever the state changes, so the app's Add pump screen shows *Ready to add* or *Not in pairing mode* without connecting, and waits for the window to open. Earlier firmware sends no manufacturer data.

## Pump characteristics

### Info (read, no auth) — frozen layout

18 bytes:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | BLE protocol major |
| 1 | 1 | BLE protocol minor |
| 2 | 1 | pump board revision |
| 3 | 1 | paired |
| 4 | 1 | flags: bit 0 = BLE pairing window open, bit 1 = this connection is authed |
| 5 | 6 | device_id (MAC) |
| 11 | 3 | firmware major, minor, patch |
| 14 | 4 | seconds the pump has been running (0 when off) |

### Pair (write + notify, no auth)

Write anything while the pairing window is open (hold the button ~5 s, `0xF2` from a phone that already has the pump, or the first 60 s after power-up while no phone has it) to claim the pump. The pump makes a new 16-byte token **for this phone**, notifies it on this characteristic, marks the connection authed and closes the window (one phone per window). The app stores the token. A write outside the window is rejected with *write not permitted*. An unpaired pump whose window has closed needs the button. Up to 8 phones; a claim when 8 already have the pump is rejected with *insufficient resources*.

This notify is the only time a token goes over the air.

### Auth (read + write)

Read: this connection's 16-byte nonce (random, new on connect and after every write).

Write: `HMAC-SHA256(token, "TLauth" || nonce)`, first 16 bytes. Success marks the connection authed as that phone. A wrong answer is rejected with *write not permitted*. Code: `tl_auth_response` in `components/tanklink_lora/tanklink_crypto.c`, `authResponse` in `protocol.dart`.

### State (read + notify)

`pump_on(1)`, 0 or 1.

### Cmd (write, authed)

Byte 0 is the opcode. Unknown opcodes and writes shorter than listed are rejected. Extra trailing bytes are ignored.

| Opcode | Meaning | Extra bytes |
| --- | --- | --- |
| `0x00` / `0x01` | Pump off / on | — |
| `0xA1` | Open LoRa tank-pair window (60 s default). A PAIR adds that sensor, or takes its new link key if already paired. Ignored when 4 sensors are paired | — |
| `0xA3` | Close the LoRa tank-pair window early (the app's Cancel); the pump's light goes back to standby. Minor 3 | — |
| `0xA2` | Unpair a sensor: deletes its tanks and their schedules. Refused while the pump fills one of its tanks. The last sensor's first tank stays, without a sensor | `sensor_id(6)` |
| `0xA4` | Select active tank slot (rejected for a different slot while running) | `slot(1)` |
| `0xA5` | Rename tank slot | `slot(1) name(≤16, UTF-8)` |
| `0xA6` | Set a tank slot's auto-off. Always on: clamped to 1–240 | `slot(1) minutes(1)` |
| `0xA7` | Set a sensor's float mode (see Sensors). Leaving two-tank mode deletes that sensor's second tank and its schedules, refused while the pump fills it | `sensor_id(6) mode(1)` |
| `0xA8` | Auto-fill on/off for a tank (see below). Turning it on is refused unless the tank has both floats: its sensor is in almost-empty mode and it is that sensor's pin-1 tank | `slot(1) on(1)` |
| `0xA9` | Save the usage settings (see Settings) | `flow_dlpm(u16) watts(u16) price_centi(u16) currency(4)` |
| `0xAA` | Check for a pump update now (Wi-Fi, see Wifi) | none |
| `0xAB` | Install the update the check found | none |
| `0xAC` | Forget the "updated automatically" notice | none |
| `0xAD` | Raise a test alert (see Alerts) | none |
| `0xAE` | Name the pump (minor 8). Refused if empty, longer than 24 bytes, not valid UTF-8 or containing control characters; leading and trailing spaces are dropped | `name` (UTF-8, 1–24 bytes) |
| `0xB1` | Test beep | — |
| `0xE0` | Clear last error | — |
| `0xE1` | Dismiss the interrupted-fill notice | — |
| `0xF0` | Unpair every phone: clears every phone's token, so all phones must add the pump again. The app no longer sends it (Remove only forgets the pump on that phone); factory reset does the same and more | — |
| `0xF1` | Factory reset | — |
| `0xF2` | Open the phone pairing window (60 s default), so another phone can add the pump. Refused while the pump runs or updates, because the window switches it off. Minor 2 | — |
| `0xF3` | Close the phone pairing window. Minor 2 | — |
| `0xF4` | Sign out every other phone: keeps only the sender's token and drops the other signed-in connections | — |

Maximum write length is 18 bytes.

### Settings (read no auth, write authed)

Minor 5 appends `auto_update(1)` to both the read and the write: 1 = the pump installs an update it found by itself, but only when it is unlikely to get in the way: the pump has been off for 10 minutes, it has been up for 10 minutes, no fill schedule is due in the next 60 minutes (with schedules set, the clock must be known), and a tank that fills by itself is not low. A failed try waits 6 hours. Off by default.

Read, 50 bytes (read and notify; the pump notifies whenever a setting or its name changes, to signed-in phones):

`run_secs(u32) serial(4 chars + NUL) buzzer_flags(1) buzzer_tone(1) led_brightness(1) starter_type(1) relay_pulse_ms(u16) flow_dlpm(u16) watts(u16) price_centi(u16) currency(4) auto_update(1) name(24)`

- **Name** (minor 8): the pump's own name, UTF-8, NUL-padded, empty until someone names it. Set with Cmd `0xAE` (below). Stored on the pump, so every phone that has the pump shows the same name; the app takes the pump's name when it connects and whenever it changes. The Bluetooth advertising name stays `TankLink-XXXX`.

- Usage, for the app's Water and power screen (set with Cmd `0xA9`): `flow_dlpm` pump flow in tenths of a litre a minute (0 = not set), `watts` pump power (default 750), `price_centi` price of a kWh in hundredths (0 = not set), `currency` UTF-8, NUL-padded (default ₹). Saved on the pump so every phone shows the same figures.

Write, at least 6 bytes (extra bytes from a newer app are ignored):

`buzzer_flags(1) buzzer_tone(1) led_brightness(1) starter_type(1) relay_pulse_ms(u16)`

- `buzzer_flags`: bit 0 enabled, bit 1 on button, bit 2 on pump start/stop, bit 3 on auto-off.
- `starter_type`: 0 = none (logical on/off only), 1 = two-button starter (Start/Stop momentary relays).
Auto-off is per tank (Cmd `0xA6`, Tanks) and the float mode per sensor (Cmd `0xA7`, Sensors).

### Tank (read + notify, authed)

The sensor of the **selected** tank (the one the pump fills), plus pump-wide error and interrupted-fill fields. `bound` = 0 when no sensor is paired. 59 bytes:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | bound |
| 1 | 1 | LoRa pairing window open |
| 2 | 6 | tank_id (tank MAC) |
| 8 | 3 | tank fw major, minor, patch |
| 11 | 1 | flags: bit 0 = the selected tank is full, bit 1 = almost empty (that sensor in almost-empty mode), bits 2–3 as LoRa |
| 12 | 1 | battery % |
| 13 | 1 | online (bound and heard within the stale window) |
| 14 | 2 | seconds since last packet (`0xFFFF` = never). Survives a restart when the DS3231 holds the time |
| 16 | 1 | RSSI dBm (int8) |
| 17 | 1 | SNR dB (int8) |
| 18 | 1 | pump last error code (see `ERROR_CODES.md`) |
| 19 | 16 | tank BLE OTA token (zeros if unknown) |
| 35 | 1 | interrupted fill reason: 0 none, 1 power cut, 2 power dip (brownout), 3 pump restarted |
| 36 | 4 | when that run started (u32, pump-local seconds since 1970; 0 = unknown) |
| 40 | 4 | last time it was seen running, ±1 min (u32, same format) |
| 44 | 4 | when the pump came back (u32, same format; filled in after the next phone time sync if the clock was unknown at boot) |
| 48 | 4 | how long it ran before the cut, seconds (u32, ±1 min) |
| 52 | 1 | tank board revision (0 = not heard yet) |
| 53 | 1 | selected tank's own fault code (see `ERROR_CODES.md`, 0 = none) |
| 54 | 1 | pump flags: bit 0 = the pump's clock lost power since it started (coin cell flat or missing). Not cleared by setting the time; the app shows *Clock battery flat* |
| 55 | 4 | pump boot id (u32): random, new every time the pump starts. The app keeps a dismissed *Clock battery flat* banner hidden only for the boot it was dismissed on |

For tank OTA the app authenticates to the tank with that sensor's token from the Sensors characteristic.

### Schedule (read/write/notify, authed)

Read and notify: `clock_valid(1) hour(1) minute(1) count(1)` followed by `count` × `enabled(1) hour(1) minute(1) slot(1)`, then `clock_flags(1)`: bit 0 = DS3231 present, bit 1 = DS3231 holds a trusted time.

Write:

- `0x01 year(u16) month(1) day(1) hour(1) minute(1) second(1) [utc_offset(i16)]`: at least 8 bytes. The optional last two bytes (minor 4) are the phone's UTC offset in minutes; the pump saves it (NVS `tl_clock/utc_off`) so SNTP time over Wi-Fi can be turned into local time. Sets the pump clock from the phone and writes it to the DS3231. Without a DS3231 (or with its battery flat), the clock is lost on reboot until the app sets it again. "Already started today" marks are kept when a sync moves the clock by 5 minutes or less, so the app's 15-minute re-sync can't start a schedule twice.
- `0x02 count(1)` followed by `count` × `enabled hour minute slot`: replaces the whole list. Maximum 4 entries.

### Tanks (read + notify, authed)

`active_slot(1) count(1)` followed by `count` × 20-byte entries: `slot_index(1) sensor_pin(1) sensor_index(1) auto_off_min(1) name(16, NUL-padded)`.

- `sensor_pin`: 0 = the sensor's pin 1, 1 = pin 2 (only in two-tank mode).
- `sensor_index`: the sensor (see Sensors) whose float this tank uses, `0xFF` = none.
- `auto_off_min`: 1–240. A fill always stops after the active slot's auto-off.

After the entries: `auto_fill_mask(1)`, bit *i* set = slot *i* fills itself when low.

**Auto-fill** (selected tank only, so the valve or lever must already point at it): the pump starts when that tank's almost-empty float drops, and stops when it is full or on auto-off. It starts once per drop: it is armed when the tank is seen above the float and fires on the next drop, so a tank that is already low (after a restart, a manual stop or turning the setting on) waits for the next one. At least 15 minutes after any stop. Only on a reading the tank sent since boot, never on one restored from flash. An automatic fill that stops any way other than "tank full" (auto-off, the app, the button) pauses auto-fill until the tank is next seen full, so a dry source or a stuck float can't keep starting the pump. The tank must be online, and nothing starts during pairing or an update.

Up to 8 slots. With no sensor paired there is exactly one slot (`sensor_index` `0xFF`), holding the name and auto-off for running without a sensor. Otherwise every slot has a sensor, each sensor has a pin-1 slot, and a pin-2 slot only in two-tank mode. A new sensor adds one slot; the first one takes over the sensorless slot.

**Only the selected tank** blocks a start when full or stops a running fill. Other tanks may be full (a lever or valve picks the tank). Selecting another slot (Cmd `0xA4`) is refused while the pump runs. A schedule switches to its slot before starting.

### Sensors (read + notify, authed)

`count(1) max(1)` followed by `count` × 35-byte entries:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | sensor index (stable while paired; used by Tanks) |
| 1 | 6 | sensor id (tank MAC) |
| 7 | 1 | float mode: 0 = second float off, 1 = almost-empty float, 2 = two tanks (pin 2 is a second tank's full float) |
| 8 | 1 | raw LoRa flags of its last packet |
| 9 | 1 | battery % |
| 10 | 1 | online |
| 11 | 2 | seconds since last packet (`0xFFFF` = never) |
| 13 | 1 | RSSI dBm (int8) |
| 14 | 1 | SNR dB (int8) |
| 15 | 3 | firmware major, minor, patch |
| 18 | 1 | board revision |
| 19 | 16 | BLE OTA token (zeros if unknown) |

After the entries, one fault byte per entry in the same order (the tank's own light code, 0 = none).

Notified on every packet from any sensor, and when one goes out of range.

### History (read + write + notify, authed)

The pump keeps its last 200 fills. A read returns one page: `total(1) start(1) count(1)` followed by `count` × 12 bytes, newest first, starting at fill `start` (0 = newest), at most 40 per page. Write `start(1)` (authed) to choose the page the next read returns; it is 0 after connecting. A notify (when a fill is added) is always page 0. The app reads every page on connect and after each notify.

Each fill:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | when it started (u32, pump-local seconds since 1970; 0 = clock unknown) |
| 4 | 4 | how long it ran, seconds (u32) |
| 8 | 1 | tank slot it filled |
| 9 | 1 | started by (cause) |
| 10 | 1 | stopped by (cause) |
| 11 | 1 | reserved, 0 |

Causes: 0 unknown, 1 app, 2 pump button, 3 schedule, 4 tank full, 5 auto-off, 6 power cut or restart, 7 update / pairing / unpair / factory reset, 8 auto-fill (start only). A fill cut by a power cut is added at the next boot with start cause 0 and stop cause 6. Notified when a fill is added. Cleared by factory reset.

### Battery (read + notify, authed)

Each paired sensor's lowest and highest battery % on each pump-local day, for the last 14 days. `count(1)` followed by, per sensor: `sensor_index(1) days(1)`, then `days` × `day(u16, pump-local days since 1970) min_pct(1) max_pct(1)`, oldest first.

Only logged while the pump knows the time; 0 % readings (no battery sense) are skipped. A sensor's log is cleared when it is unpaired. The app turns the daily lows into a trend: on solar, a falling low means the panel isn't keeping up. Notified when a log changes.

### Wifi (read + write + notify, authed; minor 4)

Optional. The pump joins one 2.4 GHz network (no WPA-Enterprise, no captive portals) and then sets its clock over SNTP and advertises `tanklink-<serial>.local`, service `_tanklink._tcp` on port 7580, TXT `id=<device id hex>`, `proto=<major>.<minor>`. Without a saved network nothing Wi-Fi runs.

Read (status): `state(1) rssi(i8, 0 = none) ip(4, a.b.c.d in byte order, 0 = none) ssid_len(1) ssid`, then (minor 5) `update_state(1) check_result(1) available_version(3) overnight_version(3)`, then (minor 7) `last_check_age_min(u16, 0xFFFF = never) available_size(u32, bytes, 0 = none)`. The app needs the whole block: a status without it is not read. State: 0 off, 1 connecting, 2 connected, 3 wrong password, 4 network not found. Notified when the state, address or signal changes.

Write, op in byte 0:

| Op | Payload | Does |
| --- | --- | --- |
| `0x01` SET | `ssid_len ssid pass_len pass` | Saves the network and connects. Empty password = open network |
| `0x02` FORGET | none | Disconnects and clears the saved network |
| `0x03` SCAN | none | Starts a scan (the pump scans so the app needs no location permission) |
| `0x04` SCAN_PAGE | `page(1)` | Later reads return that page of the scan results |
| `0x05` STATUS | none | Later reads return the status again |

**Pump updates itself** (minor 5). `update_state`: 0 none, 1 update available, 2 checking, 3 installing. `check_result`: 0 never, 1 ok, 2 no internet, 3 error. `available_version`: major, minor, patch of the update the last check found (zeros = none). `overnight_version`: the version the pump installed by itself (automatic install), until the app sends Cmd `0xAC` (zeros = none). Cmd `0xAA` checks now (needs Wi-Fi), Cmd `0xAB` downloads and installs what the check found; both return at once. Progress is in OtaStatus as for any update. Install is refused while the pump runs.

**While an update runs** (from the moment an install is asked for, including the pauses between download tries, or while any update from a phone is being written) the pump does not start (by button, app, schedule or auto-fill), does not open its pairing window, and refuses Unpair and Factory reset (the button holds for pairing and reset do nothing). A start press is not an error: no red light code, and the update light stays on. The app knows from `update_state` = 3 (installing) in the Wifi status, or from OtaStatus (`ready`, `writing`, `verify ok`, `rebooting`), whoever started the update, and then greys out Start, Add phone, Sign out other phones, Factory reset, Wi-Fi setup and the update buttons, and shows a banner with progress. Stop always works. The pump checks every 6 hours, the first time a random 1–61 minutes after it gets Wi-Fi after a start. A check that fails (no internet, a bad answer) is retried after 15 minutes, doubling up to 6 hours. A check that falls due while the pump is running, an update is being written or a pairing window is open waits 2 minutes and isn't counted as a failure. Cmd `0xAA` is refused in those same states (the app says why).

How: the pump asks the report service (`GET /v1/firmware/pump/latest?hw=&proto=`, `report_worker/README.md`) and downloads the image over HTTPS from GitHub. The image goes through the same `pump_ota` path as an update from the app, so the sha256 from the release, the signature check and the pump-off rule all apply: an image not signed with the TankLink key is refused whatever the server says.

Scan page read: `scanning(1) total(1) count(1)`, then `count` × `ssid_len ssid rssi(i8) auth(1)`; up to 8 per page, strongest first, `auth` 0 open, 1 secured, 2 not supported (Enterprise).

**Password.** BLE isn't encrypted, so in SET the password bytes are XOR'd with a 64-byte keystream: `HMAC-SHA256(token, auth_nonce || "wifi" || 0x00)` followed by the same with `0x01`. `token` is the signed-in phone's token and `auth_nonce` is the Auth nonce that connection signed in with (the one the app read just before its successful Auth write). A phone that has only just claimed the pump has no such nonce and must sign in again first. Test vector in `tanklink_app/test/protocol_test.dart`.

### OTA (pump and tank) — frozen

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

### Alerts (minor 6)

An alert is `seq(1) type(1) arg(1)` plus a 4-byte **tag** that proves this pump made it: the first 4 bytes of `HMAC-SHA256(alert_key, device_id[6] || seq || type || arg)`. `seq` runs 1–255 and wraps to 1 (0 = none); it is saved in NVS so a restart doesn't reuse numbers. A phone shows an alert only if `(seq - last_seen) mod 256` is 1–127, so a copy that arrives late, or by a second route, is ignored.

| Type | Meaning | `arg` |
| --- | --- | --- |
| 1 | Tank full: a fill stopped because the tank is full | fill (below) |
| 2 | A fill stopped by auto-off | fill |
| 3 | A fill was cut short by a power cut | fill |
| 4 | The selected tank's sensor went out of range (at most once every 30 minutes) | tank slot |
| 5 | A sensor's battery is at or below 20 % (again after 24 hours while it stays low, and after it has been back above 30 %) | battery (below) |
| 6 | Test alert (Cmd `0xAD`) | `0xFF` |
| 7 | A tank sensor was removed because its tank went into pairing mode (see *Leaving a pump* below) | sensor index (0–3) |

`arg` is signed by the tag with the rest of the alert. For types 1–3 ("fill"): bits 0–2 are the tank slot and bits 3–7 are how long the fill ran, in 5-minute steps (0 = under 5 minutes, 31 = 155 minutes or more). For type 5 ("battery"): bits 0–1 are the sensor index and bits 2–7 are the battery percentage divided by 2. The app turns these into text such as "Tank 1 is full. The pump stopped after about 40 minutes, about 480 litres."

Only a stop by "tank full" or by auto-off is an alert; stops from the app, the button or the system are the user's own action.

**Alert key (`0x12`, read, signed in):** 16 bytes, one random key per pump shared by its paired phones. It is made the first time a signed-in phone reads it. It is replaced when phones are removed (unpair, *Sign out other phones*, factory reset), so a removed phone's key stops working.

**Alert log (`0x13`, read + notify, signed in):** `count(1)` then `count` × `seq(1) type(1) arg(1) age_min(u16)`, newest first, up to 8. Kept in RAM, so it starts empty after a restart. The app reads it after signing in to catch up on alerts it missed.

**In the advertisement:** the manufacturer data is always the company ID `0xFFFF`, the state byte and **7 more bytes** (`seq type arg tag[4]`, zeros without an alert), so the advertisement is always 30 of 31 bytes. State bit `0x04` means an alert is in those bytes. The pump keeps an alert there for **60 minutes** (2 minutes for a test), and a new alert replaces it. A background scan filtered on that bit lets Android wake the app with it closed (`AlertScanner.kt`); a pump with no alert, and a tank sensor (6 bytes of manufacturer data), never match.

## Wi-Fi transport

The same characteristics, over TCP, when the pump is on Wi-Fi (the Wifi characteristic sets that up). Port **7580**, at most 3 clients; the pump advertises `_tanklink._tcp` over mDNS (see Wifi above). Reads, writes and notifications carry **exactly the bytes BLE does** (the characteristic's UUID suffix byte names it, `0x02` Info to `0x11` Wifi). Only the framing is new. Pairing a new phone (Pair) is **BLE only**, so nobody on the network can claim a pump.

Frame, all little-endian:

| Bytes | Field |
| --- | --- |
| 2 | length of everything after this field, tag included |
| 1 | type: `0x01` HELLO, `0x02` AUTH, `0x03` READ, `0x04` WRITE, `0x05` RESULT, `0x06` NOTIFY, `0x07` ERROR (reserved) |
| 1 | characteristic id (0 for HELLO) |
| 4 | frame counter: each side counts its own frames from 1 |
| n | payload |
| 8 | tag, on every frame after AUTH: first 8 bytes of `HMAC-SHA256(session_key, every byte before the tag, length field included)` |

- **HELLO** (pump → app, on connect): `nonce(16)` then the Info payload.
- **AUTH** (app → pump, untagged): the 16-byte answer `HMAC-SHA256(token, "TLauth" || nonce)[0..16)`, the same as the BLE Auth write, with HELLO's nonce. On success the pump replies RESULT (tagged); on failure it replies RESULT with status 1 (untagged) and closes.
- `session_key = HMAC-SHA256(token, nonce || "tcp")`, from the same token and nonce. Every later frame carries a tag; the receiver closes the connection on a bad tag or a counter that doesn't go up.
- Before AUTH only AUTH and a READ of Info (untagged) are accepted. Anything else closes the connection.
- **READ**: empty payload. **WRITE**: the bytes BLE would write (an OTA data write may carry up to 2048 bytes after the 4-byte offset). Requests are answered in order.
- **RESULT**: the request's characteristic id, then `status(1)` (0 ok, 1 not signed in, 2 bad length, 3 refused, 4 out of memory) and, for a successful READ, the value.
- **NOTIFY**: a characteristic's value, sent to every signed-in client (the pump gives each one everything BLE would, whether or not it "subscribed").
- A client that sends nothing for 90 s is dropped (send a READ of State as a keep-alive), and one that hasn't signed in after 10 s. A client too slow to take a notification is cut off.
- Payloads aren't encrypted (pump state isn't secret). The tag stops anyone else on the network from sending commands or changing replies. The Wi-Fi password in Wifi SET uses the same keystream as over BLE, with the nonce from HELLO.

`scripts/wifi_api_check.py` is a reference client: HELLO, AUTH, reads Info and State, and can send a test beep.

## Tank characteristics

The tank only runs BLE during a ~10 s window after a short button press, for OTA.

- **Info** (read, frozen layout, 13 bytes): `proto_major(1) proto_minor(1) hw_rev(1) paired(1)=1 tank_id(6) fw_major(1) fw_minor(1) fw_patch(1)`.
- **Auth** (read + write): same challenge as the pump, with the tank's OTA token. That token is `HMAC-SHA256(link key, "TLota")`, first 16 bytes, so it changes on every pairing and never goes over the air; the pump derives it from the link key and the app reads it from the pump's Tank or Sensors characteristic.
- **OtaCtrl / OtaData / OtaStatus**: same as the pump.

## LoRa (tank ↔ pump)

433 MHz, SX1278. Packed struct `tanklink_lora_status_t`, 21 bytes:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | magic `'T' 'L'` (`0x54 0x4C`) |
| 2 | 1 | LoRa protocol major (currently **5**) |
| 3 | 1 | type: `0x01` STATUS, `0x02` PAIR, `0x03` ACK, `0x04` UNPAIR |
| 4 | 1 | flags |
| 5 | 1 | battery % |
| 6 | 4 | seq (u32, per tank, only goes up; kept in the tank's NVS) |
| 10 | 6 | tank_id (tank MAC) |
| 16 | 3 | fw major, minor, patch |
| 19 | 1 | tank board revision (0 in ACK) |
| 20 | 1 | tank fault (LED code, 0 = none; 0 in ACK) |

On air:

- STATUS and ACK: the 21-byte body, then an 8-byte tag (29 bytes).
- PAIR: the body, the tank's new 16-byte **link key**, then the tag (45 bytes).
- UNPAIR: the same size as STATUS (29 bytes), `type = 0x04`, tagged with the link key the tank was paired with.

The tag is `HMAC-SHA256(link key, everything before it)`, first 8 bytes (`tl_lora_seal` / `tl_lora_verify`). A packet with a wrong tag is dropped. PAIR is tagged with the key it carries; the pump's ACK to it is tagged with the same key, and the tank only starts using the new key once it gets that ACK, so a failed pairing leaves the old link working.

The link key is sent in the clear once, in PAIR. Someone listening during that pairing window could learn it; after that, packets can't be faked or replayed.

Versioning: a receiver drops packets whose major differs from its own. Within a major, new fields go before the tag (after the key in PAIR), and receivers ignore bytes they don't know.

Flags: bit 0 = sensor 1 pin HIGH, bit 1 = sensor 2 pin HIGH, bit 2 = button, bit 3 = tank in pairing mode. Pins have internal pull-ups. The **pump** decides what a level means (full / empty / second tank), not the tank.

Exchange:

1. The tank sends STATUS (or PAIR, with a new link key, when the button has been held 3 s).
2. The pump accepts PAIR only while its tank-pair window is open (Cmd `0xA1`). It accepts STATUS only from a paired `tank_id` (up to 4) with a valid tag.
3. The pump replies ACK with the same layout, `type = 0x03`, the same `seq`, tagged with that tank's key. The tank retries up to 5 times without an ACK, with a random 40–440 ms gap so two tanks that collided don't retry in step. It only accepts a correctly tagged ACK carrying its own `tank_id` and `seq`.

**Leaving a pump (UNPAIR, `0x04`).** When a tank that was paired goes into pairing mode, it tells the pump it was paired with that it is gone, so the pump removes the sensor (as *Unpair* in the app does) instead of showing it offline for ever. The tank sends it **last**: after it paired with a new pump, or after pairing was cancelled or timed out. It is tagged with the **old** link key and sent twice at most (no more waiting if nobody answers). The pump that holds that key finds the sensor by `tank_id`, checks the tag and that `seq` is not older than the last it saw, removes the sensor and ACKs (tagged with the same key). A pump that was just paired again with the same tank already has the new key, so it fails the tag check and ignores the notice: re-pairing with the same pump keeps its tank names, schedules and settings. The pump refuses it while it fills that sensor's tank (the same rule as *Unpair*); the sensor can then be removed from the app. A pump that doesn't know type `0x04` ignores it, so no coordinated update is needed (`TANKLINK_LORA_VER` is unchanged).
4. The pump drops a STATUS whose `seq` is below the last one it saw from that tank (a replay). The same `seq` again is a retry: it is ACKed and updates RSSI/SNR but not state. The pump saves the last `seq` per tank in NVS, so this holds across restarts.
