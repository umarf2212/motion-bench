import AppKit
import CoreBluetooth
import CoreGraphics
import SwiftUI

private let motionService = CBUUID(string: "8b05f100-7a13-4f50-9f5a-f173fdc30001")
private let motionSample = CBUUID(string: "8b05f100-7a13-4f50-9f5a-f173fdc30002")
private let motionButtons = CBUUID(string: "8b05f100-7a13-4f50-9f5a-f173fdc30003")

private enum MotionButton: UInt8 {
    case leftClick = 1, rightClick = 2, move = 4, scroll = 8
}

private enum PointerAction {
    case idle, move, scroll

    init(buttons: UInt8, moveActive: Bool) {
        if buttons & MotionButton.scroll.rawValue != 0 {
            self = .scroll
        } else {
            self = moveActive ? .move : .idle
        }
    }
}

private struct MoveButtonGesture {
    private(set) var locked = false
    private var held: Bool
    private var pressStartedAt: TimeInterval?
    private var firstTapAt: TimeInterval?
    private var suppressHold = false

    init(held: Bool = false) { self.held = held }

    var moveActive: Bool { locked || (held && !suppressHold) }

    mutating func update(pressed: Bool, scrolling: Bool, now: TimeInterval, interval: TimeInterval) {
        if scrolling {
            self = MoveButtonGesture(held: pressed)
            suppressHold = pressed
            return
        }
        guard held != pressed else { return }
        held = pressed
        if pressed {
            if let firstTapAt, now - firstTapAt <= interval {
                locked.toggle()
                suppressHold = !locked
                pressStartedAt = nil
            } else {
                pressStartedAt = now
            }
            firstTapAt = nil
        } else {
            if let pressStartedAt, now - pressStartedAt <= interval {
                firstTapAt = pressStartedAt
            }
            pressStartedAt = nil
            suppressHold = false
        }
    }
}

struct LeftClickSequence {
    private var firstClick: (time: TimeInterval, location: CGPoint)?
    private var press: (time: TimeInterval, location: CGPoint)?
    private(set) var count: Int64 = 1

    mutating func mouseDown(at location: CGPoint, now: TimeInterval, interval: TimeInterval) -> Int64 {
        count = 1
        if let firstClick, now - firstClick.time <= interval,
           isNearby(location, firstClick.location) {
            count = 2
        }
        firstClick = nil
        press = (now, location)
        return count
    }

    mutating func mouseDragged(to location: CGPoint) {
        if let press, !isNearby(location, press.location) { self.press = nil }
    }

    mutating func mouseUp(at location: CGPoint, now: TimeInterval, interval: TimeInterval) -> Int64 {
        if count == 1, let press, now - press.time <= interval, isNearby(location, press.location) {
            firstClick = press
        }
        press = nil
        return count
    }

    private func isNearby(_ a: CGPoint, _ b: CGPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= 6
    }
}

func cursorDestination(from position: CGPoint, moving delta: CGPoint, displays: [CGRect]) -> CGPoint {
    func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX - 1, max(bounds.minX, point.x)),
                y: min(bounds.maxY - 1, max(bounds.minY, point.y)))
    }
    func distance(to bounds: CGRect) -> CGFloat {
        let nearest = clamp(position, to: bounds)
        return hypot(nearest.x - position.x, nearest.y - position.y)
    }
    guard let screen = displays.first(where: { $0.contains(position) })
            ?? displays.min(by: { distance(to: $0) < distance(to: $1) }) else { return position }
    let origin = clamp(position, to: screen)
    let target = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
    if displays.contains(where: { $0.contains(target) }) { return target }
    return clamp(target, to: screen)
}

struct MotionSample {
    let timestamp: UInt32
    let acceleration: [Double]
    let gyro: [Double]

    init?(_ data: Data) {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        func word(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func values(at offset: Int, scale: Double) -> [Double] {
            (0..<3).map { axis in Double(Int16(bitPattern: word(offset + axis * 2))) / scale }
        }
        timestamp = UInt32(word(0)) | UInt32(word(2)) << 16
        acceleration = values(at: 4, scale: 16_384)
        gyro = values(at: 10, scale: 64)
    }
}

enum CursorDirection: Int, CaseIterable {
    case xCounterclockwise, xClockwise
    case yCounterclockwise, yClockwise
    case zCounterclockwise, zClockwise

