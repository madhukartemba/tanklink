#!/usr/bin/env bash
# Release any of pump, tank and app in one go, following the checklist in
# AGENTS.md: bump, commit, rebuild, verify, push, publish.
#
# Usage:
#   ./scripts/release.sh [--pump X.Y.Z] [--tank X.Y.Z] [--app X.Y.Z] \
#       --notes DIR [-m "Commit subject"] [--dry-run]
#
# DIR holds the release notes as pump.md, tank.md and app.md (one per
# component being released). Format: a short "## Changes" list, then which
# versions go together (see AGENTS.md).
#
# --dry-run bumps, builds and runs every check, then puts the version files
# back. Nothing is committed, pushed or published.
#
# Checks before anything is published:
#   - on main, clean tree, tags not taken, each version above the last release
#   - each binary contains its new version
#   - each sha256 differs from the previous release's manifest
#   - the APK is signed with the upload key and has the new version
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Upload key certificate (docs/app-release.md). Never publish another signer.
APP_CERT_SHA256="d4000075a2503d04c9d19c4e440dfd0656140c35379809290fdfa72167ecc3a1"

PUMP_VER="" TANK_VER="" APP_VER="" NOTES="" MESSAGE="" DRY_RUN=0

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pump) PUMP_VER="${2:?}"; shift 2 ;;
    --tank) TANK_VER="${2:?}"; shift 2 ;;
    --app) APP_VER="${2:?}"; shift 2 ;;
    --notes) NOTES="${2:?}"; shift 2 ;;
    -m|--message) MESSAGE="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$PUMP_VER$TANK_VER$APP_VER" ]] || die "nothing to release: pass --pump, --tank and/or --app"
[[ -n "$NOTES" && -d "$NOTES" ]] || die "--notes DIR is required"
NOTES="$(cd "$NOTES" && pwd)"

semver_ok() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# Highest released version for a tag prefix, or empty.
last_release() {
  gh release list --limit 200 --json tagName -q '.[].tagName' |
    sed -n "s/^$1//p" | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; } |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}
# True when $1 > $2.
ver_gt() {
  [[ "$1" != "$2" ]] &&
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$1" ]]
}
find_tool() {
  command -v "$1" 2>/dev/null ||
    find "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools \
      -name "$1" -type f 2>/dev/null | sort | tail -1
}

COMPONENTS=()
[[ -n "$PUMP_VER" ]] && COMPONENTS+=(pump)
[[ -n "$TANK_VER" ]] && COMPONENTS+=(tank)
[[ -n "$APP_VER" ]] && COMPONENTS+=(app)

ver_of() { case "$1" in pump) echo "$PUMP_VER" ;; tank) echo "$TANK_VER" ;; app) echo "$APP_VER" ;; esac; }
tag_of() { echo "$1-v$(ver_of "$1")"; }

# ---------------------------------------------------------------- preflight
step "Checking"
command -v gh >/dev/null || die "gh (GitHub CLI) is required"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "switch to main first"
git diff --quiet && git diff --cached --quiet || die "commit or stash your changes first"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
  die "main is not in sync with origin/main (pull or push first)"

for c in "${COMPONENTS[@]}"; do
  v="$(ver_of "$c")"
  semver_ok "$v" || die "$c version must be X.Y.Z, got $v"
  [[ -f "$NOTES/$c.md" ]] || die "missing release notes $NOTES/$c.md"
  tag="$(tag_of "$c")"
  if gh release view "$tag" >/dev/null 2>&1 || git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "$tag already exists"
  fi
  prev="$(last_release "$c-v")"
  if [[ -n "$prev" ]] && ! ver_gt "$v" "$prev"; then
    die "$c $v is not above the last release $prev"
  fi
  echo "  $c: ${prev:-none} -> $v"
done

