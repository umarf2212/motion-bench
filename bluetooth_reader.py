"""Print live MotionC3 readings on a computer with BLE and Bleak installed."""

import asyncio
from struct import Struct

from bleak import BleakClient, BleakScanner


SERVICE = "8b05f100-7a13-4f50-9f5a-f173fdc30001"
SAMPLE = "8b05f100-7a13-4f50-9f5a-f173fdc30002"
PACKET = Struct("<Ihhhhhh")


def show_reading(_, data):
    if len(data) != PACKET.size:
        return
    time_us, ax, ay, az, gx, gy, gz = PACKET.unpack(data)
    print(f"{time_us / 1e6:9.3f} s  "
          f"accel (g) {ax / 16384:+.3f} {ay / 16384:+.3f} {az / 16384:+.3f}  "
          f"gyro (°/s) {gx / 64:+.2f} {gy / 64:+.2f} {gz / 64:+.2f}", flush=True)


async def main():
    device = await BleakScanner.find_device_by_filter(
        lambda _, advertisement: SERVICE in advertisement.service_uuids,
        service_uuids=[SERVICE],
        timeout=12,
    )
    if device is None:
        raise SystemExit("MotionC3 not found. Power on the board and disconnect any other BLE client.")

    disconnected = asyncio.Event()
    async with BleakClient(device, disconnected_callback=lambda _: disconnected.set()) as client:
        await client.start_notify(SAMPLE, show_reading)
        print("Connected. Press Ctrl+C to stop.")
        await disconnected.wait()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
