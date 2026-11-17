#!/usr/bin/env bash
# Usage: ./scripts/make_pump_manifest.sh X.Y.Z [out_dir]
exec "$(dirname "$0")/make_firmware_manifest.sh" pump "$@"
