# Build and flash setup (pump, tank, app)

Setting up a computer to build and flash the pump and tank firmware and build the Android app. Settings and pins are in [`CONFIGURATION.md`](CONFIGURATION.md). Publishing releases is in [`firmware-release.md`](firmware-release.md) and [`app-release.md`](app-release.md).

Checked on macOS with **ESP-IDF v6.1.0** (tag `v6.1`, commit `fff9895c`) and **Flutter 3.50** with **JDK 17**. Linux steps are the same except for the install packages.

## Quick reference

Once everything is installed:

```bash
. "$HOME/esp/esp-idf/export.sh"                 # every new terminal
cd pump_node && idf.py build                     # or tank_node
idf.py -p /dev/cu.usbmodemXXXX flash monitor     # Ctrl+] quits the monitor
```

```bash
cd tanklink_app && flutter pub get && flutter build apk --release
```

| Task | Command (in `pump_node/` or `tank_node/`) |
| --- | --- |
| Build | `idf.py build` |
| Flash app + bootloader + partition table (keeps pairing) | `idf.py -p PORT flash` |
| Flash and watch the log | `idf.py -p PORT flash monitor` |
| Log only | `idf.py -p PORT monitor` |
| Wipe everything (pairing, settings, schedules) then flash | `idf.py -p PORT erase-flash flash` |
| Change build options | `idf.py menuconfig` (see [`CONFIGURATION.md`](CONFIGURATION.md)) |
| Start clean after an IDF or option mess | `idf.py fullclean` then `idf.py build` |

## 1. Install the tools

You need:

- **Git**
- **CMake** and **Ninja**
- **Python 3.10 or newer** (the ESP-IDF installer sets up its own Python environment)
- A **USB cable** that carries data, not just power

On macOS with Homebrew:

```bash
brew install cmake ninja dfu-util
```

On Ubuntu/Debian:

```bash
sudo apt-get install git wget flex bison gperf python3 python3-pip python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
```

## 2. Install ESP-IDF v6.1

Use the official ESP-IDF at a fixed version. The version matters because the pump's dependency lock is built against v6.1.

```bash
mkdir -p ~/esp
cd ~/esp
git clone -b v6.1 --recursive https://github.com/espressif/esp-idf.git
cd ~/esp/esp-idf
./install.sh esp32c3
```

Each new terminal must load ESP-IDF before you build:

```bash
. "$HOME/esp/esp-idf/export.sh"
idf.py --version
```

You should see `ESP-IDF v6.1`. If not, check `git -C ~/esp/esp-idf describe --tags`.

## 3. Get the code

```bash
git clone git@github.com:madhukartemba/tanklink.git
cd tanklink
```

**You don't need to clone PixelEngine.** The pump build downloads it from GitHub, pinned to a fixed commit in [`pump_node/main/idf_component.yml`](../pump_node/main/idf_component.yml).

### Signing key

Every firmware build is signed, and a board only accepts an update over BLE if it is signed with the same key as the firmware it runs. The key is `keys/firmware_signing_key.pem` at the repo root (gitignored). Both pump and tank use it. The build fails without it.

Make it once:

```bash
. "$HOME/esp/esp-idf/export.sh"
mkdir -p keys
espsecure generate-signing-key --version 2 --scheme rsa3072 keys/firmware_signing_key.pem
```

**Back it up somewhere safe and never commit it.** If it is lost, boards can only be updated over USB. If it leaks, anyone with a board's sign-in token can flash their own firmware: make a new key and flash every board over USB.

This is signature checking on update only. No eFuses are burned and the bootloader doesn't check, so USB flashing works as before. The first board update to signed firmware works over BLE from the app, because the old firmware doesn't check.

After the key or the signing settings change, delete the local `sdkconfig` (or run `idf.py fullclean`) so it picks up `sdkconfig.defaults`.

## 4. Build the tank

```bash
. "$HOME/esp/esp-idf/export.sh"
cd tank_node
idf.py build
```

## 5. Build the pump

```bash
. "$HOME/esp/esp-idf/export.sh"
cd pump_node
idf.py set-target esp32c3    # first build on a new checkout only
idf.py build
```

The first pump build downloads PixelEngine and the LED strip component. It needs internet access and can take a few minutes.

> Run `set-target` only once. It deletes `sdkconfig` and regenerates it from `sdkconfig.defaults`, so anything changed only in `menuconfig` is lost.

Output: `build/pump_node.bin` (or `build/tank_node.bin`). This is the file that goes into a release and that the app flashes over BLE.

## 6. Flash over USB

Plug in one board at a time and find its port:

- macOS: `ls /dev/cu.usbmodem*`
- Linux: `ls /dev/ttyACM*`
- Windows: check the COM port in Device Manager

Then flash and open the serial monitor:

