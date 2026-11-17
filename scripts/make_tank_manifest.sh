#!/usr/bin/env bash
# Usage: ./scripts/make_tank_manifest.sh X.Y.Z [out_dir]
exec "$(dirname "$0")/make_firmware_manifest.sh" tank "$@"