    var label: String {
        let axis = ["X", "Y", "Z"][rawValue / 2]
        return "\(axis) \(rawValue.isMultiple(of: 2) ? "counterclockwise" : "clockwise")"
    }

    func speed(from gyro: [Double]) -> Double {
        let rate = gyro[rawValue / 2]
        let direction = rawValue.isMultiple(of: 2) ? -1.0 : 1.0
        let adjusted = max(0, abs(rate) - 1.5)
        return direction * (rate < 0 ? -adjusted : adjusted)
    }
}

struct CursorMotion {
    private var target = CGPoint.zero
    private var velocity = CGPoint.zero
    private var xRemainder = 0.0
    private var yRemainder = 0.0
    private var previousScrollTimestamp: UInt32?
    private var horizontalFlick = ScrollFlick()
    private var verticalFlick = ScrollFlick()

    func scrollMomentum(sensitivity: Double) -> ScrollMomentum? {
        let scale = 16 * sensitivity
        return ScrollMomentum(horizontal: horizontalFlick.coast(speed: velocity.x * scale),
                              vertical: verticalFlick.coast(speed: velocity.y * scale))
    }

    mutating func update(_ gyro: [Double], timestamp: UInt32, left: CursorDirection,
                         up: CursorDirection, scrolling: Bool) {
        let next = CGPoint(x: left.speed(from: gyro), y: up.speed(from: gyro))
        if scrolling, let previousScrollTimestamp {
            let elapsed = timestamp &- previousScrollTimestamp
            if (2_000...75_000).contains(elapsed) {
                let dt = Double(elapsed) / 1_000_000
                let decay = exp(-dt / 0.09)
                horizontalFlick.update(acceleration: (next.x - target.x) / dt, decay: decay)
                verticalFlick.update(acceleration: (next.y - target.y) / dt, decay: decay)
            } else if elapsed > 75_000 {
                horizontalFlick = ScrollFlick()
                verticalFlick = ScrollFlick()
            }
        }
        previousScrollTimestamp = scrolling ? timestamp : nil
        target = next
    }

    mutating func step(seconds: Double, sensitivity: Double) -> CGPoint {
        guard seconds > 0 else { return .zero }
        let dt = min(seconds, 0.025)
        // Smooth changes in turning speed over a few ticks without a long tail.
        let blend = 1 - exp(-dt / 0.018)
        velocity.x += (target.x - velocity.x) * blend
        velocity.y += (target.y - velocity.y) * blend
        let scale = dt * 16 * sensitivity
        let x = min(48, max(-48, xRemainder + velocity.x * scale))
        let y = min(48, max(-48, yRemainder + velocity.y * scale))
        let movement = CGPoint(x: x.rounded(.towardZero), y: y.rounded(.towardZero))
        xRemainder = x - movement.x
        yRemainder = y - movement.y
        return movement
    }
}

private struct ScrollFlick {
    private var positiveAcceleration = 0.0
    private var negativeAcceleration = 0.0

    mutating func update(acceleration: Double, decay: Double) {
        positiveAcceleration = max(positiveAcceleration * decay, acceleration)
        negativeAcceleration = max(negativeAcceleration * decay, -acceleration)
    }

    func coast(speed: Double) -> ScrollCoast? {
        ScrollCoast(speed: speed, flickAcceleration: speed < 0 ? negativeAcceleration : positiveAcceleration)
    }
}

struct ScrollMomentum {
    private var horizontal: ScrollCoast?
    private var vertical: ScrollCoast?

    fileprivate init?(horizontal: ScrollCoast?, vertical: ScrollCoast?) {
        guard horizontal != nil || vertical != nil else { return nil }
        self.horizontal = horizontal
        self.vertical = vertical
    }

    var finished: Bool { (horizontal?.finished ?? true) && (vertical?.finished ?? true) }

    mutating func step(seconds: Double) -> CGPoint {
        let x = horizontal?.step(seconds: seconds) ?? 0
        let y = vertical?.step(seconds: seconds) ?? 0
        return CGPoint(x: Int(x), y: Int(y))
    }
}

private struct ScrollCoast {
    private var speed: Double
    private var remainingTime = 0.28
    private var remainder = 0.0
    private let decayTime = 0.09

