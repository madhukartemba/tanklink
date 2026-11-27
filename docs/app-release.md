# TankLink app releases (`app-v*`)

Android sideload + in-app update (no Play Store required). Firmware releases remain `pump-v*` / `tank-v*`.

## Signing (one-time)

Release builds must be signed with the upload key. `flutter build apk --release` fails without `android/key.properties`.

```bash
cd tanklink_app/android
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp key.properties.example key.properties
# Edit key.properties — never commit key.properties or *.jks
```

The upload key exists on the release machine: `android/app/upload-keystore.jks`, passwords in `android/key.properties`, certificate SHA-256 `d4000075a2503d04c9d19c4e440dfd0656140c35379809290fdfa72167ecc3a1`.

Back up `upload-keystore.jks` and its passwords somewhere safe. Android only installs an update signed with the same key as the installed app, so losing the key means every phone has to uninstall and pair again.

> Releases up to app 1.2.0 are signed with this build machine's debug key (cert SHA-256 `4eaeb0bf…afa381`), built with `--android-project-arg=allowDebugSigning=true`. The first release signed with the upload key cannot update those installs: uninstall the old app once, install the new one, and pair the pump again.

For a build on a machine without the key: `flutter build apk --release --android-project-arg=allowDebugSigning=true`. Only publish one from the machine whose debug key signed the earlier releases, and check the signer below.

Check the signer before publishing:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk | grep SHA-256
```

## The release script

`scripts/release.sh --app X.Y.Z --notes DIR` does everything below, including the signer check. See [`firmware-release.md`](firmware-release.md#the-release-script).

## Build and manifest

```bash
cd tanklink_app
flutter build apk --release
cd ..
./scripts/make_app_manifest.sh 1.0.1
cp tanklink_app/build/app/outputs/flutter-apk/app-release.apk /tmp/TankLink.apk
```

## GitHub release

1. Tag **`app-v1.0.1`** on `main` (after merging app update feature).
2. Attach:
   - **`TankLink.apk`** (release-signed APK)
   - **`app-manifest.json`** from `tanklink_app/build/app-manifest.json`
3. Mark as **latest** production release (not draft/prerelease).

### Install QR code

Use **[`docs/app-qr.svg`](app-qr.svg)**: `https://tanklink.madhukartemba.in/app`. The report service ([`report_worker/`](../report_worker/)) answers with a redirect to `TankLink.apk` of the newest `app-v*` release, so it needs no upload step and the code never has to change. If the service can't read the release list it redirects to the GitHub releases page. Version 3, medium error correction, 4-module quiet zone.

### Pump NFC tag

An NFC sticker on the pump holds `https://tanklink.madhukartemba.in/pump/<serial>` (the pump's `#A1B2`, or just `/pump` to open the app on whichever pump it last used). With the app installed, a tap opens the app on that pump (Android App Links, verified through the report service's `/.well-known/assetlinks.json`); without it, the tap opens the website. Write it as a single URI record (NFC Tools: "Add a record → URL"), then lock the tag. Use an on-metal tag on a metal enclosure. A changed upload key needs the new SHA-256 in `ASSET_LINKS` in `report_worker/src/index.js`.

The app lists releases through the report service (`GET /v1/releases` in [`report_worker/`](../report_worker/), a 10-minute cached copy of the GitHub API list; GitHub directly if it can't be reached), picks the newest `app-v*` tag, verifies `app-manifest.json` **sha256**, downloads **TankLink.apk**, and opens the system install UI. A just-published release can take up to ~10 minutes to appear because of that cache; `scripts/release.sh` ends by running `scripts/refresh_worker.sh`, and you can run it yourself any time.

## Versioning

- **`pubspec.yaml`**: `version: 1.0.1+2` (`+` = Android `versionCode`, must increase every upload).
- Manifest **`version`** must match the tag semver (`app-v1.0.1` → `1.0.1`).