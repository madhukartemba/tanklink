## Changes

- The pump keeps its own name (up to 24 characters), so every phone that has the pump shows the same one. A phone that renames it writes the new name to the pump, and other connected phones pick it up straight away. Factory reset clears the name.
- The Settings characteristic now notifies when a setting or the name changes, so a second phone sees the change without reconnecting.

Goes with app 1.15.0. This release changes the Bluetooth protocol (minor 8, fields appended to Settings): update the pump and the app together. A pump that hasn't been named yet shows each phone's saved name until someone renames it. No wiring change, nothing to pair again.
