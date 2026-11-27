# Plan: LoRa hub for far-away pumps

Status: **Design only. Nothing is built.** Android app only. Local only: no cloud control, same as the rest of TankLink.

## Goal

A **hub** sits in the house and talks to one or more pumps over LoRa, so the app can see and control pumps that are out of Bluetooth and Wi-Fi range.

1. The phone talks to the hub over Wi-Fi (the existing TCP protocol) or Bluetooth.
2. The hub talks to each linked pump over LoRa, on the same radio settings the tanks use.
3. Alerts from a far pump (tank full, auto-off, power cut, ...) reach the phone through the hub, with the app closed.

The hub is a **pump PCB with hub firmware**: ESP32-C3 SuperMini + RA-02, same pins, no relay module.

## Check first: do you need a hub?

If a far pump can join Wi-Fi (an outdoor access point or mesh node near it), the shipped Wi-Fi feature already gives full control, alerts and updates with no new code. A hub is for pumps beyond any Wi-Fi.

**Range test with no new code (do this before Phase 1):** pair a spare tank node to the far pump and put the tank where the hub will go (same height, same antenna). The pump's Sensors screen shows its RSSI and SNR, and the Tank screen shows how often it is heard. If the tank is heard reliably, the hub will be too: it uses the same radio, settings and power. Write the numbers here.

## What the hub can and can't do

LoRa at SF10 / 125 kHz moves a 31-byte packet in about 420 ms. That is enough for status and commands, not for the full app.

| Over the hub | Not over the hub (needs Bluetooth or Wi-Fi at the pump) |
| --- | --- |
| Pump on/off state, run time, last error, interrupted-fill notice | First setup, phone pairing, tank sensor pairing |
| Every tank: full / low / online, sensor battery, selected tank | Firmware updates of the pump or tanks (about 1.5 MB) |
| Start, stop, select tank, auto-fill on/off, clear error, dismiss notice | Schedules, buzzer, auto-fill times, usage settings, Wi-Fi setup |
| Pump name and tank names (fetched only when they change) | History (200 fills), battery history |
| Alerts, relayed to the phone with the app closed | Factory reset, unpair phones, open phone pairing |
| "Update available" / "Updating" shown; "Install update" sent (the pump downloads it over its own Wi-Fi, if it has any) | |

## Out of scope

- Cloud or internet access to the hub. The hub, like the pump, only makes outgoing requests (time, its own updates).
- Relaying firmware over LoRa.
- A pump reached through more than one hub, or a hub relaying through another hub (no mesh).
- Different radio settings for the hub link. The SX1278 listens at one spreading factor at a time, and the pump must hear its tanks, so every link stays SF10 / 125 kHz / 4/5. Longer range comes from the hub's antenna and placement.
- iPhone.
- Old-version handling (see `AGENTS.md`).

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Hub hardware | The pump PCB: SuperMini, RA-02, button, NeoPixel, buzzer. No relay module; DS3231 optional | Already built and tested; same LoRa pins |
| Antenna | External 433 MHz antenna on the RA-02's IPEX connector, mounted as high as possible | The only range lever at a fixed SF and +10 dBm (India's 10 mW limit) |
| Firmware | A new project, `hub_node/`, not a mode of `pump_node/` | Pump code is tied to `pump_control` everywhere (`pump_api.c`, `pump_pair.c`, `pump_ota.c` all include it); a role switch would put `#if` through the pump's safety code |
| Code reuse | Move the pieces with no pump logic into components (Phase 1). Copy and trim the rest | Keeps one copy of the framing, crypto and HTTP code; leaves the pump's tested logic alone |
| Phone ↔ hub | Same service UUID, Info, Pair, Auth and OTA characteristics as the pump; Wi-Fi TCP on port 7580 with the same framing | The app's scan, sign-in, Wi-Fi link and OTA code work unchanged |
| Telling a hub from a pump | Append `kind(1)` to Info (1 = pump, 2 = hub). Advertised name `TL-Hub-XXXX` | Info is append-only, so this is a minor change. The shorter name frees an advertisement byte (see Alerts) |
| Link key between hub and pump | The **app** makes a random 16-byte key and writes it to both: to the pump while signed in at the pump, to the hub while signed in at the hub, each sent with the connection's keystream (as the Wi-Fi password is). Never sent over LoRa | Unlike tank pairing, nothing secret goes on air, and no pairing windows have to line up between two far-apart places |
| Who may control pumps through the hub | Any phone paired with the hub controls every pump linked to it. Linking a pump needs a phone signed in **at that pump** | The pump's owner consents by linking; the hub is then trusted like a paired phone with a short command list |
| Limits | One hub per pump; up to 8 pumps per hub | 8 fits in 3 bits of the relayed alert; airtime stays low (see Airtime) |
| Push or poll | Both: the pump pushes changes and alerts; the hub polls as a heartbeat | Changes arrive in about a second without fast polling |
| Commands the hub may send | A fixed list on the pump (below); anything else is refused | A compromised or buggy hub can't factory-reset, unpair or reflash a pump |