```bash
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

`flash` writes the bootloader, the partition table, the OTA selector, and the app into the first OTA slot. It **does not** erase NVS, so pairing, settings, schedules and the tank binding are kept.

If the board doesn't enter flash mode: hold **BOOT**, tap **RESET**, release **BOOT**. On the tank, the RA-02's MISO pin will block flash mode if it's on GPIO9. See [`tank_node/README.md`](../tank_node/README.md).

**Wipe the board** only when you need a clean start or after a partition-table change. This clears pairing, so re-pair in the app afterwards:

```bash
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash
```

### USB or over the air?

| | USB (`idf.py flash`) | BLE OTA (from the app) |
| --- | --- | --- |
| Needs | Board on the computer | Paired phone near the board; pump must be **off** |
| Use for | First install, partition-table changes, development | Updates to installed boards |
| Source of the image | Your local build | A GitHub release (`pump-v*` / `tank-v*`) |
| Tank | Board on USB | Short-press the tank button to open its ~10 s BLE window, then start the update in the app |

## 7. Read the serial log

`idf.py -p PORT monitor` shows the live log. **Ctrl+]** quits. A reset prints the boot sequence, which is the quickest way to check hardware. Look for lines like:

```
I (157) RTC: DS3231 found on SDA=7 SCL=6
I (167) CLOCK: clock from RTC 2026-11-17 13:28:20
I (167) LORA: tank last heard 13 s ago (restored, online) flags=0x03
I (197) LORA: listening for tank @ 433000000 Hz
I (317) PUMP: PAIRED — advertising as TankLink-E5FE
```

A `W`/`E` line on `RTC`, `LORA` or `SX1278` usually means wiring. The pump soft-fails each missing part and keeps running.

The tank sleeps most of the time, so its USB port disappears. To watch it, set `TANK_DEMO_NO_SLEEP=y` (see [`CONFIGURATION.md`](CONFIGURATION.md)), or press its button and open the monitor straight away.

**From a script or a non-interactive shell** (no TTY, so `idf.py monitor` won't start): use pyserial from the ESP-IDF Python environment. **Open the port with DTR and RTS low.** On macOS, opening it with the default settings can hold the chip in reset.

```python
import serial, time
s = serial.Serial()
s.port, s.baudrate, s.timeout = "/dev/cu.usbmodemXXXX", 115200, 0.2
s.dtr = False; s.rts = False
s.open()
s.rts = True; time.sleep(0.2); s.rts = False   # reset, to capture the boot log
while True:
    print(s.read(4096).decode(errors="replace"), end="")
```

## 8. Build the app

Install **Flutter 3.50** (stable), **JDK 17**, and the **Android SDK** (Android Studio, or Homebrew `android-commandlinetools`). Then:

```bash
flutter doctor              # fix anything it flags for Android
cd tanklink_app
flutter pub get
flutter analyze             # should report no errors
flutter run                 # on a phone with USB debugging
flutter build apk --release # → build/app/outputs/flutter-apk/app-release.apk
```

The app needs a real phone with Bluetooth. Emulators can't reach the pump. Minimum Android is 7.0 (API 24).

**Signing:** a release build needs `android/key.properties` and the upload keystore, and fails without them. For a local test build use `flutter build apk --release --android-project-arg=allowDebugSigning=true`. Details are in [`app-release.md`](app-release.md).

## Troubleshooting

**`idf.py: command not found`**
Run `. "$HOME/esp/esp-idf/export.sh"` in this terminal first.

**`ESP-IDF Python virtual environment ".../idf6.1_py3.12_env/bin/python" not found`**
`export.sh` picked a different Python than the one the installer used. List `~/.espressif/python_env/` and point at the environment that exists:

```bash
export IDF_PYTHON_ENV_PATH="$HOME/.espressif/python_env/idf6.1_py3.14_env"
. "$HOME/esp/esp-idf/export.sh"
```

Or run `./install.sh esp32c3` again in `~/esp/esp-idf` with the Python you want.

**`export.sh` does nothing in a script**
It must be sourced (`.` or `source`) in bash or zsh, in the same shell that runs `idf.py`. In one-off commands, wrap both: `bash -c '. ~/esp/esp-idf/export.sh && idf.py build'`.

**A changed pin or option has no effect**
Your local `sdkconfig` still holds the old value. It overrides `sdkconfig.defaults`. Check with `grep OPTION_NAME sdkconfig`, then edit it, or delete `sdkconfig` and build again. See [`CONFIGURATION.md`](CONFIGURATION.md#changing-a-build-option).

**`Git reference "..." doesn't exist in the repository "...PixelEngine.git"`**
The cached copy of PixelEngine is out of date. Delete the component manager cache and build again:

- macOS: `rm -rf ~/Library/Caches/Espressif/ComponentManager/b_git_*`
- Linux: `rm -rf ~/.cache/Espressif/ComponentManager/b_git_*`

Then in `pump_node`, run `rm -rf dependencies.lock managed_components build` and build again.

**`has no member named 'setAnimationImmediate'`**
The PixelEngine commit pinned in `pump_node/main/idf_component.yml` is too old. Pull the latest `tanklink` changes.

**Build errors after switching ESP-IDF versions**
Run `idf.py fullclean` in the board folder, then build again.

**Port busy / `could not open port`**
Another monitor (or a script) still has the port open. Close it. Only one program can use the port at a time.

**`W gpio: conflict found for GPIO[0]` / `GPIO[1]` on the pump**
Harmless. The relay pins are set to idle very early in boot, then configured again by the relay driver.

**DS3231 not found**
The boot log scans the I2C bus. It says if SDA and SCL look swapped, or lists any device that answers. Fix the wiring, or change `PUMP_RTC_SDA_GPIO` / `PUMP_RTC_SCL_GPIO`.
