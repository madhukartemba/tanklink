## Changes

- The tank always gets back to sleep by itself and never needs its reset button: every sleep now also has a timer wake (daily when not set up).
- A button that is held or stuck when the tank goes to sleep is ignored until it is released, so it can't start pairing by itself and drop the tank from its pump.
- A float that keeps flapping no longer keeps waking the radio; the regular check-in still reports it.
- After a crash or a brownout the tank rests before trying again, longer each time it repeats, so a fault can't empty the battery.
- Check-ins the pump doesn't answer no longer blink an error code, which saves battery. Codes still show after a button press.
- Updates to the tank start faster.

Goes with pump 0.28.0 and app 1.16.0. No layout change: nothing to pair or set again.
