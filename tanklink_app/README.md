# TankLink app

Flutter app for the TankLink pump: claim/pair over BLE, pump on/off, settings, fill schedules, tank pairing, and over-the-air updates for the app, pump, and tank.

```bash
cd tanklink_app
flutter pub get
flutter run
```

Checks: `flutter analyze` and `flutter test`. Release builds: [`docs/app-release.md`](../docs/app-release.md).

## Layout

| Folder | What's there |
| --- | --- |
| `lib/ble/` | `pump_session.dart` (BLE connection, auth, all payload encode/decode) and `tanklink_uuids.dart` (must match the firmware headers) |
| `lib/screens/` | Home, pump list, add pump, settings, starter, schedules, tank pairing, error codes |
| `lib/update/` | GitHub Releases lookup (highest semver per tag prefix), sha256 check, APK install, pump/tank BLE OTA |
| `lib/widgets/` | Slide-to-start control |

Byte layouts: [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

## Flow

1. Hold the pump button ~5 s to open the BLE pairing window.
2. **Add pump** → scan → tap the device → Claim. The app stores the token.
3. Home → slide to start, or tap to stop. The pump drives the starter relays.

Forget on the phone does not unpair the pump. Use **Unpair** in settings, or factory reset the pump (hold the button ~15 s).
