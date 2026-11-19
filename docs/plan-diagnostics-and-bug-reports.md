# Plan: device diagnostics and "Report a problem"

Goal: when something fails on a user's pump, tank or phone, you get enough detail to tell what failed. Reports land as grouped issues in a private GitHub repo. Pump control itself stays fully local.

## Constraints that shape it

- **No cloud in pump control.** The pump and tank never reach the internet. Only the phone does, so the phone collects everything and sends it. Reporting is the only feature that uses the internet; the app works the same without it.
- **The user sends it, after seeing it.** Nothing leaves the phone automatically.
- **Field boards update only over BLE OTA.** OTA never rewrites the partition table, so anything that needs a new partition (ESP-IDF core dumps) only reaches boards someone reflashes over USB with `erase-flash`. Phase 1–3 must work with the current `partitions_ota.csv`.
- **The tank is asleep almost all the time** and its BLE is only up for ~10 s after a button press. Its diagnostics have to ride on LoRa to the pump.
- **Never include secrets**: phone owner token, auth keys, sensor BLE OTA tokens.
- No migrations (see AGENTS.md). New NVS blobs that fail their size/magic check just start empty.

## What gets collected

| Source | What | Survives |
| --- | --- | --- |
| App | Rolling log file: BLE connect/disconnect and errors, failed commands, OTA failures (stage + error), update-check/download failures, uncaught Dart and Flutter errors with stack traces | App restarts (file, capped) |
| Pump | Event log in NVS: each boot with reset reason (panic, watchdog, brownout, power-on), error codes as they are set/cleared, tank offline/back, RTC failures, OTA start/fail/success, NVS init failures, factory reset | Power cuts |
| Pump | Log text: the last ~8 KB of INFO, WARN and ERROR lines (what the serial monitor shows), so a report shows what led up to a failure | Restarts and crashes (no-init RAM), not power cuts |
| Pump | Crash record: on panic, the faulting PC, exception cause and a short backtrace | Restarts and crashes (no-init RAM), not power cuts |
| Pump | Counters: boots, LoRa packets received / bad CRC / unknown sender, ACKs sent, BLE auth failures | Flushed to NVS hourly and on events (limits flash wear) |
| Tank | Reset reason, boot count, TX attempts, missed ACKs, last error code, battery | Sent to the pump on every STATUS; pump keeps the latest per sensor |
| Phone | App version, Android version, phone model, BLE permissions state | Read at report time |

## Phase 1 — App log and "Report a problem" (app only, next app release)

**Status:** released in app 1.4.0. The Worker is live at `https://tanklink.madhukartemba.in` (apps 1.4.0–1.4.1 use the older `tanklink-reports.` name, which still works).

Ships alone; already useful for app-side failures (BLE, updates, crashes).

1. **`lib/diag/app_log.dart`**: a small logger with levels, writing lines to a file in the app support dir. Two files of 256 KB, rotating. **Keeps INFO lines as well as warnings and errors**: screen opened, pump connected/selected, command sent and its result, tank selected, update checked. That shows the steps that led to an error, not just the error. Keeps the last 500 lines in memory for the report.
2. **Catch everything in `main.dart`**: `FlutterError.onError`, `PlatformDispatcher.instance.onError`, and route `debugPrint` into the logger.
3. **Log at the failure points** that already exist: `pump_session.dart` (connect, discover, auth, command writes, disconnect reason), `ota_upload.dart` (stage, offset, status byte), `update/` (HTTP status, sha256 mismatch, install errors). One line each, no payload bytes except opcodes.
4. **Screen: Settings → Report a problem** (`lib/screens/report_problem_screen.dart`):
   - "What went wrong?" text box (required) and "When did it happen?" (now / today / earlier).
   - Checkboxes, on by default: app log, pump diagnostics (greyed out until Phase 2 or when not connected), phone details.
   - **Preview** button showing the exact text that will be sent.
   - **Send**: POSTs the report to the report service (below). On success, shows the short report ID it returns ("Sent. Report ID K7Q2") so the user can quote it.
   - **No internet or service down**: the report goes into a queue in the app support dir and is sent on the next app start, or when the user taps Retry. At most 10 queued; oldest dropped.
   - Secondary **Save or share file**: builds `tanklink-report-YYYYMMDD-HHMM.txt` and opens the Android share sheet (`share_plus`), for when sending won't work at all.
   - One line under Send says where it goes: "Sent to the TankLink developer to fix the problem."
   - `lib/diag/report_sender.dart` holds the URL and app key as constants, the POST, and the queue.
