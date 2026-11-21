#!/usr/bin/env bash
# Make the report service forget its cached release list and fetch it again,
# so a release you just published (or deleted) shows up now, not within ~10
# minutes. The key is in report_worker/.refresh_key (gitignored) or in the
# TANKLINK_REFRESH_KEY environment variable. See report_worker/README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${TANKLINK_REFRESH_KEY:-}"
[[ -z "$KEY" && -f "$ROOT/report_worker/.refresh_key" ]] && KEY="$(tr -d '\n' <"$ROOT/report_worker/.refresh_key")"
[[ -n "$KEY" ]] || { echo "No key: put it in report_worker/.refresh_key or TANKLINK_REFRESH_KEY" >&2; exit 1; }
HOST="${TANKLINK_HOST:-https://tanklink.madhukartemba.in}"
curl -fsS -X POST -H "x-refresh-key: $KEY" "$HOST/v1/refresh"
echo
