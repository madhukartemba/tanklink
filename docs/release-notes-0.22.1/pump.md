## Changes

- The pump's own firmware update now tries the download up to 3 times if the download server doesn't answer, instead of giving up after one try.
- The update is fetched from the TankLink service (`tanklink.madhukartemba.in`), not from GitHub's download host, which some networks don't reach. (This part is in the service and was already live; the firmware keeps working with it.)
- A little less logging noise during an update.

Goes with app 1.11.1. No protocol change, nothing to pair again, no wiring change.
