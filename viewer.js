"use strict";

const byId = (id) => document.getElementById(id);
const canvas = byId("scene");
const ctx = canvas.getContext("2d");
const demo = byId("demo");
const connect = byId("connect");
const connectBluetooth = byId("connect-bluetooth");
const zero = byId("zero");
const message = byId("message");
const mode = byId("mode");
const pointerMode = byId("pointer-mode");
const pointer = byId("gyro-pointer");
const pointerLeft = byId("pointer-left");
const pointerUp = byId("pointer-up");
const systemCursor = byId("system-cursor");
const cursorStatus = byId("cursor-status");
const outputs = ["roll", "pitch", "yaw"].map(byId);
const axisColors = ["#ffa98d", "#c3ee9b", "#a7d4ff"];
const identity = [1, 0, 0, 0];
const rad = Math.PI / 180;
const clamp = (n, min, max) => Math.max(min, Math.min(max, n));

function multiply([a, b, c, d], [w, x, y, z]) {
  return [
    a * w - b * x - c * y - d * z,
    a * x + b * w + c * z - d * y,
    a * y - b * z + c * w + d * x,
    a * z + b * y - c * x + d * w,
  ];
}

const inverse = ([w, x, y, z]) => [w, -x, -y, -z];
const rotate = (q, point) => multiply(multiply(q, [0, ...point]), inverse(q)).slice(1);

function orientation(roll, pitch, yaw) {
  const axis = (angle, i) => identity.map((_, j) =>
    j === 0 ? Math.cos(angle / 2) : j === i ? Math.sin(angle / 2) : 0
  );
  return multiply(multiply(axis(yaw, 3), axis(pitch, 2)), axis(roll, 1));
}

function euler([w, x, y, z]) {
  return [
    Math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)),
    Math.asin(clamp(2 * (w * y - z * x), -1, 1)),
    Math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)),
  ];
}

let pose = identity;
let reference = identity;
let timestamp = null;

// Gyro readings drive motion. The accelerometer corrects tilt when its
// magnitude is close to 1 g. Rotation about gravity has no absolute reference.
function updatePose([time, ax, ay, az, gx, gy, gz]) {
  const magnitude = Math.hypot(ax, ay, az);
  const dt = timestamp === null ? 0 : ((time - timestamp) >>> 0) / 1e6;
  timestamp = time;

  if (dt === 0 || dt > 0.25) {
    if (magnitude > 0.8 && magnitude < 1.2) {
      const yaw = dt === 0 ? 0 : euler(pose)[2];
      pose = orientation(Math.atan2(ay, az), Math.atan2(-ax, Math.hypot(ay, az)), yaw);
    }
    return 0;
  }

  let wx = gx * rad, wy = gy * rad, wz = gz * rad;
  if (magnitude > 0.8 && magnitude < 1.2) {
    const [vx, vy, vz] = rotate(inverse(pose), [0, 0, 1]);
    const gain = 2.4 / magnitude;
    wx += gain * (ay * vz - az * vy);
    wy += gain * (az * vx - ax * vz);
    wz += gain * (ax * vy - ay * vx);
  }

  const rate = multiply(pose, [0, wx, wy, wz]);
  const next = pose.map((value, i) => value + rate[i] * dt / 2);
  const length = Math.hypot(...next);
  pose = next.map((value) => value / length);
  return dt;
}

let pointerX = 50;
let pointerY = 50;

function positionPointer(x, y) {
  pointerX = clamp(x, 0, 100);
  pointerY = clamp(y, 0, 100);
  pointer.style.left = `${pointerX}%`;
  pointer.style.top = `${pointerY}%`;
}

