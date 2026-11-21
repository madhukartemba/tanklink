## Changes

- The status light bar is now 13 LEDs (it was 11). The animations spread across the longer bar by themselves.
- The pump checks for a firmware update every 3 hours (it was 6). A check that fails is still retried after 15 minutes, doubling up to 3 hours.

Goes with app 1.15.1 (unchanged). No protocol change, nothing to pair again. **If your bar has 11 LEDs**, set `PUMP_NEOPIXEL_COUNT` back to 11 and build it yourself; this build drives 13.
