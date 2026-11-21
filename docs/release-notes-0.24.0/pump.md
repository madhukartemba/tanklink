## Changes

- The pump checks for a firmware update every 6 hours (it used to be once a day). A check that fails, for example with no internet, is retried after 15 minutes, then 30, 60 and so on up to 6 hours, instead of waiting a full day.
- A check that falls due while the pump is running, an update is being written or a pairing window is open waits a couple of minutes. "Check now" is refused in those states, and the app says why.
- The pump reports when it last checked and how big the update it found is, so the app can show "checked 3 h ago" and a progress bar for an update it didn't start.
- Alerts: the pump makes its alert key the first time a signed-in phone asks for it, instead of at start-up.
- The update code is split into a network part and a policy part (no change in behaviour).

Goes with app 1.13.0. This release changes the Bluetooth protocol (minor 7, fields appended to the Wi-Fi status): update the pump and the app together. An older pump won't connect to the new app until it is updated, and an older app can't read the new status. No wiring change, nothing to pair again.
