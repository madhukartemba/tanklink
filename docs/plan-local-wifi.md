# Plan: local Wi-Fi for the pump

Status: **Phases 1 and 2 firmware are built (compile, not yet tried on a board); the app has the Wi-Fi byte layouts, tests and the UTC offset on the clock write. Phase 0 (hardware spike), Phase 3, the rest of Phase 4 and Phase 5 are not started.** Android app only. Local network first; internet is used only for time and pump firmware downloads. No cloud control.

## Goal

1. The pump joins the home Wi-Fi. The app controls it over Wi-Fi when it can and over BLE when it can't, with the same screens and features.
2. Pump firmware updates over Wi-Fi, two ways:
   - **The pump downloads the update itself** from the internet.
   - **The phone sends it over Wi-Fi**, which is much faster than BLE.
   - **Bluetooth stays** as the fallback the user can always pick.
3. Things that only work with Wi-Fi (see "What Wi-Fi adds").

BLE stays required: first setup, phone pairing, tank sensor pairing and **tank firmware updates** (the tank has no Wi-Fi) all keep using it.

## What Wi-Fi adds

| Feature | Phase | Needs internet |
| --- | --- | --- |
| Control from anywhere in the house (Wi-Fi range, not BLE range) | 2 | No |
| More phones connected at once (BLE allows 5) | 2 | No |
| Pump updates sent from the phone over Wi-Fi (about 10–30 s instead of minutes) | 2 | No |
| Pump downloads and installs its own updates | 3 | Yes |
| Pump checks daily for a new version; the app shows "Update available" right away | 3 | Yes |
| Optional: install pump updates automatically at night when idle (off by default) | 3 | Yes |
| Time set automatically (SNTP), even without the DS3231 or a phone sync | 1 | Yes |
| Wi-Fi signal and status in the app, for troubleshooting | 1 | No |

Later, in their own plans (Wi-Fi is the groundwork): Home Assistant / local MQTT, the pump's own web page for iPhones, and alerts away from home through the report Worker.

## Out of scope

- Cloud control of the pump. This plan never opens the pump to the internet; it only makes outgoing HTTPS requests.
- Wi-Fi on the tank node (battery; it stays LoRa + BLE).
- 5 GHz networks (the ESP32-C3 is 2.4 GHz only), WPA2/WPA3-Enterprise and captive portals. Say this in the setup screen.
- Old-version handling (see `AGENTS.md`).

## Work split

| Phase | What | Commit subject |
| --- | --- | --- |
| 0 | Spike: check memory and radio sharing on a real board | none (throwaway branch) |
| 1 | Pump: join Wi-Fi, set it up over BLE, status, mDNS, SNTP | `Pump joins Wi-Fi: setup over BLE, status, automatic time.` |
| 2 | Pump: local API over TCP (all features, plus OTA) | `Pump local API over Wi-Fi.` |
| 3 | Pump + Worker: the pump downloads its own updates | `Pump updates itself over Wi-Fi.` |
| 4 | App: Wi-Fi setup, Wi-Fi transport, update method picker | `App: connect and update over Wi-Fi.` |
| 5 | Docs and release | `Pump 0.21.0, TankLink app 1.10.0: local Wi-Fi.` (via `scripts/release.sh`) |

Phases 1–3 are firmware and can be built in that order without the app. Each one compiles and keeps BLE working.

If the BLE alerts plan (`docs/plan-ble-alerts.md`) is done first, its Kotlin bridge is the place to add the mDNS lookup in Phase 4.

---

## Phase 0 — Spike (do this first; it can change the plan)

On a real pump board, with NimBLE, Wi-Fi and one HTTPS download running together:

1. **Free heap.** Log `esp_get_free_heap_size()` and `heap_caps_get_minimum_free_size()` during a GitHub HTTPS download while a phone is connected over BLE. You want at least about 30 KB minimum free. If it's lower, try the settings under "Memory settings" below before going on.
2. **BLE with Wi-Fi on.** A BLE OTA and a History read still finish, and the app's connection doesn't drop over 30 minutes.
3. **Wi-Fi reconnects** after the router restarts, without the task watchdog firing (10 s, `CONFIG_ESP_TASK_WDT_TIMEOUT_S`).
4. **Binary size** stays well under the 1.75 MB OTA slot (about 725 KB today; expect about 1.2–1.3 MB).

