#!/usr/bin/env bash
# Write firmware-manifest.json for a pump or tank build.
#
# Usage: ./scripts/make_firmware_manifest.sh pump|tank X.Y.Z [out_dir]
#
# The board revision and protocol major come from the build itself
# (build/config/sdkconfig.h and the BLE header), so the manifest always
# describes the binary next to it. The app only offers a release whose
# proto_major matches its own and whose hw_revs list the connected board.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${1:?node required: pump or tank}"
VER="${2:?version required, e.g. 0.12.0}"

case "$NODE" in
  pump)
    PROJ="$ROOT/pump_node"
    HW_KEY="CONFIG_PUMP_HW_REV"
    PROTO_HDR="$PROJ/main/tanklink_uuid.h"
    ;;
  tank)
    PROJ="$ROOT/tank_node"
    HW_KEY="CONFIG_TANK_HW_REV"
    PROTO_HDR="$PROJ/main/tanklink_ble_uuid.h"
    ;;
  *)
    echo "First argument must be pump or tank" >&2
    exit 1
    ;;
esac

BIN="$PROJ/build/${NODE}_node.bin"
SDKCONFIG_H="$PROJ/build/config/sdkconfig.h"
OUT_DIR="${3:-$PROJ/build}"

if [[ ! -f "$BIN" || ! -f "$SDKCONFIG_H" ]]; then
  echo "Missing $BIN — run idf.py build first" >&2
  exit 1
fi
if ! strings "$BIN" | grep -x "$VER" >/dev/null; then
  echo "$BIN does not contain version $VER. Bump the version and rebuild." >&2
  exit 1
fi

HW_REV="$(awk -v k="$HW_KEY" '$1 == "#define" && $2 == k {print $3}' "$SDKCONFIG_H")"
PROTO_MAJOR="$(awk '$1 == "#define" && $2 == "TANKLINK_PROTO_MAJOR" {print $3}' "$PROTO_HDR")"
if [[ -z "$HW_REV" || -z "$PROTO_MAJOR" ]]; then
  echo "Could not read $HW_KEY or TANKLINK_PROTO_MAJOR" >&2
  exit 1
fi

SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
MANIFEST="$OUT_DIR/firmware-manifest.json"
cat >"$MANIFEST" <<JSON
{
  "component": "${NODE}_node",
  "version": "$VER",
  "sha256": "$SHA",
  "proto_major": $PROTO_MAJOR,
  "hw_revs": [$HW_REV]
}
JSON
echo "Wrote $MANIFEST"
cat "$MANIFEST"