    init?(speed: Double, flickAcceleration: Double) {
        guard abs(speed) >= 120 else { return nil }
        // Keep a light flick short and cap the strongest flick at about 107 extra points.
        let strength = min(1, flickAcceleration / 2_500)
        self.speed = min(1_250, max(-1_250, speed)) * (0.23 + 0.77 * strength)
    }

    var finished: Bool { remainingTime <= 0 || abs(speed) < 12 }

    mutating func step(seconds: Double) -> Int32 {
        guard seconds > 0, !finished else { return 0 }
        let elapsed = min(seconds, remainingTime)
        let dt = min(elapsed, 0.025)
        let decay = exp(-dt / decayTime)
        remainder += speed * decayTime * (1 - decay)
        speed *= exp(-elapsed / decayTime)
        remainingTime -= elapsed
        let points = Int32(remainder)
        remainder -= Double(points)
        return points
    }
}

func stationaryGyroOffset(_ samples: [MotionSample]) -> [Double]? {
    guard samples.count >= 35, let first = samples.first, let last = samples.last,
          (1_000_000...2_000_000).contains(last.timestamp &- first.timestamp) else { return nil }
    var offsets: [Double] = []
    for axis in 0..<3 {
        let gyro = samples.map { $0.gyro[axis] }
        let acceleration = samples.map { $0.acceleration[axis] }
        guard gyro.max()! - gyro.min()! <= 1.25,
              acceleration.max()! - acceleration.min()! <= 0.06 else { return nil }
        let offset = gyro.reduce(0, +) / Double(gyro.count)
        guard abs(offset) <= 20 else { return nil }
        offsets.append(offset)
    }
    return offsets
}

final class MotionReceiver: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var ready = false
    @Published private(set) var active = false
    @Published private(set) var status = "Checking Bluetooth…"
    @Published private(set) var sample: MotionSample?
    @Published private(set) var cursorEnabled = false
    @Published private(set) var cursorStatus = "Cursor control is off."
    @Published private(set) var calibrating = false
    @Published var moveLeft = CursorDirection.zCounterclockwise {
        didSet {
            UserDefaults.standard.set(moveLeft.rawValue, forKey: "cursorMoveLeft")
            cursorMotion = CursorMotion()
        }
    }
    @Published var moveUp = CursorDirection.xCounterclockwise {
        didSet {
            UserDefaults.standard.set(moveUp.rawValue, forKey: "cursorMoveUp")
            cursorMotion = CursorMotion()
        }
    }
    @Published var sensitivity = 1.0 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "cursorSensitivity") }
    }

    private var central: CBCentralManager!
    private var board: CBPeripheral?
    private var cursorMotion = CursorMotion()
    private var scrollMomentum: ScrollMomentum?
    private var lastReadingAt = -Double.infinity
    private var lastDisplayAt = -Double.infinity
    private var lastCursorTick = 0.0
    private var cursorTimer: Timer?
    private var calibrationTimer: Timer?
    private var calibrationSamples: [MotionSample] = []
    private var gyroOffset: [Double]?
    private var requestedCursorAccess = false
    private var buttonState: UInt8?
    private var postedMouseButtons: UInt8 = 0
    private var leftClick = LeftClickSequence()
    private var moveGesture = MoveButtonGesture()
    private var pointerAction: PointerAction {
        PointerAction(buttons: buttonState ?? 0, moveActive: moveGesture.moveActive)
    }
    private var displayBounds: [CGRect] = []

    override init() {
        super.init()
        if let value = UserDefaults.standard.object(forKey: "cursorMoveLeft") as? Int,
           let direction = CursorDirection(rawValue: value) {
            moveLeft = direction
        }
        if let value = UserDefaults.standard.object(forKey: "cursorMoveUp") as? Int,
           let direction = CursorDirection(rawValue: value) {
            moveUp = direction
        }
        let savedSpeed = UserDefaults.standard.double(forKey: "cursorSensitivity")
        if (0.25...3.0).contains(savedSpeed) { sensitivity = savedSpeed }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func toggle() {
        if active {
            finish("Disconnected.")
        } else if ready {
            sample = nil
            active = true
            status = "Looking for MotionC3…"
            central.scanForPeripherals(withServices: [motionService])
        }
    }

    private func finish(_ message: String) {
        if cursorEnabled || calibrating { stopCursor() }
        buttonState = nil
        gyroOffset = nil
        central.stopScan()
        if let board { central.cancelPeripheralConnection(board) }
        board = nil
        active = false
        sample = nil
        status = message
    }

    func toggleCursor() {
        guard !calibrating else { return }
        if cursorEnabled {
            stopCursor()
            return
        }
        guard sample != nil, ProcessInfo.processInfo.systemUptime - lastReadingAt < 1 else {
            cursorStatus = "Connect to MotionC3 and wait for live readings first."
            return
        }
        guard CGPreflightPostEventAccess() else {
            cursorStatus = "Allow Motion Bench Bluetooth in Privacy & Security → Accessibility, then try again."
            if !requestedCursorAccess {
                requestedCursorAccess = true
                DispatchQueue.global().async { _ = CGRequestPostEventAccess() }
            }
            return
        }
        zeroDrift(enableAfterward: true)
    }

    private func startCursor() {
        refreshDisplays()
        cursorMotion = CursorMotion()
        lastCursorTick = ProcessInfo.processInfo.systemUptime
        cursorEnabled = true
        moveGesture = MoveButtonGesture(held: (buttonState ?? 0) & MotionButton.move.rawValue != 0)
        showMoveMode()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.cursorTick()
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    func stopCursor(_ message: String = "Cursor control is off.") {
        postMouseButtonChanges(postedMouseButtons, held: 0)
        leftClick = LeftClickSequence()
        scrollMomentum = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        calibrationSamples.removeAll()
        calibrating = false
        cursorEnabled = false
        moveGesture = MoveButtonGesture()
        cursorStatus = message
    }

    private func showMoveMode() {
        if pointerAction == .scroll {
            cursorStatus = "Scrolling. Gyro lock is off."
            return
        }
        cursorStatus = moveGesture.locked
            ? "Gyro movement is locked on. Double-tap to unlock."
            : "Hold the gyro button to move. Double-tap to lock movement on."
    }

    func zeroDrift(enableAfterward: Bool = false) {
        guard sample != nil, !calibrating, ProcessInfo.processInfo.systemUptime - lastReadingAt < 1 else { return }
        stopCursor("Measuring gyro offset. Keep the sensor still…")
        calibrating = true
        let timer = Timer(timeInterval: 1.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastReadingAt < 0.25,
               let offset = stationaryGyroOffset(self.calibrationSamples) {
                self.gyroOffset = offset
                self.stopCursor("Gyro zeroed. Click Enable cursor to resume.")
                if enableAfterward { self.startCursor() }
            } else {
                self.stopCursor("Couldn’t zero the gyro. Keep the sensor still and try again.")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        calibrationTimer = timer
    }

    var displayedGyro: [Double]? {
        guard gyroOffset != nil else { return nil }
        return sample.map { correctedGyro($0) }
    }
    var gyroIsZeroed: Bool { gyroOffset != nil }

    private func correctedGyro(_ reading: MotionSample) -> [Double] {
        guard let gyroOffset else { return reading.gyro }
        return zip(reading.gyro, gyroOffset).map { $0.0 - $0.1 }
    }

    private func cursorTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastCursorTick
        lastCursorTick = now
        let sampleAge = now - lastReadingAt
        if sampleAge >= 1 {
            stopCursor("Cursor stopped because the sensor stopped sending data.")
        }
        guard sampleAge < 0.075 else {
            cursorMotion = CursorMotion()
            scrollMomentum = nil
            return
        }
        if pointerAction == .idle, var momentum = scrollMomentum {
            let points = momentum.step(seconds: dt)
            scrollMomentum = momentum.finished ? nil : momentum
            postScroll(points)
            return
        }
        guard pointerAction != .idle else { return }
        let movement = cursorMotion.step(seconds: dt, sensitivity: sensitivity)
        if pointerAction == .scroll {
            postScroll(movement)
            return
        }
        guard movement != .zero, let current = CGEvent(source: nil)?.location else { return }
        let target = cursorDestination(from: current, moving: movement, displays: displayBounds)
        guard target != current else { return }
        let eventType: CGEventType
        let mouseButton: CGMouseButton
        if postedMouseButtons & MotionButton.leftClick.rawValue != 0 {
            eventType = .leftMouseDragged
            mouseButton = .left
        } else if postedMouseButtons & MotionButton.rightClick.rawValue != 0 {
            eventType = .rightMouseDragged
            mouseButton = .right
        } else {
            eventType = .mouseMoved
            mouseButton = .left
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                                  mouseCursorPosition: target, mouseButton: mouseButton) else { return }
        if eventType == .leftMouseDragged {
            leftClick.mouseDragged(to: target)
            event.setIntegerValueField(.mouseEventClickState, value: leftClick.count)
        }
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(_ movement: CGPoint) {
        guard movement != .zero, let current = CGEvent(source: nil)?.location else { return }
        // Quartz wheel deltas are positive for scrolling up and left.
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: -Int32(movement.y), wheel2: -Int32(movement.x), wheel3: 0)
        event?.location = current
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    func refreshDisplays() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return }
        displayBounds = displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    private func handleButtons(_ state: UInt8) {
        let previous = buttonState
        let previousAction = pointerAction
        buttonState = state
        let now = ProcessInfo.processInfo.systemUptime
        guard cursorEnabled, now - lastReadingAt < 1 else { return }
        let wasLocked = moveGesture.locked
        let scrolling = state & MotionButton.scroll.rawValue != 0
        moveGesture.update(pressed: state & MotionButton.move.rawValue != 0,
                           scrolling: scrolling || previousAction == .scroll,
                           now: now, interval: NSEvent.doubleClickInterval)
        if pointerAction != .idle {
            scrollMomentum = nil
        } else if previousAction == .scroll && now - lastReadingAt < 0.075 {
            scrollMomentum = cursorMotion.scrollMomentum(sensitivity: sensitivity)
        }
        if pointerAction != previousAction { cursorMotion = CursorMotion() }
        if wasLocked != moveGesture.locked || scrolling != (previousAction == .scroll) { showMoveMode() }
        guard let previous else { return }
        postMouseButtonChanges(state ^ previous, held: state)
    }

    private func postMouseButtonChanges(_ changed: UInt8, held: UInt8) {
        let clickMask = MotionButton.leftClick.rawValue | MotionButton.rightClick.rawValue
        let pending = changed & clickMask & (held ^ postedMouseButtons)
        guard pending != 0, let location = CGEvent(source: nil)?.location else { return }

        let buttons: [(MotionButton, CGMouseButton, CGEventType, CGEventType)] = [
            (.leftClick, .left, .leftMouseDown, .leftMouseUp),
            (.rightClick, .right, .rightMouseDown, .rightMouseUp),
        ]
        for (input, button, down, up) in buttons where pending & input.rawValue != 0 {
            let pressed = held & input.rawValue != 0
            guard let event = CGEvent(mouseEventSource: nil, mouseType: pressed ? down : up,
                                      mouseCursorPosition: location, mouseButton: button) else { continue }
            var clickCount: Int64 = 1
            if input == .leftClick {
                let now = ProcessInfo.processInfo.systemUptime
                let interval = NSEvent.doubleClickInterval
                clickCount = pressed ? leftClick.mouseDown(at: location, now: now, interval: interval)
                                     : leftClick.mouseUp(at: location, now: now, interval: interval)
            }
            event.setIntegerValueField(.mouseEventClickState, value: clickCount)
            event.post(tap: .cghidEventTap)
            postedMouseButtons ^= input.rawValue
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        ready = central.state == .poweredOn
        switch central.state {
        case .poweredOn: status = "Ready to connect."
        case .poweredOff: finish("Turn on Bluetooth to connect.")
        case .unauthorized: finish("Allow Motion Bench Bluetooth in Privacy & Security → Bluetooth.")
        case .unsupported: finish("Bluetooth Low Energy is unavailable on this Mac.")
        default: finish("Waiting for Bluetooth…")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, board == nil else { return }
        central.stopScan()
        board = peripheral
        peripheral.delegate = self
        status = "Connecting to \(peripheral.name ?? "MotionC3")…"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard board == peripheral else { return }
        peripheral.discoverServices([motionService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if board == peripheral { finish(error?.localizedDescription ?? "Connection failed. Try again.") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if board == peripheral { finish("Board disconnected. Click Connect to try again.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard board == peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == motionService }) else {
            finish("Motion service unavailable.")
            return
        }
        peripheral.discoverCharacteristics([motionSample, motionButtons], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard board == peripheral else { return }
        guard error == nil, let stream = service.characteristics?.first(where: { $0.uuid == motionSample }) else {
            finish("Motion stream unavailable.")
            return
        }
        peripheral.setNotifyValue(true, for: stream)
        if let buttons = service.characteristics?.first(where: { $0.uuid == motionButtons }) {
            peripheral.setNotifyValue(true, for: buttons)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard board == peripheral else { return }
        if characteristic.uuid == motionButtons {
            if error == nil && characteristic.isNotifying { peripheral.readValue(for: characteristic) }
            return
        }
        guard characteristic.uuid == motionSample else { return }
        guard error == nil, characteristic.isNotifying else {
            finish("Couldn’t subscribe to readings.")
            return
        }
        if sample == nil { status = "Connected. Waiting for sensor readings…" }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard board == peripheral, error == nil, let bytes = characteristic.value else { return }
        if characteristic.uuid == motionButtons {
            if bytes.count == 1, let state = bytes.first { handleButtons(state) }
            return
        }
        guard characteristic.uuid == motionSample, let reading = MotionSample(bytes) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let firstReading = sample == nil
        if calibrating { calibrationSamples.append(reading) }
        if cursorEnabled {
            if now - lastReadingAt >= 1 {
                stopCursor("Cursor stopped because the sensor stream paused.")
            } else if pointerAction != .idle {
                cursorMotion.update(correctedGyro(reading), timestamp: reading.timestamp, left: moveLeft, up: moveUp,
                                    scrolling: pointerAction == .scroll)
            }
        }
        lastReadingAt = now
        // Keep packet handling independent of SwiftUI redraws.
        if sample == nil || now - lastDisplayAt >= 0.05 {
            sample = reading
            lastDisplayAt = now
        }
        if status != "Live Bluetooth" { status = "Live Bluetooth" }
        if firstReading { zeroDrift() }
    }
}

struct MotionView: View {
    @ObservedObject var receiver: MotionReceiver

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Motion Bench").font(.largeTitle.bold())
                    Text(receiver.status).foregroundStyle(.secondary)
                }
                Spacer()
                Button(receiver.active ? "Disconnect" : "Connect") { receiver.toggle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!receiver.ready && !receiver.active)
            }
            readings(receiver.gyroIsZeroed ? "Gyroscope (zeroed) · °/s" : "Gyroscope · °/s",
                     values: receiver.displayedGyro)
            readings("Accelerometer · g", values: receiver.sample?.acceleration)
            if let sample = receiver.sample {
                Text("Sensor time \(Double(sample.timestamp) / 1_000_000, specifier: "%.2f") s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System cursor").font(.headline)
                    Text(receiver.cursorStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Zero drift") { receiver.zeroDrift() }
                    .disabled(receiver.sample == nil || receiver.calibrating)
                Button(receiver.cursorEnabled ? "Stop cursor" : "Enable cursor") {
                    receiver.toggleCursor()
                }
                .disabled(receiver.sample == nil || receiver.calibrating)
            }
            HStack {
                directionPicker("Move left", selection: $receiver.moveLeft)
                directionPicker("Move up", selection: $receiver.moveUp)
            }
            HStack {
                Slider(value: $receiver.sensitivity, in: 0.25...3, step: 0.05) {
                    Text("Cursor speed")
                }
                Text("\(receiver.sensitivity, specifier: "%.2f")×")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(24)
        .frame(minWidth: 490, minHeight: 350)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            receiver.refreshDisplays()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            receiver.stopCursor()
        }
        .onExitCommand { receiver.stopCursor() }
        .onDisappear { receiver.stopCursor() }
    }

    private func directionPicker(_ title: String, selection: Binding<CursorDirection>) -> some View {
        Picker(title, selection: selection) {
            ForEach(CursorDirection.allCases, id: \.self) { direction in
                Text(direction.label).tag(direction)
            }
        }
    }

    private func readings(_ title: String, values: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                ForEach(0..<3) { axis in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(["X", "Y", "Z"][axis]).foregroundStyle(.secondary)
                        Text(values.map { String(format: "%+.2f", $0[axis]) } ?? "—")
                            .font(.title2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

@main
struct MotionBenchApp: App {
    @StateObject private var receiver = MotionReceiver()

    var body: some Scene {
        WindowGroup("Motion Bench Bluetooth") { MotionView(receiver: receiver) }
    }
}
