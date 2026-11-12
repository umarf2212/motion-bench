#include <Wire.h>

// ESP32-WROOM development board pins used in the wiring guide.
constexpr int SDA_PIN = 21;
constexpr int SCL_PIN = 22;
constexpr unsigned long BAUD_RATE = 115200;
constexpr int CALIBRATION_SAMPLES = 200;

uint8_t address = 0x68;
float gyroBias[3] = {};

bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

int16_t readWord() {
  uint16_t high = Wire.read();
  uint16_t low = Wire.read();
  return static_cast<int16_t>((high << 8) | low);
}

bool readSensor(int16_t (&accel)[3], int16_t (&gyro)[3]) {
  Wire.beginTransmission(address);
  Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0 ||
      Wire.requestFrom(address, static_cast<size_t>(14)) != 14) {
    return false;
  }

  for (int16_t &value : accel) value = readWord();
  readWord();  // Skip the temperature.
  for (int16_t &value : gyro) value = readWord();
  return true;
}

bool startSensor() {
  const uint8_t addresses[] = {0x68, 0x69};
  for (uint8_t candidate : addresses) {
    address = candidate;
    Wire.beginTransmission(address);
    Wire.write(0x75);  // WHO_AM_I
    if (Wire.endTransmission(false) != 0 ||
        Wire.requestFrom(address, static_cast<size_t>(1)) != 1) {
      continue;
    }

    const int deviceId = Wire.read();
    // 0x74 is the ID reported by the connected breakout.
    if (deviceId != 0x68 && deviceId != 0x74) continue;

    if (!writeRegister(0x6B, 0x01)) return false;  // Wake and select gyro clock.
    delay(100);
    return writeRegister(0x1A, 0x03) &&  // Low-pass filter.
           writeRegister(0x19, 9) &&     // 100 Hz internal sample rate.
           writeRegister(0x1B, 0) &&     // ±250 degrees/second.
           writeRegister(0x1C, 0);       // ±2 g.
  }
  return false;
}

bool calibrate() {
  Serial.println("# Keep the sensor still for gyro calibration.");
  float sum[3] = {};
  for (int sample = 0; sample < CALIBRATION_SAMPLES; ++sample) {
    int16_t accel[3], gyro[3];
    if (!readSensor(accel, gyro)) return false;
    for (int axis = 0; axis < 3; ++axis) sum[axis] += gyro[axis];
    delay(10);
  }
  for (int axis = 0; axis < 3; ++axis) {
    gyroBias[axis] = sum[axis] / CALIBRATION_SAMPLES;
  }
  return true;
}

void setup() {
  Serial.begin(BAUD_RATE);
  Wire.begin(SDA_PIN, SCL_PIN, 100000);
}

void loop() {
  static bool ready = false;
  if (!ready) {
    ready = startSensor() && calibrate();
    if (!ready) {
      Serial.println("# ERROR: MPU-6050 not found or unreadable. Check 3V3, GND, SDA and SCL.");
      delay(1000);
      return;
    }
    Serial.println("# Streaming at about 50 Hz. Columns: us, ax, ay, az, gx, gy, gz");
  }

  int16_t accel[3], gyro[3];
  if (!readSensor(accel, gyro)) {
    ready = false;
    return;
  }

  Serial.printf("IMU,%lu,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f\n",
                static_cast<unsigned long>(micros()),
                accel[0] / 16384.0, accel[1] / 16384.0, accel[2] / 16384.0,
                (gyro[0] - gyroBias[0]) / 131.0,
                (gyro[1] - gyroBias[1]) / 131.0,
                (gyro[2] - gyroBias[2]) / 131.0);
  delay(20);
}
