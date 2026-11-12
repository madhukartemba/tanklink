# Bare XIAO ESP32-C3 deep-sleep sanity

Timer-only deep sleep (no BLE / LoRa). Use to measure board floor current on **BAT±** with USB unplugged (~40–50 µA on a genuine XIAO C3).

```bash
. "$HOME/esp/esp-idf/export.sh"
cd tools/xiao_deep_sleep
idf.py set-target esp32c3 build
idf.py -p /dev/cu.usbmodemXXXX flash
```

Awake ~15 s, then sleeps for 60 s (repeats on wake).
