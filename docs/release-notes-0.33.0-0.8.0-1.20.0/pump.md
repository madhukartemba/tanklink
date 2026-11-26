## Changes

- Tank updates: choose how often the tank sensors send the tank level, from the app (Tank sensors → Tank updates). The pump sends the interval to every sensor with its next reply; default 5 minutes.
- "Out of range" now follows that interval: a sensor counts as offline after 2.5 missed updates (at least 30 seconds).

Goes with tank 0.8.0 and app 1.20.0. A tank on older firmware keeps updating every 5 minutes, so update the tanks before picking a shorter interval, or they show as out of range. Nothing to pair again, no wiring change.
