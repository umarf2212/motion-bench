"""Stream MPU-6050-compatible motion data for Motion Bench."""

from machine import I2C, Pin
from os import uname
from struct import pack_into, unpack_from
from time import sleep_ms, sleep_us, ticks_add, ticks_diff, ticks_us

is_c3 = "ESP32C3" in uname().machine.upper().replace("-", "")
sda_pin, scl_pin = (4, 5) if is_c3 else (21, 22)
bus = I2C(0, sda=Pin(sda_pin), scl=Pin(scl_pin), freq=100000)
sample = bytearray(14)

BLE_SERVICE = "8b05f100-7a13-4f50-9f5a-f173fdc30001"
BLE_SAMPLE = "8b05f100-7a13-4f50-9f5a-f173fdc30002"
BLE_BUTTONS = "8b05f100-7a13-4f50-9f5a-f173fdc30003"
SAMPLE_PERIOD_US = 10_000
USB_PERIOD_US = 20_000


class Buttons:
    def __init__(self):
        # Bit order: left click, right click, move hold, scroll hold.
        self.pins = [Pin(number, Pin.IN, Pin.PULL_UP) for number in (0, 1, 6, 7)]
        self.state = 0
        self.pending = [0] * len(self.pins)

    def poll(self):
        for index, pin in enumerate(self.pins):
            bit = 1 << index
            pressed = pin.value() == 0
            if pressed == bool(self.state & bit):
                self.pending[index] = 0
            else:
                self.pending[index] += 1
                if self.pending[index] == 3:
                    self.state ^= bit
                    self.pending[index] = 0
        return self.state


class MotionBluetooth:
    def __init__(self):
        import bluetooth

        self.radio = bluetooth.BLE()
        self.radio.active(True)
        self.radio.config(gap_name="MotionC3")
        service = bluetooth.UUID(BLE_SERVICE)
        characteristic = (bluetooth.UUID(BLE_SAMPLE), bluetooth.FLAG_NOTIFY)
        buttons = (bluetooth.UUID(BLE_BUTTONS), bluetooth.FLAG_READ | bluetooth.FLAG_NOTIFY)
        ((self.handle, self.buttons_handle),) = self.radio.gatts_register_services(
            ((service, (characteristic, buttons)),)
        )
        self.buttons = Buttons()
        self.button_state = 0
        self.last_button_update = ticks_us()
        self.radio.gatts_write(self.buttons_handle, b"\x00")
        self.advertisement = b"\x02\x01\x06\x11\x07" + bytes(service) + b"\x09\x09MotionC3"
        self.connection = None
        self.packet = bytearray(16)
        self.radio.irq(self.on_event)
        self.advertise()

    def advertise(self):
        self.radio.gap_advertise(100000, adv_data=self.advertisement)

    def on_event(self, event, data):
        if event == 1:  # _IRQ_CENTRAL_CONNECT
            self.connection = data[0]
        elif event == 2:  # _IRQ_CENTRAL_DISCONNECT
            self.connection = None
            self.advertise()

    def notify(self, timestamp, ax, ay, az, gx, gy, gz):
        if self.connection is None:
            return
        # 16 bytes: uint32 microseconds, 3 accelerometer counts, 3 gyro values.
        # Gyro values use 64 counts per degree/second after bias correction.
        pack_into("<Ihhhhhh", self.packet, 0, timestamp, ax, ay, az,
                  round(gx * 64), round(gy * 64), round(gz * 64))
        try:
            self.radio.gatts_notify(self.connection, self.handle, self.packet)
        except OSError:
            # A full BLE queue or a disconnect must not interrupt USB streaming.
            pass

    def poll_buttons(self, now):
        state = self.buttons.poll()
        refresh = self.connection is not None and ticks_diff(now, self.last_button_update) >= 250_000
        if state != self.button_state or refresh:
            try:
                self.radio.gatts_write(self.buttons_handle, bytes((state,)), True)
                self.button_state = state
                self.last_button_update = now
            except OSError:
                pass  # Retry on the next sample.


