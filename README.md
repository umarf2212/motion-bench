# Motion Bench

A local 3D viewer for an MPU-6050 breakout connected to an ESP32-WROOM development board with a CH340 USB-to-serial chip. You need four jumper wires and a USB data cable.

## Use the programmed board

The connected ESP32 already runs [the MicroPython sensor program](micropython/main.py) at startup. Open [Motion Bench](index.html) in desktop Brave, Chrome, or Edge. If the viewer is disconnected, click **Connect USB** and select the ESP32 port. The C3 normally appears as `usbmodem`, and the original ESP32-WROOM as `usbserial`. When **Live USB** appears, tilt the sensor. The first few seconds after power-up are used to calibrate, so keep the sensor still during that time.

Scroll to **Air mouse** and start with the breadboard flat. Use **Move left** and **Move up** to choose an axis and turn direction for each movement. The defaults are Y counterclockwise for left and Z clockwise for up. View each turn from the positive end of its sensor axis. Changes apply immediately, and reloading restores the defaults. Use **Center pointer** to reset its position.

## Read the ESP32-C3 over Bluetooth

In the web viewer, open [Motion Bench](http://127.0.0.1:8765) in desktop Chrome, click **Connect Bluetooth**, and select **MotionC3** in the browser’s chooser. Disconnect the Mac app first if it is connected to the board. Wait for **Live Bluetooth**, then move the sensor.

Power the C3 and wire the sensor as shown below. [Build the Mac app](#build-the-mac-app), then open **Motion Bench Bluetooth.app** in the `mac-client` folder and click **Connect**. Allow Bluetooth access if macOS asks. The app finds **MotionC3** and displays all six readings. If the app connects and waits for readings, check the MPU-6050 connections.

To move the Mac pointer over Bluetooth, wait for **Live Bluetooth**, set the sensor down, then click **Enable cursor**. Keep it still while the app measures the resting gyro offset. If macOS prompts you, enable **Motion Bench Bluetooth** in **System Settings → Privacy & Security → Accessibility**, then click **Enable cursor** again. Use **Move left** and **Move up** to choose the gyro axes and turn directions. Adjust **Cursor speed** from 0.25× to 3×. The app remembers your speed and directions. Click **Stop cursor** or press **Esc** while the app is focused to stop. Cursor control also stops if the sensor disconnects or stops sending readings.

Keep the sensor still for the first couple of seconds after connecting. The app measures the resting offset before showing gyro readings. If you moved the board while connecting, set it down and click **Zero drift** to try again. If the pointer drifts, stop cursor control, set the sensor down, and click **Enable cursor** to calibrate again.

On another computer with Bluetooth Low Energy, you can use [the Python reader](bluetooth_reader.py). Install [Bleak](https://bleak.readthedocs.io/en/stable/) in your Python environment, then run `python bluetooth_reader.py`. Connect from one Bluetooth client at a time. Disconnect Bluetooth when you want to use the USB stream.

For your own client, scan for GATT service `8b05f100-7a13-4f50-9f5a-f173fdc30001` and subscribe to characteristic `8b05f100-7a13-4f50-9f5a-f173fdc30002`. Each 16-byte notification contains a little-endian unsigned 32-bit timestamp in microseconds, three signed 16-bit accelerometer values in X/Y/Z order (16,384 counts per g), and three signed 16-bit gyro values in X/Y/Z order (64 counts per degree per second).

### Build the Mac app

On macOS 12 or later with the Xcode command line tools installed, run these commands from the repository folder.

```sh
motion_app="mac-client/Motion Bench Bluetooth.app"
mkdir -p "$motion_app/Contents/MacOS"
cp mac-client/Info.plist "$motion_app/Contents/Info.plist"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos12.0" \
  mac-client/MotionBench.swift -o "$motion_app/Contents/MacOS/MotionBench"
codesign --force --sign - "$motion_app"
```

## Move the macOS cursor

1. If Motion Bench is already connected to the ESP32 in another tab, disconnect it there.
2. Run the helper from the repository folder in Terminal and leave the window open.

   ```sh
   python3 cursor_helper.py
   ```

3. Open [http://127.0.0.1:8765](http://127.0.0.1:8765) in desktop Brave, Chrome, or Edge. Connect the ESP32 and wait for **Live USB** or **Live Bluetooth**.
4. In **Air mouse**, click **System cursor**. If macOS asks for access, enable the app it names under **System Settings → Privacy & Security → Accessibility**, then click **System cursor** again. The same axis and direction controls now steer the Mac cursor.

Click **System cursor** again or press **Esc** in the viewer tab to turn it off. You can also stop the helper with **Control-C** in Terminal.

The remaining steps cover wiring a board and setting up the viewer again. The Arduino sketch is an alternative for a board you intend to program with Arduino.

## 1. Wire the sensor

Unplug the ESP32 from USB first. Use the labels printed next to the pins on each board. The GPIO numbers in this table are pin **labels**, not positions counted from the end of the board.

| MPU-6050 breakout pin | ESP32-WROOM | ESP32-C3 Super Mini |
| --- | --- | --- |
| `VCC` | `3V3` | `3V3` |
| `GND` | `GND` | `GND` |
| `SDA` | `GPIO21` | `GPIO4` |
| `SCL` | `GPIO22` | `GPIO5` |

The MicroPython program selects the pins based on the ESP32 model. On a Mac, the C3's built-in USB port appears as a `usbmodem` device.

For the four buttons on the **ESP32-C3 Super Mini**, unplug USB and place each tactile switch across the breadboard’s center gap. A typical four-leg switch has two pairs of legs that are already connected internally. Use one leg from each pair. If you have a continuity tester, check that the two chosen legs connect only when pressed.

| Button | One leg | Leg from the other pair |
| --- | --- | --- |
| Left click | `GPIO0` | `GND` |
| Right click | `GPIO1` | `GND` |
| Hold to move | `GPIO6` | `GND` |
| Hold to scroll | `GPIO7` | `GND` |

All four ground wires can share the same breadboard ground rail. The firmware uses the C3's internal pull-ups, so the switches only need GPIO and ground. Keep the MPU-6050 connected to GPIO4 and GPIO5 as shown above.

In the Mac app, connect with the board still so it can zero the gyro. Click **Enable cursor** and grant Accessibility access if prompted. Hold GPIO6’s button to move the pointer, and release it to stop. Double-tap GPIO6 to lock movement on, and double-tap it again to unlock. Double-tap the left button with the pointer over the same spot to double-click. To drag, hold the left button while moving the cursor, then release it to drop.

To scroll, point at the scrollable area and hold GPIO7’s button. Turn the board the same way you move the cursor left, right, up, or down. Release GPIO7 during a fast turn to let scrolling coast briefly in that direction. A sharper flick coasts farther. Press it again to cancel the coast. Pressing GPIO7 clears the gyro lock and ignores gyro taps during scrolling. After releasing GPIO7, press GPIO6 again to move the pointer. **Stop cursor** or **Esc** in the app turns off both motion and clicks and clears the lock.

Use the ESP32’s 3.3 V pin. The sketch automatically checks the two MPU-6050 addresses, so you can leave `AD0` at the breakout’s default. If your module has an `AD0` pin with no onboard pull-down, connect it to GND. Leave `INT`, `XDA`, and `XCL` disconnected. If the sensor pins have loose, unsoldered headers, solder them before using jumper wires. [Espressif I²C pin reference](https://docs.espressif.com/projects/arduino-esp32/en/latest/api/i2c.html), [MPU-6050 datasheet](https://invensense.tdk.com/wp-content/uploads/2015/02/MPU-6000-Datasheet.pdf)

## 2. Arduino setup for another board

1. Install and open [Arduino IDE](https://www.arduino.cc/en/software).
2. In **Settings** or **Preferences**, add the URL below to **Additional Boards Manager URLs**. Then open **Boards Manager**, search for `esp32`, and install **esp32 by Espressif Systems**. [Espressif installation guide](https://docs.espressif.com/projects/arduino-esp32/en/latest/installing.html)

   ```text
   https://espressif.github.io/arduino-esp32/package_esp32_index.json
   ```

3. Connect the ESP32 with a USB data cable. Under **Tools → Board → esp32**, select **ESP32 Dev Module**. Under **Tools → Port**, pick the port that appears when you plug the board in. On a Mac it may contain `usbserial` or `wchusbserial`.
4. Open [mpu6050_stream.ino](mpu6050_stream/mpu6050_stream.ino) in Arduino IDE. Put the sensor flat on the desk, click **Upload**, then leave it still for the first few seconds after reset so the sketch can measure gyro bias.
5. Optional check in **Serial Monitor** at **115200 baud**. Lines starting with `IMU,` mean the sensor is streaming. Close Serial Monitor before connecting the viewer.

## 3. Open the viewer

Open [index.html](index.html) in **desktop Brave, Chrome, or Edge**. In Finder, right-click it and choose **Open With**. Click **Play demo** to try the viewer before plugging in the sensor. [Chrome Web Serial documentation](https://developer.chrome.com/docs/capabilities/serial)

If your browser blocks USB access when opening the file directly, run this command from the repository folder in Terminal.

```sh
python3 -m http.server 8000 --bind 127.0.0.1
```

Keep Terminal open and go to [http://localhost:8000](http://localhost:8000) in the same browser.

Click **Connect USB** and select the port for your board. When the status changes to **Live USB**, tilt the sensor and watch the model follow. **Zero orientation** makes the current pose the new reference. The MPU-6050 has no compass, so yaw (turning about the vertical axis) can drift. Press **Zero orientation** to set a new reference.

## If you get stuck

| What you see | What to try |
| --- | --- |
| No serial port appears | Try another USB data cable and USB port. If macOS still shows no CH340 port, check the [WCH macOS driver](https://www.wch-ic.com/downloads/CH341SER_MAC_ZIP.html). |
| Upload stays at `Connecting…` | If your board has **BOOT**, hold it while Arduino IDE says `Connecting…`, then release when the upload starts. |
| Browser says it couldn’t open the port | Close Arduino Serial Monitor and any other app using that port, then try again. |
| Viewer stays on **Waiting for data** | Keep the sensor flat and press the ESP32’s **EN** or **RST** button. Check that you uploaded the sketch to the port you selected. |
| Viewer says **Check sensor wiring** | Unplug USB, recheck all four connections, then reconnect USB. Make sure SDA goes to 21 and SCL to 22. |
| Orientation drifts quickly after startup | Put the sensor flat and still, press **EN/RST**, and give it a few seconds to recalibrate. |