---

## LoRa: hub ↔ pump

New packet types within LoRa major 5 (append-only rule: tanks drop them because the tag doesn't match their key, and the pump's receive loop ignores types it doesn't know). Bodies use their own layout; they share only the first 4 bytes with tank packets.

### Header (14 bytes) and tag

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | magic `'T' 'L'` |
| 2 | 1 | LoRa major (5) |
| 3 | 1 | type (below) |
| 4 | 6 | pump device_id (MAC): the addressee for hub → pump, the sender for pump → hub |
| 10 | 4 | seq (u32): the sender's own counter for this link, only goes up |
| 14 | n | payload |
| 14+n | 8 | tag: first 8 bytes of `HMAC-SHA256(link key, everything before it)` (`tl_lora_seal`) |

Each side keeps its own counter per link and the last seq it accepted from the other side. A packet with a bad tag or a seq that isn't higher is dropped. Counters are saved to NVS in steps (reserve the next 256 at boot and when used up), so a restart never reuses one and flash isn't written per packet.

### Types

| Type | Name | Direction | Payload |
| --- | --- | --- | --- |
| `0x10` | HPOLL | hub → pump | `want(1)`: bit 0 = state, bit 1 = names page (with `page(1)`) |
| `0x11` | HSTATE | pump → hub | `req_seq(4)` (0 when pushed), then State (below) |
| `0x12` | HCMD | hub → pump | `retry_of(4)` (0 on a first try), then the Cmd bytes as the app writes them (≤ 18) |
| `0x13` | HRESULT | pump → hub | `req_seq(4) status(1)` (the `pump_api_err_t` value), then State |
| `0x14` | HNAMES | pump → hub | `req_seq(4) page(1)`; page 0 = pump name (≤ 24 bytes), pages 1–8 = that slot's name (≤ 16) |
| `0x15` | HALERT | pump → hub | The alert exactly as the pump made it: `seq type arg tag[4]` |
| `0x16` | HACK | hub → pump | `ack_seq(4)`: the pushed HSTATE or HALERT the hub got |

**Retries:** a hub request gets an answer within about 1 s or is sent again with a new seq, up to 3 times with a random 0.3–1.5 s gap. A pushed HSTATE or HALERT is sent again until HACK, up to 3 times. **HCMD is not re-run:** the pump keeps the last command's seq and result; a resend of a command whose answer was lost carries a new seq **and** the original seq in `retry_of`, and the pump answers with the saved result if it already ran it.

### State (pump → hub), 26 bytes

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | pump on |
| 1 | 1 | last error (`ERROR_CODES.md`) |
| 2 | 2 | minutes running (u16, 0 when off) |
| 4 | 1 | selected slot (`0xFF` none) |
| 5 | 1 | flags: bit 0 interrupted-fill notice, bit 1 updating, bit 2 update available, bit 3 auto-fill armed, bit 4 auto-fill paused, bit 5 clock battery flat |
| 6 | 1 | slot count (0–8) |
| 7 | 8 | per slot: bit 0 full, bit 1 low, bit 2 sensor online, bit 3 has a sensor, bit 4 auto-fill tank |
| 15 | 4 | battery % of sensors 0–3 (`0xFF` none) |
| 19 | 3 | pump firmware major, minor, patch |
| 22 | 1 | names revision: goes up when the pump or a slot is renamed or slots change, so the hub refetches HNAMES |
| 23 | 1 | newest alert seq (0 none), so the hub notices a missed HALERT |
| 24 | 2 | auto-off minutes left for the running fill (u16, 0 = not running) |

Sealed size: 14 + 4 + 26 + 8 = 52 bytes, about 620 ms on air.

### Commands the pump accepts from the hub

Cmd opcodes `0x00` / `0x01` (off / on), `0xA4` (select slot), `0xA8` (auto-fill on/off), `0xAA` (check for update), `0xAB` (install update), `0xAC`, `0xAD` (test alert), `0xE0`, `0xE1`. Everything else returns `PUMP_API_ERR_REFUSED`. Every command goes through `pump_api_write` with the hub's own session, so the start checks, update lock and auto-off apply exactly as from a phone.

### When the pump pushes

HSTATE on: pump on/off, last error set or cleared, the selected slot's full/low/online changes, a slot selected, update state changes. HALERT whenever `pump_alert_raise` runs (a new alert sink in `pump_alert.c`). At most one push every 5 s; changes inside that gap go in the next one.

**Listen before talk:** before an unsolicited send (pump pushes, hub polls) the sender runs the SX1278's channel activity detection (CAD, about 2 symbols ≈ 16 ms at SF10) and waits a random 100–600 ms if the channel is busy. Answers (HSTATE to a poll, HRESULT, tank ACKs) go out right away, as tank ACKs do now.

### Airtime

| Traffic | Per exchange | Default rate | Share of the channel |
| --- | --- | --- | --- |
| Hub heartbeat per pump (HPOLL + HSTATE) | about 1.1 s | every 120 s, 4 pumps | about 4 % |
| One pump open in the app | about 1.1 s | every 15 s | about 7 % |
| Tanks (STATUS + ACK) | about 0.9 s | every 300 s, 4 pumps × 4 sensors | about 5 % |

Under 20 % at worst, so collisions are occasional and the retries above cover them. A tank STATUS that arrives while its pump is sending is lost; the tank retries (5 attempts, random backoff) as it already does. Keep the in-app rate at 15 s or slower, and say in the app's "Tank updates" help that very short intervals (under 1 min) with a hub on the same pumps make the channel busy.

A pump that misses 3 heartbeats in a row is shown as **Not reachable** in the app with the age of the last state.

---

## Pump firmware changes

New file `pump_node/main/pump_hub.c`:

- Link record in NVS (`tl_hub`: hub id, key, counters). A changed layout fails its size check and loads "no hub", per the no-migration rule.
- Receives hub packet types from `lora_link.c`'s receive loop (a dispatch on `type` before the tank handling; the radio, its task and the receive-mode watchdog stay in `lora_link.c`).
- A hub session: `pump_api_session_t` with id `PUMP_API_HUB_ID` (`0x7FFD`), authed, `phone = -1`, plus a flag that makes `pump_api_write` check the command list above.
- Builds State and the names pages from existing getters (`pump_control_*`, `pump_tanks_*`, `lora_link_slot_*`, `pump_update_*`, `pump_autofill_*`).
- Push throttle and retries on a timer; CAD in `components/tanklink_lora/sx1278.c` (`sx1278_channel_busy()`).

App-facing additions (BLE minor bump, append-only):

- Cmd `0xB2` link hub: `hub_id(6) key(16)`, the key sent with the keystream. Replaces an existing link.
- Cmd `0xB3` forget hub.
- New characteristic `0x16` **Hub** (read + notify, signed in): `linked(1) hub_id(6) seconds since last packet(u16, 0xFFFF never) rssi(i8) snr(i8)`.
- Info: append `kind(1)` = 1.

Also: `pump_ota.c` refuses an image whose `esp_app_desc_t.project_name` isn't `pump_node` (and the hub refuses anything but `hub_node`). Both are signed with the same key, so this is what stops the app or a mixed-up release from flashing hub firmware onto a pump.

Memory: State is built on the stack; no new task (the LoRa task does the work). Check `DIAG: heap` after the change.

## Hub firmware (`hub_node/`)

| File | Job | From |
| --- | --- | --- |
| `main.c` | Boot, NimBLE, advertising (`TL-Hub-XXXX`, state byte, relayed alert) | trimmed `pump_node/main/main.c` |
| `hub_pumps.c` | Linked pumps (up to 8): id, key, counters, cached State and names, last heard, RSSI/SNR. NVS `tl_hubp` | new |
| `hub_link.c` | LoRa: poll schedule, requests and retries, receive pushes, HACK, CAD, receive-mode watchdog | new, patterned on `lora_link.c` |
| `hub_api.c` | `hub_api_read` / `hub_api_write` for both transports (below) | new, patterned on `pump_api.c` |
| `hub_gatt.c` | BLE service table, Pair, notifications | trimmed `gatt_svr.c` |
| `hub_pair.c` | Phone tokens (up to 8), pairing window | trimmed `pump_pair.c` (no pump-off rule) |
| `hub_ota.c` | Firmware update from either transport or from itself | trimmed `pump_ota.c` (no relays) |
| `hub_update.c` | Self-update checks every 3 h; installs when no command is in flight | trimmed `pump_update.c` |
| `hub_alert.c` | Holds the newest relayed alert in the advertisement for 60 min; alert log | new, small |
| `board.c`, `status_led.cpp`, `buzzer.c` | Button (hold 5 s = phone pairing, 15 s more = factory reset), LED, buzzer | copied |

Shared components (Phase 1):

| Component | Contents | Used by |
| --- | --- | --- |
| `components/tanklink_lora/` (exists) | radio, packet formats (add the hub header and types to `tanklink_lora_proto.h`), crypto, CAD | pump, tank, hub |
| `components/tanklink_net/` (new) | Wi-Fi join / reconnect / scan / mDNS / SNTP with the TX power cap (from `pump_wifi.c`), TCP framing and session tags (from `pump_wifi_api.c`, dispatching to a callback), update HTTP client with the device kind in the URL (from `pump_update_http.c`) | pump, hub |

The hub keeps the pump's Wi-Fi traps: TX power capped at 8.5 dBm, cross-signed roots option, flash-resident Wi-Fi code. It has more free heap than the pump (no schedules, history or tank logic).

The pump PCB's relay pins (GPIO0/1) are left as inputs; with no relay module fitted nothing is connected. The hub never drives them.

`HUB_HW_REV` in Kconfig starts at 1 (the pump PCB). Hub manifests list it in `hw_revs`, and the app picks hub releases by tag prefix and Info `kind`, not by hw_rev alone (the pump PCB's revision number is the same).

## Phone ↔ hub

Same transports as a pump. Characteristics the hub serves:

| XX | Name | Notes |
| --- | --- | --- |
| 02–04, 08–0a | Info, Pair, Auth, OtaCtrl/Data/Status | Same as the pump (frozen). Info `kind` = 2 |
| 11 | Wifi | Same as the pump |
| 20 | **Pumps** (read + notify, signed in) | `count(1)`, then per pump: `index(1) pump_id(6) reach(1)` (0 unknown, 1 ok, 2 not reachable) `age_s(u16) rssi(i8) snr(i8)`, the State bytes, `names_rev(1)`. Notified when any of it changes |
| 21 | **HubCmd** (write, signed in) | `0x01` add pump: `pump_id(6) key(16)` (keystream). `0x02` remove pump: `pump_id(6)`. `0x03` send command: `pump_id(6) req(1)` then Cmd bytes. `0x04` watch pump: `pump_id(6)` (poll every 15 s for 2 min; the app repeats it while the screen is open). `0x05` fetch names: `pump_id(6)` |
| 22 | **HubResult** (notify, signed in) | `req(1) pump_id(6) status(1)`: status is the pump's `pump_api_err_t`, or `0x80` not reachable, `0x81` busy (another command to that pump is in flight) |
| 23 | **Names** (read, signed in) | `pump_id(6)` written first, then read: pump name and slot names from the hub's cache |

A command answers in about 1–3 s (up to about 6 s with retries). The app shows the button as busy until HubResult arrives.

## Alerts

The hub relays each pump's alert **unchanged**, including the pump's own 4-byte tag. The phone already has every pump's alert key (it read it while signed in at the pump) and keeps a last-seen `seq` per pump, so:

- the tag check and "show each alert once" work as they do now, and an alert heard both from the pump directly and through the hub shows once;
- no new alert format and no hub alert key.

**Advertisement:** flags (3) + name `TL-Hub-XXXX` (13) + manufacturer data (14): company `0xFFFF`, state byte (bit 0 pairing open, bit 1 paired, bit 2 alert present, bit 3 = this is a hub), `pump_index(1)`, `seq type arg tag[4]` = 30 of 31 bytes. The phone maps `pump_index` to the pump's device_id from the Pumps list it saved when it last read the hub, then verifies the tag with that pump's alert key. `AlertScanReceiver.kt` needs the hub layout; the scan filter on bit 2 stays.

Later (not in the first version): a hub-made alert when a pump becomes not reachable, and the hub's buzzer sounding for relayed alerts (with the pump's quiet hours rule).

## App changes

- **Add a hub:** the same Add flow as a pump (BLE scan, Pair). Info `kind` = 2 opens the hub setup instead of the pump screens. Optional Wi-Fi setup reuses `wifi_screen.dart`.
- **Link a pump to a hub:** on the pump's Settings, *Link to hub*: pick a saved hub. The app makes the key, writes Cmd `0xB2` to the pump now, and writes HubCmd add to the hub now if it can reach it, otherwise saves the pending half (secure storage) and finishes it the next time it signs in to the hub. *Unlink* does both removes the same way.
- **Home screen:** pumps reached only through a hub appear in the normal pump list with a *via hub* label and the age of the last state. Opening one shows a **reduced pump screen** (`screens/remote_pump_screen.dart`): state, tanks, start/stop, select tank, auto-fill switch, clear error, update banner. When the phone can reach the pump directly (Bluetooth or Wi-Fi) the full screen is used as now.
- **New code:** `ble/hub_session.dart` (connection, Pumps / HubResult parsing, commands with timeouts), hub parsers in `protocol.dart` with tests in `test/protocol_test.dart`, constants in `tanklink_uuids.dart`, Kotlin alert receiver update.
- **Updates:** `hub-v*` releases in the update checker, filtered by Info `kind`; the update sheet's three methods (hub downloads it, phone over Wi-Fi, phone over Bluetooth) as for the pump.
- User text stays short: *Not reachable (last heard 12 min ago)*, *Sending…*, *The pump didn't answer. Try again.*

## Report service

- `GET /v1/firmware/hub/latest?hw=&proto=` and `GET /v1/firmware/hub/download/<ver>.bin`, the same as the pump routes with the `hub-v` prefix.
- `/v1/releases` already lists every release; nothing to change.

## Release

- `scripts/release.sh`: a `hub` component (`hub_node/main/hub_version.h`, `scripts/make_hub_manifest.sh`, assets `hub_node.bin` and `firmware-manifest.json`).
- The first release is pump + hub + app together: the pump needs `pump_hub.c` and Cmd `0xB2`, the app needs the hub screens. Tanks are unchanged (no tank release).
- Release notes: the pump PCB without the relay module becomes a hub; fit an external antenna; hub firmware must be flashed over USB the first time.

## Shared contracts to add to `AGENTS.md`

| Contract | Pump | Hub | App |
| --- | --- | --- | --- |
| Hub LoRa header, types, State layout, command list | `pump_hub.c`, `tanklink_lora_proto.h` | `hub_link.c`, same header | — |
| Hub characteristics (Pumps, HubCmd, HubResult, Names), Info `kind` | `tanklink_uuid.h` (`kind`, `0x16` Hub) | `hub_node/main/tanklink_hub_uuid.h` | `tanklink_uuids.dart`, `protocol.dart` (`test/protocol_test.dart`) |
| Hub advertisement with relayed alert | — | `main.c` (`advertise`) | `protocol.dart`, `AlertScanReceiver.kt` |
| Hub update request | — | `components/tanklink_net` | `report_worker/src/index.js` |

## Work split

| Phase | What | Commit subject |
| --- | --- | --- |
| 0 | Range test with a spare tank node at the hub spot (no code); write the numbers here | none |
| 1 | Move Wi-Fi, TCP framing and update HTTP into `components/tanklink_net`; pump builds and behaves the same; add CAD to `sx1278.c` | `Move pump Wi-Fi and update code into a shared component.` |
| 2 | Pump: `pump_hub.c`, hub packet types, Cmd `0xB2`/`0xB3`, Hub characteristic, Info `kind`, project-name check in OTA | `Pump answers a LoRa hub.` |
| 3 | Hub firmware: BLE, pairing, Wi-Fi, linked pumps, LoRa polling and pushes, Pumps/HubCmd/HubResult/Names, relayed alerts, OTA | `Hub firmware: control far pumps over LoRa.` |
| 4 | Worker hub routes, release script, manifests | `Hub releases and update routes.` |
| 5 | App: add hub, link pump, via-hub pumps, reduced screen, alerts from the hub, hub updates | `App: pumps through a LoRa hub.` |
| 6 | Docs (`PROTOCOL.md`, `PINMAPS.md` hub section, `CONFIGURATION.md`, `AGENTS.md` tables) and release | via `scripts/release.sh` |

Phases 1–3 can be built and checked with a serial log before the app exists: a debug command on the hub's serial console (`link`, `poll`, `cmd`) makes testing on two boards possible early.

## Effort

| Phase | Size | Notes |
| --- | --- | --- |
| 1 | 3–4 days | Mostly moving code; the risk is breaking the pump's Wi-Fi, so retest a pump on Wi-Fi after it |
| 2 | 4–6 days | Small file, but the command list, retries and NVS counters need care |
| 3 | 1.5–2 weeks | Largest part; much is trimmed pump code |
| 4 | 1–2 days | |
| 5 | 1–1.5 weeks | Hub session, reduced screen, pending link, Kotlin alert change |
| 6 | 2–3 days | Plus the release itself |
| Testing on boards | 1 week or more | Range, collisions with tanks, missed packets, a pump restarting mid-command, the hub restarting. No hardware-in-the-loop exists |

About **5–7 weeks** in total for a first release. A smaller first step (Phases 0–3 with a serial console, no app) shows whether the link works at your distances in about 2–3 weeks.

## Risks and open questions

- **Range is the unknown.** Phase 0 answers it. If the far pump is marginal at SF10, the plan doesn't fix that; moving to SF11/12 for every link is a breaking radio change (pump, tanks and hub together) and doubles to quadruples airtime.
- **Channel load** grows with pumps × sensors × short "Tank updates" intervals. Watch the tank's retry count and the hub's not-reachable rate during testing.
- **Trust:** a hub controls every linked pump for every phone paired with it. Losing the hub means re-linking (the pump keeps working on its own; nothing on the pump depends on the hub).
- **Stale state:** the app must always show the age of a via-hub state and never present it as live.
- **Name:** `TL-Hub-XXXX` vs a user-set hub name (Settings on the hub). Decide in Phase 3.
