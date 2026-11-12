# Motion Bench

Four-button Bluetooth air mouse for macOS. ESP32-C3 Super Mini, MPU-6050, and a browser-based 3D motion viewer.

## Wire and flash

Unplug USB before wiring. Use the ESP32 pin labels.

| MPU-6050 | ESP32-C3 | ESP32-WROOM (USB viewer) |
| --- | --- | --- |
| VCC | 3V3 | 3V3 |
| GND | GND | GND |
| SDA | GPIO4 | GPIO21 |
| SCL | GPIO5 | GPIO22 |

Leave `INT`, `XDA`, and `XCL` open. The firmware checks both I²C addresses. Tie `AD0` to GND if it would otherwise float.

On the C3, wire each switch between its GPIO and GND. Use one leg from each contact pair on a four-leg switch. Internal pull-ups are enabled.

| GPIO | Control |
| --- | --- |
| GPIO0 | Left-click. Double-tap to double-click. Hold while moving to drag. |
| GPIO1 | Right-click. |
| GPIO6 | Hold to move. Double-tap to toggle movement lock. |
| GPIO7 | Hold to scroll on both axes. Pressing clears movement lock and stops any coast. A sharper flick coasts farther after release. |

Copy [the firmware](micropython/main.py) to `/main.py` on the MicroPython board. Reset and keep the sensor still for calibration.

## Build the Mac app

Run from the repo root on macOS 12+ with Xcode Command Line Tools installed.

```sh
motion_app="mac-client/Motion Bench Bluetooth.app"
mkdir -p "$motion_app/Contents/MacOS"
cp mac-client/Info.plist "$motion_app/Contents/Info.plist"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos12.0" \
  mac-client/MotionBench.swift -o "$motion_app/Contents/MacOS/MotionBench"
codesign --force --sign - "$motion_app"
```

1. Open **Motion Bench Bluetooth.app** from `mac-client`. Allow Bluetooth access and click **Connect** to find **MotionC3**.
2. Set the sensor down and click **Enable cursor**. If prompted, allow the app under **System Settings > Privacy & Security > Accessibility**, then retry.
3. Set **Move left**, **Move up**, and **Cursor speed**. Defaults are Z counterclockwise for left and X counterclockwise for up. Scroll uses the same directions.

If the pointer drifts, stop cursor control and re-enable it with the board still. **Stop cursor** or **Esc** in the app disables pointer control.

## Web viewer and tools

- **3D viewer:** Open [index.html](index.html) in desktop Chrome. Choose **Play demo** or **Connect USB**. If USB access is blocked, run `python3 -m http.server 8000 --bind 127.0.0.1` and open [localhost:8000](http://localhost:8000).
- **Web Bluetooth or system cursor:** Run `python3 cursor_helper.py` on macOS and open [127.0.0.1:8765](http://127.0.0.1:8765) in Chrome. Select **MotionC3** under **Connect Bluetooth**. **System cursor** requires macOS Accessibility access.
- **BLE terminal reader:** Install `bleak` and run `python3 bluetooth_reader.py`. Connect one Bluetooth client at a time.
- **Arduino USB stream:** Upload [the ESP32-WROOM sketch](mpu6050_stream/mpu6050_stream.ino) with the Espressif ESP32 board package. Select **ESP32 Dev Module**. Serial runs at 115200 baud.
- **Rev A carrier PCB:** [KiCad and layout files](pcb-design/). Grid checks passed. Verify module fit and run KiCad DRC before fabrication.