Write the numbers into this doc before Phase 1.

### Memory settings to try (add to `pump_node/sdkconfig.defaults` only if needed)

```
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=y
CONFIG_MBEDTLS_DYNAMIC_BUFFER=y
CONFIG_MBEDTLS_ASYMMETRIC_CONTENT_LEN=y
CONFIG_MBEDTLS_SSL_IN_CONTENT_LEN=16384
CONFIG_MBEDTLS_SSL_OUT_CONTENT_LEN=4096
CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM=6
CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM=16
CONFIG_ESP_WIFI_DYNAMIC_TX_BUFFER_NUM=16
CONFIG_LWIP_TCP_SND_BUF_DEFAULT=5760
CONFIG_LWIP_TCP_WND_DEFAULT=5760
```

With BLE on, Wi-Fi must use modem sleep (`WIFI_PS_MIN_MODEM`, the default). Don't set `WIFI_PS_NONE`: coexistence needs the gaps.

---

## Phase 1 — Pump joins Wi-Fi

### 1.1 `pump_wifi.c` / `pump_wifi.h`

- Station mode only. **Off until credentials are set**, so a pump without Wi-Fi behaves exactly as today.
- Credentials in NVS `tl_wifi/ssid`, `tl_wifi/pass`. Cleared by factory reset and by the "Forget Wi-Fi" command.
- Event-driven connect, reconnect with backoff (2 s, doubling, max 5 min). Never block the poll or LoRa task: everything runs from Wi-Fi/IP events or its own task.
- `pump_wifi_state()`: off / connecting / connected / wrong password / network not found.
- Starts after BLE in `app_main` (`main.c`), after `relay_control_early_safe()`, as now.

### 1.2 Set up over BLE

New characteristic **Wi-Fi**, UUID suffix `0x11` (`TANKLINK_CHR_WIFI_INIT`; if the BLE alerts plan already used `0x11` for its Alert key, use `0x12`). Read, write, notify. **Auth required** for everything (same check as the other protected handlers in `gatt_svr.c`).

Read = status:

| Bytes | Field |
| --- | --- |
| 1 | state (above) |
| 1 | RSSI (signed dBm, 0 = none) |
| 4 | IPv4 address (0 = none) |
| 1 + n | SSID length + SSID (up to 32) |

Notify when the state or IP changes.

Write = one of these ops in byte 0:

| Op | Payload | Does |
| --- | --- | --- |
| `0x01` SET | ssid_len, ssid, pass_len, pass (encrypted, below) | Save and connect |
| `0x02` FORGET | — | Disconnect and clear credentials |
| `0x03` SCAN | — | Start a scan; results are read with op 0x04 |
| `0x04` SCAN_PAGE | page(1) | The next read returns up to 8 networks: ssid_len, ssid, rssi, auth type |

The pump scans for networks so the app doesn't need location permission to read the phone's SSID.

**Password encryption.** The BLE link isn't encrypted, so the password is XOR'd with a keystream: `HMAC-SHA256(token, auth_nonce ‖ "wifi" ‖ 0x00)` ‖ `HMAC-SHA256(token, auth_nonce ‖ "wifi" ‖ 0x01)` (64 bytes, enough for a 63-character WPA2 password). `token` is the signed-in phone's token and `auth_nonce` is this connection's Auth nonce. Both sides already have both. Use `tl_hmac_sha256` (`components/tanklink_lora/tanklink_crypto.c`) and `package:crypto` in Dart. Add a shared test vector to `test/protocol_test.dart`.

Append-only change: bump `TANKLINK_PROTO_MINOR`.

### 1.3 mDNS

