# Firmware build setup (pump and tank)

This guide sets up a new computer to build and flash `pump_node` and `tank_node`.

Everything below was checked with **ESP-IDF v6.1** on macOS. Linux steps are the same except for the install packages.

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

Use the official ESP-IDF install at a fixed version. The version matters, because the repo's dependency lock is built against v6.1.

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

You should see `ESP-IDF v6.1`. If not, check the `git -C ~/esp/esp-idf describe --tags` output.

## 3. Get the code

```bash
git clone git@github.com:madhukartemba/tanklink.git
cd tanklink
```

**You do not need to clone PixelEngine.** The pump downloads it from GitHub during the build. It is pinned to a fixed commit in [`pump_node/main/idf_component.yml`](../pump_node/main/idf_component.yml).

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
idf.py set-target esp32c3
idf.py build
```

The first pump build downloads PixelEngine and the LED strip component. This needs internet access and can take a few minutes.

## 6. Flash

Plug in one board at a time and find its port:

- macOS: `ls /dev/cu.usbmodem*`
- Linux: `ls /dev/ttyACM*`
- Windows: check the COM port in Device Manager

Then flash and open the serial monitor:

```bash
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

If the board does not enter flash mode, hold **BOOT**, tap **RESET**, then release **BOOT**.

First flash after a partition change must be over USB. Use `erase-flash` once, which also clears pairing:

```bash
idf.py -p /dev/cu.usbmodemXXXX erase-flash flash
```

See [`docs/firmware-release.md`](firmware-release.md) for release and OTA notes.

## Troubleshooting

**`idf.py: command not found`**
Run `. "$HOME/esp/esp-idf/export.sh"` in the terminal first.

**`Git reference "..." doesn't exist in the repository "...PixelEngine.git"`**
The downloaded copy of PixelEngine is out of date. Delete the component manager cache and build again:

- macOS: `rm -rf ~/Library/Caches/Espressif/ComponentManager/b_git_*`
- Linux: `rm -rf ~/.cache/Espressif/ComponentManager/b_git_*`

Then in `pump_node`, run `rm -rf dependencies.lock managed_components build` and build again.

**`has no member named 'setAnimationImmediate'`**
The PixelEngine commit pinned in `pump_node/main/idf_component.yml` is too old. Pull the latest `tanklink` changes so the pinned commit is up to date.

**Build errors after switching ESP-IDF versions**
Run `idf.py fullclean` in the board folder, then build again.
