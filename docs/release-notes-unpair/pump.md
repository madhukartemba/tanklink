## Changes

- The pump removes a tank sensor when the tank tells it over LoRa that it was removed (the tank went into pairing mode). It checks the notice is genuine and recent with the link key it shares with that tank, then removes the sensor the way *Unpair* in the app does. It won't do it while the pump is filling that sensor's tank; remove it from the app then.

Works with tank 0.5.0. A tank on older firmware doesn't send the notice, so nothing changes for it. No protocol change for the app, nothing to pair again, no wiring change. The app is unchanged.
