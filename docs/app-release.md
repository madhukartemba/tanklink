# TankLink app releases (`app-v*`)

Android sideload + in-app update (no Play Store required). Firmware releases remain `pump-v*` / `tank-v*`.

## Signing (one-time)

> **Current state:** no `key.properties` exists, so releases so far are signed with the build machine's **debug key** (cert SHA-256 `4eaeb0bf…afa381`). Keep building on that machine, or existing installs must uninstall before they can update. Setting up the upload key below changes the signer, so plan that switch as a one-time reinstall.

```bash
cd tanklink_app/android
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp key.properties.example key.properties
# Edit key.properties — never commit key.properties or *.jks
```

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

The app lists releases via the GitHub API, picks the newest `app-v*` tag, verifies `app-manifest.json` **sha256**, downloads **TankLink.apk**, and opens the system install UI.

## Versioning

- **`pubspec.yaml`**: `version: 1.0.1+2` (`+` = Android `versionCode`, must increase every upload).
- Manifest **`version`** must match the tag semver (`app-v1.0.1` → `1.0.1`).