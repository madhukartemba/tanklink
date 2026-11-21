## Changes

- Fixes the app staying on "Updating pump…" after the pump had updated itself. A pump that restarts after its own update now ends the update, and the app checks that the version really changed.
- If the pump can't download an update itself, the dialog offers "Send from this phone" over Wi-Fi, and says so in plain words ("The pump couldn't reach the download server").
- A Wi-Fi connection that Android drops no longer shows up as an uncaught error, and a failed write can't leave later requests stuck.

Goes with pump 0.22.1.