if [[ -n "$PUMP_VER$TANK_VER" ]]; then
  IDF_PATH="${IDF_PATH:-$HOME/esp/esp-idf}"
  [[ -f "$IDF_PATH/export.sh" ]] || die "ESP-IDF not found at $IDF_PATH"
  # Boards only take updates signed with this key (sdkconfig.defaults).
  [[ -f keys/firmware_signing_key.pem ]] ||
    die "keys/firmware_signing_key.pem is missing: boards would refuse the update (docs/firmware-build-setup.md#signing-key)"
  if [[ -z "${IDF_PYTHON_ENV_PATH:-}" ]]; then
    IDF_PYTHON_ENV_PATH="$(ls -d "$HOME"/.espressif/python_env/idf6.1* 2>/dev/null | head -1 || true)"
  fi
  export IDF_PATH IDF_PYTHON_ENV_PATH
fi
if [[ -n "$APP_VER" ]]; then
  command -v flutter >/dev/null || die "flutter is required"
  [[ -f tanklink_app/android/key.properties ]] ||
    die "tanklink_app/android/key.properties is missing: the APK would not be signed with the upload key"
  APKSIGNER="$(find_tool apksigner)"
  [[ -n "$APKSIGNER" ]] || die "apksigner not found (Android build-tools)"
  AAPT2="$(find_tool aapt2)"
fi

# ---------------------------------------------------------------- bump
VERSION_FILES=()
set_c_version() { # file prefix X.Y.Z
  local file="$1" p="$2" ma mi pa
  IFS=. read -r ma mi pa <<<"$3"
  sed -i '' -E \
    -e "s/^(#define ${p}_MAJOR )[0-9]+/\\1$ma/" \
    -e "s/^(#define ${p}_MINOR )[0-9]+/\\1$mi/" \
    -e "s/^(#define ${p}_PATCH )[0-9]+/\\1$pa/" "$file"
  VERSION_FILES+=("$file")
}

