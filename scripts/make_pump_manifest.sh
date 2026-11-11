#!/usr/bin/env bash
# Usage: ./scripts/make_pump_manifest.sh 0.4.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:?version required, e.g. 0.4.0}"
BIN="$ROOT/pump_node/build/pump_node.bin"
OUT_DIR="${2:-$ROOT/pump_node/build}"
if [[ ! -f "$BIN" ]]; then
  echo "Missing $BIN — run idf.py build first" >&2
  exit 1
fi
SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
MANIFEST="$OUT_DIR/firmware-manifest.json"
cat >"$MANIFEST" <<EOF
{
  "component": "pump_node",
  "version": "$VER",
  "sha256": "$SHA",
  "min_app": "1.0.0"
}
EOF
echo "Wrote $MANIFEST"
echo "Bin: $BIN"
echo "sha256: $SHA"