ble_stream = None
if is_c3:
    try:
        ble_stream = MotionBluetooth()
        print("# Bluetooth ready: MotionC3")
    except (ImportError, OSError, ValueError) as error:
        print("# Bluetooth unavailable:", error)


def start_sensor():
    for address in (0x68, 0x69):
        try:
            device_id = bus.readfrom_mem(address, 0x75, 1)[0]
        except OSError:
            continue

        # 0x74 is the ID reported by the connected breakout.
        if device_id not in (0x68, 0x74):
            continue

        bus.writeto_mem(address, 0x6B, b"\x01")  # Wake and select the gyro clock.
        sleep_ms(100)
        bus.writeto_mem(address, 0x1A, b"\x03")  # Low-pass filter.
        bus.writeto_mem(address, 0x19, b"\x09")  # 100 Hz internal sample rate.
        bus.writeto_mem(address, 0x1B, b"\x00")  # ±250 degrees/second.
        bus.writeto_mem(address, 0x1C, b"\x00")  # ±2 g.
        print("# Sensor at 0x%02x, WHO_AM_I=0x%02x" % (address, device_id))
        return address

    raise OSError("No supported motion sensor found")


def read_sample(address):
    bus.readfrom_mem_into(address, 0x3B, sample)
    return unpack_from(">hhhhhhh", sample)


def calibrate(address):
    print("# Keep the sensor still for gyro calibration.")
    bias = [0, 0, 0]
    for _ in range(200):
        reading = read_sample(address)
        for axis in range(3):
            bias[axis] += reading[4 + axis]
        sleep_ms(10)
    return [total / 200 for total in bias]


def stream(address, bias):
    print("# Motion stream ready. Keep USB open for USB readings or connect to MotionC3.")
    last_tick = ticks_us()
    next_sample = last_tick
    last_usb = ticks_add(last_tick, -USB_PERIOD_US)
    timestamp = 0
    while True:
        delay = ticks_diff(next_sample, ticks_us())
        if delay >= 1000:
            sleep_ms(delay // 1000)
            delay = ticks_diff(next_sample, ticks_us())
        if delay > 0:
            sleep_us(delay)
        ax, ay, az, _, gx, gy, gz = read_sample(address)
        tick = ticks_us()
        # Extend MicroPython's wrapping counter to the viewer's uint32 clock.
        from_ticks = ticks_diff(tick, last_tick)
        timestamp = (timestamp + from_ticks) & 0xFFFFFFFF
        last_tick = tick
        gx, gy, gz = (gx - bias[0]) / 131, (gy - bias[1]) / 131, (gz - bias[2]) / 131
        if ble_stream is not None:
            ble_stream.poll_buttons(tick)
        if ble_stream is not None and ble_stream.connection is not None:
            # An unopened USB console can block writes, so give BLE the stream
            # while a client is connected. USB resumes after disconnection.
            ble_stream.notify(timestamp, ax, ay, az, gx, gy, gz)
        elif ticks_diff(tick, last_usb) >= USB_PERIOD_US:
            last_usb = ticks_add(last_usb, USB_PERIOD_US)
            if ticks_diff(tick, last_usb) >= USB_PERIOD_US:
                last_usb = tick
            print("IMU,%d,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f" % (
                timestamp, ax / 16384, ay / 16384, az / 16384, gx, gy, gz,
            ))
        next_sample = ticks_add(next_sample, SAMPLE_PERIOD_US)
        # Skip a missed slot instead of sending a burst of stale readings.
        now = ticks_us()
        if ticks_diff(next_sample, now) <= 0:
            next_sample = ticks_add(now, SAMPLE_PERIOD_US)


while True:
    try:
        address = start_sensor()
        stream(address, calibrate(address))
    except OSError:
        print("# ERROR: Motion sensor not found or unreadable. Check 3V3, GND, SDA and SCL.")
        sleep_ms(1000)
