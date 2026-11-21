## Changes

- While the pump updates its own firmware (or a phone sends one), it no longer starts, opens its pairing window, or resets. A start press is no longer an error: there is no red light code, and the update animation stays on. Stop always works.
- The update animation now shows for the whole install, including the secure-connection setup and the pauses between download tries, and no longer flashes red between tries.
- After tank-sensor pairing during an update, the light goes back to the update animation instead of the idle glow.
- A few small clean-ups in the update code.

Goes with app 1.12.0. No protocol change, nothing to pair again, no wiring change.
