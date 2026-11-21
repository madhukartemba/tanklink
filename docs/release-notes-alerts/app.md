## Changes

- Pump alerts with the app closed (Android 12 and later): tank full, auto-off, a power cut during a fill, a tank sensor out of range, and a low sensor battery. Notifications say what happened and how long the fill ran, with litres when the pump's flow is set, for example "Tank 1 is full. The pump stopped after about 40 minutes, about 480 litres."
- Alerts are on by default. The app explains why it needs notification and Nearby devices permission, and asks once.
- Problems that need action (power cut, auto-off, sensor out of range) use a louder notification channel than "tank full" and battery reminders.
- No notification while the app is on screen, since the app already shows it. A missed alert is added to the next one ("And 1 more").
- Settings → Alerts: a switch per alert type, a test button, and a shortcut to the phone's battery settings (some phones stop background apps until you allow it).

Goes with pump 0.22.0. Update both. Alerts only work while the phone is within Bluetooth range of the pump, and stop if the app is force-stopped until it is opened again.
