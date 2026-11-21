## Changes

- Optional Wi-Fi: the pump joins a 2.4 GHz home network, set up from the app over Bluetooth. Without a saved network nothing changes.
- The app can control the pump over Wi-Fi (same screens and features) and falls back to Bluetooth.
- The pump sets its clock from the internet when on Wi-Fi (the app sends the time zone with each sync).
- The pump checks daily for a new version and can download and install it itself; an optional setting installs it automatically when the pump is idle and no fill is planned.
- Firmware updates sent from the phone over Wi-Fi are much faster than over Bluetooth.

Goes with app 1.10.0. Update the pump and the app together: this release changes the Bluetooth protocol (minor 5, fields appended). No wiring change. Wi-Fi is 2.4 GHz only, and the first build with Wi-Fi is about 1.5 MB, so keep an eye on the OTA slot (1.75 MB).
