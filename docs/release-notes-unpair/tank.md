## Changes

- When a tank that was paired goes into pairing mode, it now tells the pump it was paired with that it has been removed. The pump drops the sensor, instead of showing it offline for ever. The notice goes out after pairing ends (paired with a new pump, cancelled or timed out), tagged with the old key, and is tried twice at most. Pairing the tank with the same pump again keeps that pump's tank names, schedules and settings.

Works best with pump 0.25.0: an older pump ignores the notice, so nothing breaks, but the sensor stays listed until you remove it in the app. No wiring change, nothing to pair again.