- Add the `espressif/mdns` managed component to `pump_node/main/idf_component.yml`.
- Hostname `tanklink-<serial>` (`pump_pair_serial()`), service `_tanklink._tcp` on the API port (Phase 2), TXT records: `id=<device id hex>`, `proto=<major>.<minor>`.

### 1.4 Automatic time (SNTP)

- The pump keeps **local** time (`pump_clock.c`). SNTP gives UTC, so the pump also needs the phone's UTC offset.
- Append a 2-byte signed **UTC offset in minutes** to the existing set-time write (minor bump, same commit). Save it in NVS `tl_clock/utc_off`. The phone sends it on every sync, so a DST change is picked up the next time the app connects.
- When Wi-Fi is up: `esp_sntp` with `pool.ntp.org`, re-sync every 6 hours. On sync: local = UTC + offset → `pump_clock` and the DS3231 (`pump_rtc.c`), the same path a phone sync uses.
- No offset saved yet → don't apply SNTP (the pump can't know the local time).

### 1.5 Done when

- `idf.py build` passes and a pump without credentials behaves as before.
- Docs: `docs/PROTOCOL.md` (Wi-Fi characteristic, set-time change), `docs/CONFIGURATION.md` (NVS keys).

---

## Phase 2 — Local API over Wi-Fi

### 2.1 Design: the same characteristics, over TCP

The app already speaks every payload in `lib/ble/protocol.dart`. The TCP API carries **the same characteristic reads, writes and notifications, with the same bytes**, so nothing in the payload layer changes. Only the framing is new.

- TCP server on port **7580**, at most **3** clients.
- Frame:

| Bytes | Field |
| --- | --- |
| 2 | length of everything after this field |
| 1 | type: `HELLO 0x01`, `AUTH 0x02`, `READ 0x03`, `WRITE 0x04`, `RESULT 0x05`, `NOTIFY 0x06`, `ERROR 0x07` |
| 1 | characteristic: the UUID suffix byte (`0x02` Info … `0x10` Battery, `0x11`/`0x12` new). 0 for HELLO/AUTH |
| 4 | frame counter (each side counts its own frames from 1) |
| n | payload (exactly what the BLE read, write or notify carries) |
| 8 | tag (from AUTH on): first 8 bytes of `HMAC-SHA256(session_key, every byte before the tag)` |