function movePointer(gyro, dt) {
  if (dt <= 0 || dt > 0.25) return;
  // Ignore small resting gyro offsets without a sudden jump at the threshold.
  const motion = (mapping) => {
    const rate = gyro[mapping.at(-1)];
    // Left and up both decrease the corresponding screen coordinate.
    const direction = mapping.startsWith("-") ? 1 : -1;
    return direction * Math.sign(rate) * Math.max(0, Math.abs(rate) - 1.5);
  };
  const horizontal = motion(pointerLeft.value);
  const vertical = motion(pointerUp.value);
  if (horizontal || vertical) {
    positionPointer(pointerX + horizontal * dt * 1.8, pointerY + vertical * dt * 2.4);
    sendCursorMotion(horizontal * dt, vertical * dt);
  }
}

byId("center-pointer").addEventListener("click", () => positionPointer(50, 50));

const cursorOrigin = "http://127.0.0.1:8765";
let cursorSession = null;

function cursorRequest(action, session, body = null) {
  return fetch(`/cursor/${action}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Motion-Bench": "cursor" },
    body,
    signal: AbortSignal.any([
      session.controller.signal,
      AbortSignal.timeout(action === "enable" ? 5000 : 1500),
    ]),
  });
}

function stopSystemCursor(description = "System cursor is off.") {
  cursorSession?.controller.abort();
  cursorSession = null;
  systemCursor.setAttribute("aria-pressed", "false");
  cursorStatus.textContent = description;
}

systemCursor.addEventListener("click", async () => {
  if (cursorSession) {
    stopSystemCursor();
    return;
  }
  if (location.origin !== cursorOrigin) {
    cursorStatus.textContent = `Start the Mac cursor helper in the setup guide, then open ${cursorOrigin}.`;
    return;
  }
  if (!activeSession || mode.dataset.live !== "true" || performance.now() - lastPacket > 2500) {
    cursorStatus.textContent = "Connect your ESP32 and wait for live readings first.";
    return;
  }

  const session = { controller: new AbortController(), enabled: false, busy: false, x: 0, y: 0 };
  cursorSession = session;
  cursorStatus.textContent = "Checking macOS cursor access…";
  try {
    const response = await cursorRequest("enable", session);
    if (cursorSession !== session) return;
    if (response.status === 403) {
      stopSystemCursor("Approve cursor access in macOS Accessibility settings, then click System cursor again.");
      return;
    }
    if (!response.ok) throw new Error("Cursor helper unavailable");
    session.enabled = true;
    systemCursor.setAttribute("aria-pressed", "true");
    cursorStatus.textContent = "System cursor is on. Press Esc in this tab to turn it off.";
  } catch (error) {
    if (cursorSession !== session) return;
    const description = error.name === "TimeoutError"
      ? "The Mac cursor helper did not respond. Restart it in Terminal, then try again."
      : "The Mac cursor helper is unavailable. Check its Terminal window and try again.";
    stopSystemCursor(description);
  }
});

async function sendCursorMotion(turnX, turnY) {
  const session = cursorSession;
  if (!session?.enabled || session.busy) return;

  // Limit individual movements and keep fractions for slow, precise turns.
  session.x = clamp(session.x + turnX * 16, -48, 48);
  session.y = clamp(session.y + turnY * 16, -48, 48);
  const dx = Math.trunc(session.x);
  const dy = Math.trunc(session.y);
  if (!dx && !dy) return;
  session.x -= dx;
  session.y -= dy;
  session.busy = true;

  try {
    const response = await cursorRequest("move", session, JSON.stringify({ dx, dy }));
    if (!response.ok) throw new Error("Cursor movement failed");
  } catch {
    if (cursorSession === session) stopSystemCursor("System cursor stopped. Check the Mac helper and try again.");
  } finally {
    session.busy = false;
  }
}

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && cursorSession) stopSystemCursor();
});
window.addEventListener("pagehide", () => {
  if (cursorSession) stopSystemCursor();
});

function camera([x, y, z]) {
  const forward = 0.5 * x - 0.866 * y;
  return [0.866 * x + 0.5 * y, 0.58 * forward - 0.815 * z, 0.815 * forward + 0.58 * z];
}

function path(points, stroke, fill, closed = false, lineWidth = 1) {
  ctx.beginPath();
  points.forEach(([x, y], i) => i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y));
  if (closed) ctx.closePath();
  if (fill) {
    ctx.fillStyle = fill;
    ctx.fill();
  }
  if (stroke) {
    ctx.strokeStyle = stroke;
    ctx.lineWidth = lineWidth;
    ctx.stroke();
  }
}

function rectangle(x1, y1, x2, y2, z) {
  return [[x1, y1, z], [x2, y1, z], [x2, y2, z], [x1, y2, z]];
}

function solid(outline, bottom, top, palette, detail) {
  const lower = outline.map(([x, y]) => [x, y, bottom]);
  const upper = outline.map(([x, y]) => [x, y, top]);
  return [
    { points: upper, color: palette[0], detail },
    { points: [...lower].reverse(), color: palette[1] },
    ...upper.map((point, i) => {
      const next = (i + 1) % upper.length;
      return { points: [lower[i], lower[next], upper[next], point], color: palette[2 + i % 2] };
    }),
  ];
}

const boardTop = 0.06;
const outline = [
  [-1.6, -1.03], [1.6, -1.03], [1.72, -0.91], [1.72, 0.91],
  [1.6, 1.03], [-1.6, 1.03], [-1.72, 0.91], [-1.72, -0.91],
];

function boardDetails(project) {
  const flat = ([x, y]) => project([x, y, boardTop]);
  const trace = (points, color = "#5abfa0") => path(points.map(flat), color);
  const fillRect = (x1, y1, x2, y2, fill) =>
    path(rectangle(x1, y1, x2, y2, boardTop).map(project), null, fill, true);
  const pad = (x, y, radius, fill, stroke) => {
    const ring = Array.from({ length: 24 }, (_, i) => {
      const t = i * Math.PI / 12;
      return flat([x + radius * Math.cos(t), y + radius * Math.sin(t)]);
    });
    path(ring, stroke, fill, true);
  };

  for (const y of [-0.71, 0.71]) {
    pad(-1.4, y, 0.153, "#13231c", "#86d5ab");
    pad(-1.4, y, 0.102, "#101713");
  }
  for (let i = 0; i < 8; i++) {
    const y = (i - 3.5) * 0.22;
    trace([[1.41, y], [1.02, y], [0.72, y * 0.64], [0.29, y * 0.64]]);
    pad(1.42, y, 0.081, "#eed18d");
    pad(1.42, y, 0.033, "#534b32");
  }
  for (let i = 0; i < 5; i++) {
    const x = -0.47 + i * 0.14;
    fillRect(x, -0.36, x + 0.064, -0.28, "#d4c897");
    fillRect(x, 0.28, x + 0.064, 0.36, "#d4c897");
  }
  trace([[-0.54, -0.36], [-0.54, 0.36], [0.33, 0.36]], "#bde5cb");
  trace([[-0.45, 0.36], [-0.65, 0.56], [-0.94, 0.56], [-0.94, 0.15]]);
  trace([[0.43, 0.32], [0.64, 0.59], [0.95, 0.59]]);
  for (const [x, y] of [[-0.95, 0.11], [-0.95, -0.1], [0.63, 0.54], [0.86, 0.54], [0.59, -0.52]]) {
    fillRect(x - 0.08, y, x + 0.08, y + 0.09, "#e0c8a6");
    fillRect(x - 0.045, y, x + 0.045, y + 0.09, "#423b32");
  }
  pad(-0.88, -0.48, 0.066, "#b3f492");
}

const faces = [
  ...solid(outline, -0.06, boardTop, ["#25896f", "#184b3c", "#145742", "#1d684f"], boardDetails),
  ...solid(rectangle(-0.49, -0.28, 0.29, 0.28, 0), boardTop, 0.19,
    ["#222d2a", "#222d2a", "#101815", "#17221d"], (project) => {
      const detail = rectangle(-0.42, -0.22, 0.22, 0.22, 0.19).map(project);
      path(detail, "#5e7568", null, true);
    }),
];

function render(q) {
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
  const pixelWidth = Math.round(width * pixelRatio);
  const pixelHeight = Math.round(height * pixelRatio);
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  ctx.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  const scale = Math.min(width / 5.25, height / 3.8);
  const project = (point) => {
    const [x, y, z] = camera(point);
    const zoom = scale * 8 / (8 - z);
    return [width / 2 + x * zoom, height * 0.45 + y * zoom, z];
  };

  for (let i = -8; i <= 8; i++) {
    const n = i * 0.62;
    const stroke = i === 0 ? "#3c5348" : "#22342b";
    path([[-5, n, -1.44], [5, n, -1.44]].map(project), stroke);
    path([[n, -5, -1.44], [n, 5, -1.44]].map(project), stroke);
  }

  const boardProject = (point) => project(rotate(q, point));
  const visible = faces.map((face) => ({ ...face, screen: face.points.map(boardProject) }))
    .filter(({ screen: [a, b, c] }) =>
      (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) < 0
    );
  const depth = ({ screen }) => screen.reduce((sum, point) => sum + point[2], 0) / screen.length;
  visible.sort((a, b) => depth(a) - depth(b));
  for (const face of visible) {
    path(face.screen, "#79b19a", face.color, true, 0.65);
    face.detail?.(boardProject);
  }

  const origin = [53, height - 52];
  const axes = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
  const labels = axes.map((axis, i) => {
    const [x, y] = camera(rotate(q, axis));
    const tip = [origin[0] + 30 * x, origin[1] + 30 * y];
    path([origin, tip], axisColors[i], null, false, 2);
    return { x: tip[0] + 9 * x, y: tip[1] + 9 * y, i };
  });
  ctx.font = "600 12px ui-monospace, monospace";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const label of labels) {
    ctx.fillStyle = axisColors[label.i];
    ctx.fillText("XYZ"[label.i], label.x, label.y);
  }

  euler(q).forEach((angle, i) => {
    const degrees = angle / rad;
    const value = Math.abs(degrees) < 0.05 ? 0 : degrees;
    const formatted = `${value.toFixed(1)}°`;
    if (outputs[i].value !== formatted) outputs[i].value = formatted;
  });
}

let activeSession = null;
let pending = false;
let demoStart = null;
let demoTime = 0;
let lastDemoFrame = null;
let demoPose = orientation(0.16, -0.18, -0.33);
let lastPacket = -Infinity;
let connectedAt = -Infinity;
let sensorError = false;

function setStatus(label, description, live = false) {
  if (!live && cursorSession) stopSystemCursor();
  if (mode.textContent !== label) mode.textContent = label;
  if (mode.dataset.live !== String(live)) mode.dataset.live = live;
  if (message.textContent !== description) message.textContent = description;
  if (pointerMode.textContent !== label) pointerMode.textContent = label;
  if (pointerMode.dataset.live !== String(live)) pointerMode.dataset.live = live;
}

function syncButtons() {
  demo.disabled = pending || Boolean(activeSession);
  demo.textContent = demoStart === null ? "Play demo" : "Pause demo";
  connect.disabled = pending || activeSession?.transport === "Bluetooth";
  connectBluetooth.disabled = pending || activeSession?.transport === "USB";
  connect.textContent = activeSession?.transport === "USB" ? "Disconnect USB" : "Connect USB";
  connectBluetooth.textContent = activeSession?.transport === "Bluetooth"
    ? "Disconnect Bluetooth" : "Connect Bluetooth";
  zero.disabled = !activeSession || performance.now() - lastPacket > 2500;
}

function startSession(session) {
  if (demoStart !== null) demoTime += performance.now() - demoStart;
  demoStart = null;
  lastDemoFrame = null;
  positionPointer(50, 50);
  pose = identity;
  reference = identity;
  timestamp = null;
  sensorError = false;
  lastPacket = -Infinity;
  connectedAt = performance.now();
  activeSession = session;
  setStatus("Waiting for data", `${session.transport} connected. Keep the sensor still as it starts.`);
}

let lastRendered = null;
new ResizeObserver(() => { lastRendered = null; }).observe(canvas);

function animate(now) {
  let current = demoPose;
  if (activeSession) {
    if (now - Math.max(lastPacket, connectedAt) > 2500 && !sensorError) {
      setStatus("Waiting for data", "Keep the sensor still. If this persists, check the wiring and reset the ESP32.");
      zero.disabled = true;
    }
    current = pose;
  } else {
    if (demoStart !== null) {
      const t = (now - demoStart + demoTime) / 1000;
      if (lastDemoFrame !== null) {
        const demoGyro = {
          x: 0.57 * Math.cos(t + 0.28) / rad,
          y: -0.52 * 0.8 * Math.cos(0.8 * t + 0.35) / rad,
          z: 0.66 * 0.56 * Math.cos(0.56 * t) / rad,
        };
        movePointer(demoGyro, (now - lastDemoFrame) / 1000);
      }
      lastDemoFrame = now;
      demoPose = orientation(0.57 * Math.sin(t + 0.28), -0.52 * Math.sin(0.8 * t + 0.35),
        -0.33 + 0.66 * Math.sin(0.56 * t));
    }
    current = demoPose;
  }
  if (current !== lastRendered) {
    render(activeSession ? multiply(reference, current) : current);
    lastRendered = current;
  }
  requestAnimationFrame(animate);
}

demo.addEventListener("click", () => {
  if (demoStart === null) {
    demoStart = performance.now();
    setStatus("Demo running", "Simulated movement. Connect your ESP32 to see live readings.");
  } else {
    demoTime += performance.now() - demoStart;
    demoStart = null;
    lastDemoFrame = null;
    setStatus("Demo paused", "Press Play demo to resume.");
  }
  syncButtons();
});

zero.addEventListener("click", () => {
  reference = inverse(pose);
  lastRendered = null;
});

function receive(line) {
  if (line.startsWith("# ERROR:")) {
    sensorError = true;
    timestamp = null;
    lastPacket = -Infinity;
    setStatus("Check sensor wiring", "The ESP32 cannot read the MPU-6050. Check 3V3, GND, SDA and SCL.");
    syncButtons();
    return;
  }

  const [tag, ...fields] = line.split(",");
  if (tag !== "IMU" || fields.length !== 7 || fields.some((field) => !field.trim())) return;
  receiveSample(fields.map(Number));
}

function receiveSample(sample) {
  if (!activeSession || activeSession.closing) return;
  if (!sample.every(Number.isFinite) || !Number.isInteger(sample[0]) ||
      sample[0] < 0 || sample[0] > 0xffffffff ||
      sample.slice(1, 4).some((n) => Math.abs(n) > 2.01) ||
      sample.slice(4).some((n) => Math.abs(n) > 501)) return;
  const dt = updatePose(sample);
  if (cursorSession && performance.now() - lastPacket > 2500) stopSystemCursor();
  const [, , , , gx, gy, gz] = sample;
  movePointer({ x: gx, y: gy, z: gz }, dt);
  lastPacket = performance.now();
  sensorError = false;
  if (mode.dataset.live !== "true") {
    setStatus(`Live ${activeSession.transport}`, "Move the sensor to rotate the model. Zero orientation sets the current pose to 0°.", true);
    syncButtons();
  }
}

async function readPort(session) {
  const decoder = new TextDecoder();
  let buffer = "";
  try {
    while (!session.closing) {
      const { value, done } = await session.reader.read();
      if (done || session.closing) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop();
      for (const line of lines) receive(line.trim());
      if (buffer.length > 1024) buffer = "";
    }
  } catch {
    // A USB cable being unplugged can reject a pending read.
  } finally {
    session.reader.releaseLock();
    try { await session.port.close(); } catch { /* The port may already be gone. */ }
    activeSession = null;
    setStatus("Demo paused", session.closing ? "ESP32 disconnected. Press Play demo or reconnect."
      : "USB connection lost. Check the cable, then reconnect.");
    syncButtons();
  }
}

connect.addEventListener("click", async () => {
  if (activeSession) {
    if (activeSession.transport !== "USB") return;
    if (cursorSession) stopSystemCursor();
    activeSession.closing = true;
    connect.disabled = true;
    try { await activeSession.reader.cancel(); } catch { /* The read loop handles cleanup. */ }
    return;
  }

  if (!navigator.serial) {
    setStatus("USB unavailable", "Open this viewer in desktop Chrome or Edge at http://localhost:8000 for USB.");
    return;
  }

  pending = true;
  syncButtons();
  let port;
  let opened = false;
  try {
    port = await navigator.serial.requestPort();
    await port.open({ baudRate: 115200 });
    opened = true;
    const reader = port.readable.getReader();
    startSession({ transport: "USB", port, reader, closing: false });
    void readPort(activeSession);
  } catch (error) {
    if (opened) await port.close().catch(() => {});
    const label = demoStart === null ? "Demo" : "Demo running";
    const description = error.name === "NotFoundError" ? "No USB port selected. Try Connect USB again."
      : "Couldn’t open the port. Close Arduino Serial Monitor, then reconnect.";
    setStatus(label, description);
  } finally {
    pending = false;
    syncButtons();
  }
});

const motionService = "8b05f100-7a13-4f50-9f5a-f173fdc30001";
const motionCharacteristic = "8b05f100-7a13-4f50-9f5a-f173fdc30002";

function closeBluetooth(session, description) {
  session.device.removeEventListener("gattserverdisconnected", session.onDisconnect);
  session.characteristic?.removeEventListener("characteristicvaluechanged", session.onSample);
  if (session.device.gatt.connected) session.device.gatt.disconnect();
  if (activeSession !== session) return;
  activeSession = null;
  setStatus("Demo paused", description);
  syncButtons();
}

connectBluetooth.addEventListener("click", async () => {
  if (activeSession) {
    if (activeSession.transport === "Bluetooth") {
      closeBluetooth(activeSession, "Bluetooth disconnected. Press Play demo or reconnect.");
    }
    return;
  }
  if (!navigator.bluetooth) {
    setStatus("Bluetooth unavailable", "Open Motion Bench at http://127.0.0.1:8765 in desktop Chrome to connect over Bluetooth.");
    return;
  }

  pending = true;
  syncButtons();
  let session;
  try {
    const device = await navigator.bluetooth.requestDevice({ filters: [{ services: [motionService] }] });
    session = {
      transport: "Bluetooth",
      device,
      onDisconnect: () => closeBluetooth(session, "Bluetooth connection lost. Reconnect to MotionC3."),
      onSample: ({ target: { value } }) => {
        if (activeSession !== session || value?.byteLength !== 16) return;
        receiveSample([
          value.getUint32(0, true),
          value.getInt16(4, true) / 16384,
          value.getInt16(6, true) / 16384,
          value.getInt16(8, true) / 16384,
          value.getInt16(10, true) / 64,
          value.getInt16(12, true) / 64,
          value.getInt16(14, true) / 64,
        ]);
      },
    };
    const server = await device.gatt.connect();
    const service = await server.getPrimaryService(motionService);
    session.characteristic = await service.getCharacteristic(motionCharacteristic);
    device.addEventListener("gattserverdisconnected", session.onDisconnect);
    session.characteristic.addEventListener("characteristicvaluechanged", session.onSample);
    startSession(session);
    await session.characteristic.startNotifications();
  } catch (error) {
    const description = !session && error.name === "NotFoundError"
      ? "No board selected. Power on MotionC3 and disconnect it from the Mac app, then try again."
      : "Couldn’t start Bluetooth. Check browser Bluetooth access and disconnect MotionC3 from other apps.";
    if (session) closeBluetooth(session, description);
    setStatus(demoStart === null ? "Demo" : "Demo running", description);
  } finally {
    pending = false;
    syncButtons();
  }
});

requestAnimationFrame(animate);
