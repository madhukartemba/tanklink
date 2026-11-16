#!/usr/bin/env bash
# Usage: ./scripts/make_app_manifest.sh 1.0.1
# Build first: cd tanklink_app && flutter build apk --release
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:?version required, e.g. 1.0.1}"
BIN="${2:-$ROOT/tanklink_app/build/app/outputs/flutter-apk/app-release.apk}"
OUT_DIR="${3:-$ROOT/tanklink_app/build}"
if [[ ! -f "$BIN" ]]; then
  echo "Missing $BIN — run: cd tanklink_app && flutter build apk --release" >&2
  exit 1
fi
SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
MANIFEST="$OUT_DIR/app-manifest.json"
cat >"$MANIFEST" <<EOF
{
  "component": "tanklink_app",
  "version": "$VER",
  "sha256": "$SHA",
  "min_app": "1.0.0"
}
EOF
echo "Wrote $MANIFEST"
echo "Bin: $BIN"
echo "Release asset name: TankLink.apk (copy/rename for GitHub)"
echo "sha256: $SHA"