5. **`lib/diag/report_builder.dart`**: pure function from inputs to report text. Redacts tokens and shortens sensor IDs to the last 3 bytes. Unit tested, including a test that no token bytes appear.
6. **Report from the error itself, on the home screen.** Every error banner in `screens/home/home_banners.dart` gets a **Report** button next to its existing actions:
   - pump error codes (1–9) and tank sensor codes
   - "Fill stopped by a power cut / dip / restart" notices
   - connection failures (can't connect, auth rejected, disconnected mid-command)
   - a failed firmware or app update

   Tapping it opens Report a problem with the error already filled in: a title like "Pump error 3: Tank offline", the time it appeared, and the error's details (code, sensor, when it was last seen). The user only has to add a sentence and send. The log is attached and the pump diagnostics are read in the background while they type.

   Failed-update dialogs and snackbars for failed commands get the same "Report" action. The general Settings → Report a problem entry stays for problems that don't show an error.

New dependencies: `share_plus`, `device_info_plus` (`http` is already there).

Phase 1 also needs the report service (next section) live before the app ships.

## Report service — Cloudflare Worker → private GitHub repo

Lives in this repo as `report_worker/` (`wrangler.toml`, `src/index.ts`, README with deploy steps). About 0.5 day.

**Setup (once)**
- Private repo `tanklink-reports`. Labels are created by the Worker as needed.
- Fine-grained GitHub token limited to that repo: Issues read/write, Contents read/write. Stored as a Worker secret (`wrangler secret put GITHUB_TOKEN`), never in the app.
- App key stored as a Worker secret too, and as a constant in the app. It can be pulled out of the APK; it only stops casual spam. Rotate it by shipping a new app if it gets abused.
- Route the Worker to `tanklink.madhukartemba.in`. The app only knows this URL, so the backend can later move to your own server without an app update.

**`POST /v1/report`** — JSON `{app_key, fingerprint, title, labels[], summary, report_text}`
1. Reject if the app key is wrong, the body is over 200 KB, or the IP has sent more than 10 reports in the last hour (Cloudflare rate-limiting rule, no code).
2. Save `report_text` as `reports/YYYY/MM/<id>.txt` in the repo (Contents API). `<id>` is a short random ID.
3. Look for an open issue with the label `fp:<fingerprint>`:
   - Found: add a comment with the summary, versions and a link to the file.
   - Not found: open an issue with the title, summary, link, and labels such as `pump-err-3`, `pump-0.14.0`, `app-1.3.0`, `crash`, `fp:<fingerprint>`.
4. Return `{id}`.

**Fingerprint** (built by the app, so the Worker stays simple): error kind + code + firmware version, plus the crash PC when there is one. A report without an error (from Settings) uses `manual` + a random part, so each one gets its own issue.

**Privacy**: the issue holds only the summary and versions; the full report is a file in the private repo. Tokens are already stripped by the app.

## Crash decoding (on your Mac, no server)

- Attach `pump_node.elf` and `tank_node.elf` to every firmware release as extra assets. The app picks assets by exact name, so extra files are ignored. Add this to the release checklist in `AGENTS.md` and `docs/firmware-release.md`.
- `scripts/decode_crash.sh <report.txt>`: reads the firmware version and crash addresses from the report, downloads that release's `.elf` with `gh release download`, and runs `riscv32-esp-elf-addr2line -pfiaC` from ESP-IDF. Prints function names and source lines.
- Only from Phase 2 on, when pump reports carry crash records.

## Phase 2 — Pump diagnostics over BLE (next pump + app releases)

1. **`pump_node/main/pump_diag.c/.h`**, modelled on `pump_history.c`:
   - Event ring of 64 entries × 12 bytes in one NVS blob (`tl_diag/events`): `local_time u32 (0 = unknown), uptime_s u32, boot_no u16, code u8, arg u8`.
   - `pump_diag_event(code, arg)` called from: `app_main` (boot + `esp_reset_reason()`), `pump_control.c` where `last_err` changes, `lora_link.c` (tank offline/back), `pump_rtc.c`, `pump_ota.c`, `pump_config.c` (factory reset).
   - Writes are throttled: the same code+arg within 60 s bumps a repeat count instead of a new entry.
   - Counters in RAM, flushed to `tl_diag/counts` hourly and before OTA reboot.
2. **Crash capture without a new partition**:
   - `__NOINIT_ATTR` struct in RAM (survives panic, watchdog and software resets; not power cuts) holding magic, PC, cause, an 8-frame backtrace, and an 8 KB ring of log text.
   - Fill the log ring from an `esp_log_set_vprintf` hook that keeps **INFO, WARN and ERROR** (DEBUG/VERBOSE are compiled out anyway) and still prints to serial. Each line is prefixed with uptime and local time when known.
   - Keep the INFO lines useful: one line per real event (start/stop and why, tank packet received with sensor + float levels, tank selected, BLE connect/auth/disconnect, schedule fired, OTA stage). Move anything per-byte or per-retry down to DEBUG so 8 KB covers hours, not seconds.
   - Write it to NVS only on a crash or watchdog (the next boot copies the ring to `tl_diag/log`), so normal logging causes no flash wear.
   - Fill the crash fields by wrapping the panic handler (`-Wl,--wrap=esp_panic_handler`). On the next boot, if the magic is set, copy it into NVS (`tl_diag/crash`) and log a CRASH event. **Needs checking on a real board** with a deliberate crash; if the wrap proves fragile, fall back to recording only the reset reason plus the log ring.
3. **New characteristic `Diag` (UUID `…0f…`)**, authed:
   - Write `[op]`: `0x01 GET page n`, `0x02 CLEAR`.
   - Read: `[ver][kind][page][pages][bytes…]` so the app pulls events, counters, crash record and log text in ≤ 180-byte pages.
   - Adding a characteristic → bump `TANKLINK_PROTO_MINOR` only.
4. **App**: `protocol.dart` decoder + `PumpSession.readDiagnostics()`, event code names in `util/diag_text.dart`, tests in `protocol_test.dart`. The report includes pump diagnostics when connected; a "Clear pump log" button after a successful send.
5. Optional small win: **Settings → Pump log** screen listing recent events in plain words, so users (and you on a support call) can read it without sending anything.

## Phase 3 — Tank diagnostics via LoRa (tank 0.4.0 + pump 0.15.0)

1. Append to the STATUS body (after `hw_rev`, per the append-only rule, no `TANKLINK_LORA_VER` bump): `reset_reason u8, boot_count u16, tx_attempts u16, ack_misses u16, last_err u8`. Tank keeps the counters in RTC memory (survives deep sleep) and NVS on change of `last_err` only.
2. Pump accepts longer packets, stores the latest per sensor in RAM, and adds a `kind = tank` page to `Diag`. Older tanks send the short packet; the pump shows "no diagnostics" for them (that is not compatibility code, just the missing bytes).
3. App shows them per sensor in the report.

## Phase 4 — later, only if needed

- **Core dumps** to a new `coredump` partition (fits in the free 384 KB after `ota_1`) for boards that get a USB `erase-flash` anyway, e.g. new builds. Full backtraces you can decode with `idf.py coredump-info`.
- **Move the report service to your own server** if reports get frequent enough that automatic crash decoding would save real time. Same `/v1/report` contract on the same `reports.` URL, so the app doesn't change.

## Docs and contracts to update

- `docs/PROTOCOL.md`: Diag characteristic and page layout; new STATUS fields.
- `docs/CONFIGURATION.md`: `tl_diag/*` NVS keys and sizes (check the 24 KB NVS partition still has room with `pump_history`).
- `docs/ERROR_CODES.md`: list of diag event codes.
- `AGENTS.md` shared-contracts table: add "Diag event codes" (pump `pump_diag.h` ↔ app `diag_text.dart`), the Diag UUID in all three UUID files, and the `/v1/report` body (`report_sender.dart` ↔ `report_worker/`). Add `report_worker/` to the code map and the `.elf` assets to the release checklist.

## Testing

- App: `flutter analyze`, `flutter test` (report builder, redaction, fingerprint, Diag decoding).
- Worker: `wrangler dev` locally against a test repo; send a new report, a duplicate (expect a comment, not a new issue), a too-big one and a wrong key.
- Firmware: compile-checked only. On real boards: force a panic with a debug-only Cmd (`0xD0`, compiled out of release builds), a watchdog, a brownout (motor start on weak supply), unplug the tank to trigger offline, interrupt an OTA; confirm each shows up in a report.

## Order and size

| Phase | Ships as | Rough size |
| --- | --- | --- |
| 1 | Report service + next app release | 2–2.5 days |
| 2 | Next pump + app releases + decode script | 2.5–3.5 days + board testing |
| 3 | Tank 0.4.0 + pump 0.15.0 + app | 1–2 days + board testing |
| 4 | Later | — |

## Where reports go

Into a private GitHub repo as issues, through the Cloudflare Worker above:

- One tap for the user, no account, no mail app.
- Duplicates are grouped by fingerprint, so one issue shows how many people hit the same error on the same version.
- Issues fit the existing workflow: GitHub notifications, `Fixes tanklink-reports#12` in commits, close on release.
- Free (Worker free tier, private repo), no upkeep, private.

Considered and not chosen: email (no grouping), GitHub issues opened by the user (needs an account, public), Sentry/Crashlytics (third party, no firmware logs), your own server now (about a day more plus upkeep; kept as the Phase 4 move).