restore_versions() {
  if [[ ${#VERSION_FILES[@]} -gt 0 ]]; then
    git checkout -- "${VERSION_FILES[@]}"
  fi
}
if [[ $DRY_RUN -eq 1 ]]; then
  trap restore_versions EXIT
fi

step "Bumping versions"
[[ -n "$PUMP_VER" ]] && set_c_version pump_node/main/tanklink_uuid.h TANKLINK_FW "$PUMP_VER"
[[ -n "$TANK_VER" ]] && set_c_version tank_node/main/tank_version.h TANK_FW "$TANK_VER"
if [[ -n "$APP_VER" ]]; then
  build_no="$(sed -n -E 's/^version: [0-9.]+\+([0-9]+)$/\1/p' tanklink_app/pubspec.yaml)"
  [[ -n "$build_no" ]] || die "could not read the build number in pubspec.yaml"
  APP_BUILD=$((build_no + 1))
  sed -i '' -E "s/^version: .*/version: $APP_VER+$APP_BUILD/" tanklink_app/pubspec.yaml
  VERSION_FILES+=(tanklink_app/pubspec.yaml)
fi
git --no-pager diff --stat

if [[ $DRY_RUN -eq 0 ]]; then
  if [[ -z "$MESSAGE" ]]; then
    parts=()
    [[ -n "$PUMP_VER" ]] && parts+=("pump $PUMP_VER")
    [[ -n "$TANK_VER" ]] && parts+=("tank $TANK_VER")
    [[ -n "$APP_VER" ]] && parts+=("app $APP_VER")
    MESSAGE="Release $(IFS=,; echo "${parts[*]}" | sed 's/,/, /g')."
  fi
  git add "${VERSION_FILES[@]}"
  git commit -q -m "$MESSAGE"
  echo "  committed: $MESSAGE"
fi

# ---------------------------------------------------------------- build
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tanklink-release.XXXXXX")"

build_fw() { # pump|tank
  step "Building $1 firmware"
  # Full log to a file; the tail only. pipefail still catches a failed build.
  (cd "${1}_node" && bash -c '. "$IDF_PATH/export.sh" >/dev/null 2>&1 && idf.py build' \
    >"$STAGE/$1-build.log" 2>&1) || { tail -30 "$STAGE/$1-build.log"; die "$1 build failed"; }
  grep -E "Project build complete" "$STAGE/$1-build.log" | head -1 || true
}

check_sha_changed() { # component sha prefix manifest_name
  local prev old
  prev="$(last_release "$3")"
  [[ -n "$prev" ]] || return 0
  mkdir -p "$STAGE/prev-$1"
  gh release download "$3$prev" -p "$4" -D "$STAGE/prev-$1" --clobber >/dev/null
  old="$(sed -n -E 's/.*"sha256": "([0-9a-f]+)".*/\1/p' "$STAGE/prev-$1/$4")"
  [[ "$old" != "$2" ]] || die "$1 binary is identical to $3$prev: rebuild did not pick up the new version"
  echo "  sha256 differs from $3$prev"
}

for fw in pump tank; do
  v="$(ver_of "$fw")"
  [[ -n "$v" ]] || continue
  build_fw "$fw"
  mkdir -p "$STAGE/$fw"
  ./scripts/make_firmware_manifest.sh "$fw" "$v" "$STAGE/$fw" >/dev/null # also checks the version string
  cp "${fw}_node/build/${fw}_node.bin" "$STAGE/$fw/"
  sha="$(shasum -a 256 "$STAGE/$fw/${fw}_node.bin" | awk '{print $1}')"
  echo "  ${fw}_node.bin contains $v, sha256 $sha"
  check_sha_changed "$fw" "$sha" "$fw-v" firmware-manifest.json
done

if [[ -n "$APP_VER" ]]; then
  step "Building app"
  (cd tanklink_app && flutter build apk --release 2>&1 | awk 'END {print}')
  APK=tanklink_app/build/app/outputs/flutter-apk/app-release.apk
  cert="$("$APKSIGNER" verify --print-certs "$APK" | sed -n 's/.*certificate SHA-256 digest: //p' | awk 'NR == 1')"
  [[ "$cert" == "$APP_CERT_SHA256" ]] || die "APK signer $cert is not the upload key"
  echo "  signed with the upload key"
  if [[ -n "${AAPT2:-}" ]]; then
    # awk reads to the end: head would SIGPIPE aapt2 and trip pipefail.
    badge="$("$AAPT2" dump badging "$APK" 2>/dev/null | awk 'NR == 1')"
    [[ "$badge" == *"versionCode='$APP_BUILD'"* && "$badge" == *"versionName='$APP_VER'"* ]] ||
      die "APK reports the wrong version: $badge"
    echo "  version $APP_VER ($APP_BUILD)"
  fi
  mkdir -p "$STAGE/app"
  cp "$APK" "$STAGE/app/TankLink.apk"
  ./scripts/make_app_manifest.sh "$APP_VER" "$STAGE/app/TankLink.apk" "$STAGE/app" >/dev/null
  sha="$(shasum -a 256 "$STAGE/app/TankLink.apk" | awk '{print $1}')"
  check_sha_changed app "$sha" app-v app-manifest.json
fi

if [[ $DRY_RUN -eq 1 ]]; then
  step "Dry run passed. Assets are in $STAGE; version files restored."
  exit 0
fi

# ---------------------------------------------------------------- publish
step "Pushing"
git push -q origin main
SHA="$(git rev-parse HEAD)"
echo "  $SHA"

publish() { # component title asset...
  local c="$1" title="$2"
  shift 2
  local latest=--latest=false
  [[ "$c" == app ]] && latest=--latest
  gh release create "$(tag_of "$c")" --target "$SHA" --title "$title" \
    --notes-file "$NOTES/$c.md" "$latest" "$@"
}

step "Publishing"
# Firmware first, so the app release ends up marked Latest.
[[ -n "$PUMP_VER" ]] && publish pump "Pump firmware $PUMP_VER" \
  "$STAGE/pump/pump_node.bin" "$STAGE/pump/firmware-manifest.json"
[[ -n "$TANK_VER" ]] && publish tank "Tank firmware $TANK_VER" \
  "$STAGE/tank/tank_node.bin" "$STAGE/tank/firmware-manifest.json"
if [[ -n "$APP_VER" ]]; then
  publish app "TankLink app $APP_VER" "$STAGE/app/TankLink.apk" "$STAGE/app/app-manifest.json"
  # The install QR (tanklink.madhukartemba.in/app) finds this release itself.
fi

step "Done"