- Handshake: on connect the pump sends HELLO (nonce, the Info payload). The app sends AUTH with the same response the BLE Auth characteristic takes (`tl_auth_response`). `session_key = HMAC-SHA256(token, nonce ‖ "tcp")`. After that, every frame carries a tag. The receiver drops the connection on a bad tag or a counter that doesn't go up.
- Before AUTH only HELLO, AUTH and a read of Info work, matching BLE.
- Payloads are not encrypted (pump state isn't secret). The tag stops anyone else on the network from sending commands or changing replies. The Wi-Fi password write (op SET) uses the same keystream as BLE, with this connection's nonce.

### 2.2 Firmware refactor: one API, two transports

Today the handlers live in `gatt_svr.c`, tied to NimBLE connection handles (`s_conns[]`, `authed`, `phone`).

- New `pump_api.c` / `pump_api.h`: a **session** (transport, id, authed, phone index, nonce) and `pump_api_read(session, chr, out)` / `pump_api_write(session, chr, data, len)`. Move each handler's logic from `gatt_svr.c` here. Payload building stays in `gatt_payloads.c`.
- `gatt_svr.c` keeps the NimBLE glue: the service table, and access callbacks that call `pump_api_*` with the BLE session for that connection.
- New `pump_wifi_api.c`: the TCP server, framing, tags, and calls into `pump_api_*` with a TCP session.
- Notifications: the existing `gatt_svr_notify_*` calls stay (other modules call them); each now also sends to every signed-in TCP client through `pump_wifi_api_notify`.
- OTA: `pump_ota_start/write/finish/on_disconnect` take a **session id** instead of `conn_handle`, so either transport can run an update. One update at a time stays the rule. Over TCP, OTA data writes can be up to 4 KB per frame.
- Pairing a new phone (Pair characteristic) and claiming stay **BLE only**, so someone on the network can't claim a pump.

This refactor is the largest piece. Do it as its own step and check that BLE still works (build, then a real phone) before adding the TCP server.

### 2.3 Done when

- `idf.py build` passes and BLE behaviour is unchanged.
- A small host-side Python script in `scripts/` (`wifi_api_check.py`) can HELLO, AUTH with a test token, read Info and State and send a test beep (`TANKLINK_CMD_TEST_BEEP`). Use it on a real board.
- `docs/PROTOCOL.md`: a "Wi-Fi transport" section with the framing, handshake and tag.

---

## Phase 3 — The pump updates itself

### 3.1 Worker endpoint

The full release list is too big to parse on the pump. Add to `report_worker/src/index.js`:

`GET /v1/firmware/pump/latest?hw=<PUMP_HW_REV>&proto=<major>`, built from the same cached release list as `GET /v1/releases`:

```json
{ "version": "0.21.0", "url": "https://github.com/.../pump_node.bin", "size": 1234567, "sha256": "…" }
```

It uses the same rules as the app (`AGENTS.md` → Versions): highest semver among `pump-v*` tags, skip any release whose manifest `proto_major` differs or whose `hw_revs` doesn't list `hw`. Cache it like `/v1/releases`. Update `report_worker/README.md`.

### 3.2 Firmware

- `pump_update.c`: `check()` calls the endpoint over HTTPS (`esp_http_client` + `esp_crt_bundle`), parses it with cJSON, and stores "update available: version, size" if the version is higher than the running one.
- Check once a day, at a random minute (so pumps don't all ask at once), and when the app asks.
- `install()`: `esp_https_ota`-style download that **feeds the existing `pump_ota_start/write/finish`** with the size and sha256 from the endpoint. That way the sha check, the signature check in `esp_ota_end` (`CONFIG_SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT`), the blocked pump start during OTA and OTA Status notifications all stay exactly as they are. Follow GitHub's redirect to its download host.
- Even if the Worker were compromised, a binary not signed with the TankLink key is refused. Say this in `docs/firmware-release.md`.
- Refuse to install while the pump is running. The download and install happen only when the pump is off, and the pump can't start during OTA (as today).
- New commands (`tanklink_uuid.h`, next free values; check for clashes): `CMD_UPDATE_CHECK`, `CMD_UPDATE_INSTALL`.
- Append to the State or Info payload (minor bump): update-available flag + version (3 bytes), and the last check result (ok / no internet / error).

### 3.3 Automatic install (off by default)

- Setting "Install pump updates automatically" (append to Settings; minor bump).
- When on: install only between 02:00 and 04:00 pump-local time, with the pump off, no fill schedule in the next 30 minutes, and a valid clock. Skip the night if any of these fails.
- After an automatic install the pump records it, and the app shows "Pump updated to X.Y.Z overnight" once.

### 3.4 Done when

- `idf.py build` passes; the Worker deploys with the new endpoint.
- On a real board: check finds a test release, install updates and reboots, and a binary signed with another key is refused.

---

## Phase 4 — App

### 4.1 Transport layer

- New `lib/link/pump_link.dart`: an interface with `read(chr)`, `write(chr, bytes)`, `notifications(chr)`, `connectionState` and `close()`.
- `lib/link/ble_link.dart`: wraps what `pump_session.dart` does with `flutter_blue_plus` today.
- `lib/link/wifi_link.dart`: `dart:io` `Socket`, the Phase 2 framing, HMAC with `package:crypto`, a reconnect loop.
- `lib/ble/pump_session.dart` talks to a `PumpLink` instead of BLE characteristics directly. Everything above it (screens, `protocol.dart`) stays the same.
- Unit tests for framing and tags in `test/wifi_link_test.dart`, with a shared test vector checked against the Phase 2 Python script.

### 4.2 Choosing the link

- Save the pump's last IP (from the Wi-Fi characteristic) with the pump in `lib/ble/models.dart`.
- On connect: try Wi-Fi at the saved IP (1.5 s timeout). If that fails, look it up with mDNS (Android `NsdManager` through a small Kotlin bridge; `_tanklink._tcp`, match the TXT `id`), then fall back to BLE.
- While connected over BLE, keep trying Wi-Fi in the background every 30 s and switch when it works. Never switch in the middle of an update.
- Setting per pump: "Connect over: Automatic / Bluetooth only".
- Show which link is in use: a small Wi-Fi or Bluetooth icon in the pump header.
- Over Wi-Fi, BLE-only actions (add a phone, pair a tank sensor, tank firmware updates) connect over BLE when needed and say "Move closer to the pump" if BLE can't connect.

### 4.3 Wi-Fi setup screen

`lib/screens/settings/wifi_screen.dart`:

- Status: network, signal, IP, state, using the Phase 1 text in plain words ("Wrong password", "Network not found").
- "Set up Wi-Fi": the pump's network list (SCAN), pick one, enter the password, connect, show the result.
- "Forget Wi-Fi".
- A line: "2.4 GHz networks only."
- Works over BLE (and over Wi-Fi once connected).

### 4.4 Pump updates

In the existing update flow (`lib/update/firmware_update_flow.dart`, `firmware_update.dart`):

- Method choice, best first, showing only what's possible right now:
  1. **Pump downloads it**: Wi-Fi connected and the pump's last check succeeded. Sends `CMD_UPDATE_INSTALL`, then follows OTA Status.
  2. **Send from this phone over Wi-Fi**: connected over Wi-Fi. The app downloads and verifies the binary as now, then sends it through the shared transfer (`lib/ble/ota_upload.dart`, now through `PumpLink`) with large chunks.
  3. **Send over Bluetooth**: always available, as today.
- If the chosen method fails, offer the next one ("Try over Bluetooth").
- The home update banner can use the pump's own "update available" flag, so it shows even when the phone hasn't checked GitHub.
- Settings: "Install pump updates automatically" switch, with a line saying it happens at night when the pump is off.
- Tank updates stay BLE only. No change there.

### 4.5 Done when

- `flutter analyze` is clean and `flutter test` passes (apart from the known offline smoke-test failure).
- `flutter build apk --release` builds.
- On a real phone and pump: set up Wi-Fi, control the pump with Bluetooth turned off on the phone, update the pump all three ways, and turn Bluetooth back on to pair a tank.

---

## Phase 5 — Docs and release

- `AGENTS.md`: code map (`pump_wifi.c`, `pump_api.c`, `pump_wifi_api.c`, `pump_update.c`, `lib/link/`), and the shared contracts table (Wi-Fi framing in `pump_wifi_api.c` ↔ `lib/link/wifi_link.dart`).
- `pump_node/WIRING.md` or the README: no wiring change; Wi-Fi is optional.
- Release with `scripts/release.sh`: pump and app minor bumps. Release notes: Wi-Fi is optional and set up from the app; the pump and the app must both be updated; 2.4 GHz only.

## Test matrix (real hardware)

| Case | Expect |
| --- | --- |
| Pump with no Wi-Fi set | Exactly as before |
| Wrong password | App shows "Wrong password"; pump keeps retrying slowly; BLE unaffected |
| Router off for 10 min, then on | Pump reconnects on its own; no restart, no watchdog |
| Phone Bluetooth off, same Wi-Fi | Full control, history, schedules, settings |
| Phone leaves Wi-Fi mid-session | App falls back to BLE when in range |
| Update: pump downloads | Installs and reboots; app follows progress |
| Update: phone over Wi-Fi | Much faster than BLE |
| Update: Wi-Fi drops halfway | Update fails safely; old firmware runs; "Try over Bluetooth" works |
| Binary signed with another key | Refused, whatever the method |
| Pump running when an update is asked for | Refused with a clear message |
| Two phones over Wi-Fi + one over BLE | All see live state changes |
| Someone on the network without a token | Can read Info only; every command is refused |
| No internet, Wi-Fi up | Local control works; update check says "No internet"; time from the phone as before |
| Overnight automatic install | Only in the window, only when idle, shown once in the app |
