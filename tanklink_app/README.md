# TankLink app

Flutter client for simple BLE claim/pair with the C3 pump.

```bash
cd /Users/madhukartemba/Desktop/tanklink/tanklink_app
flutter pub get
flutter run
```

## Flow

1. Power unpaired pump (`TankLink-Pump` in serial: UNPAIRED).
2. **Add pump** → scan → tap device → Claim.
3. Home → **Connect** → ON/OFF (state only; relays stubbed).

Forget on phone does not unpair the C3 — erase-flash the pump to reclaim.
