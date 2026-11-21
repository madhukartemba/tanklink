## Changes

- Alerts: the pump raises an alert when a fill stops because the tank is full, when auto-off stops a fill, when a power cut ends a fill, when the active tank's sensor goes out of range, and when a sensor's battery is low. It puts the alert in its Bluetooth advertisement for an hour, so a phone can show it even with the TankLink app closed, and keeps the last 8 in a log the app reads when it connects.
- Each alert carries how long the fill ran (or the battery level), so the notification can say more than "something happened".
- A signed alert key (made when the first phone pairs, replaced when phones are removed) lets the app check an alert really came from this pump.
- "Send a test alert" from the app raises a test alert.

Goes with app 1.11.0. Update the pump and the app together: this release changes the Bluetooth protocol (minor 6, fields appended). Each phone must connect to the pump once after updating to get the alert key. No wiring change, nothing to pair again.
