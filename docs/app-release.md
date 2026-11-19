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

`scripts/release.sh --app X.Y.Z --notes DIR` does everything below, including the signer check and the `app-latest` upload. See [`firmware-release.md`](firmware-release.md#the-release-script).

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
4. Replace the APK on the fixed **`app-latest`** release so the QR download stays current. Do not mark that release as Latest (`--latest=false` is already set). The in-app updater only reads `app-v*` tags, so this tag is ignored there.

```bash
gh release upload app-latest /tmp/TankLink.apk --clobber
```

QR and direct download (always the file last uploaded to `app-latest`):

`https://github.com/madhukartemba/tanklink/releases/download/app-latest/TankLink.apk`

The QR image is [`docs/app-latest-qr.svg`](app-latest-qr.svg). It is the smallest symbol that URL can make (version 5, low error correction, 4-module quiet zone).

The app lists releases via the GitHub API, picks the newest `app-v*` tag, verifies `app-manifest.json` **sha256**, downloads **TankLink.apk**, and opens the system install UI.

## Versioning

- **`pubspec.yaml`**: `version: 1.0.1+2` (`+` = Android `versionCode`, must increase every upload).
- Manifest **`version`** must match the tag semver (`app-v1.0.1` → `1.0.1`).