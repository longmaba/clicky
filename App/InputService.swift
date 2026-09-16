import AppKit
import Carbon
import IOKit
import IOKit.hid
import IOKit.hidsystem
import ClickyCore

/// Observes physical keyboard HID transitions and macOS mouse button events.
/// It never asks macOS for characters or text.
final class InputService {
    var onEvent: ((PhysicalInputEvent) -> Void)?
    var onReset: (() -> Void)?
    var onError: ((String?) -> Void)?
    private var worker: Thread?
    private var runLoop: CFRunLoop?
    private let stateLock = NSLock()
    private var manager: IOHIDManager?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var normalizer = InputNormalizer()
    private var mouseInput = MouseInputRouter()
    private var paused = false
    private var desiredRunning = false
    private var desiredPaused = false
    private var fallbackFnDown = false

    static var permissionGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    @discardableResult static func requestPermission() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    func start() {
        stateLock.lock()
        desiredRunning = true
        guard worker == nil else { stateLock.unlock(); return }
        let thread = makeWorkerLocked()
        stateLock.unlock(); thread.start()
    }
    private func makeWorkerLocked() -> Thread {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Clicky physical input"; thread.qualityOfService = .userInteractive
        worker = thread; return thread
    }
    private func finishWorker() {
        stateLock.lock(); runLoop = nil; worker = nil
        let next = desiredRunning ? makeWorkerLocked() : nil
        stateLock.unlock(); next?.start()
    }
    private func run() {
        let loop = CFRunLoopGetCurrent()!
        stateLock.lock(); runLoop = loop; paused = desiredPaused; let shouldRun = desiredRunning; stateLock.unlock()
        guard shouldRun else { finishWorker(); return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hid
        let devices: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 7],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 1],
            [kIOHIDDeviceUsagePageKey: 12, kIOHIDDeviceUsageKey: 1]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(hid, devices as CFArray)
        let elements: [[String: Int]] = [
            [kIOHIDElementUsagePageKey: 7], [kIOHIDElementUsagePageKey: 12],
            [kIOHIDElementUsagePageKey: 9,kIOHIDElementUsageKey: 1],
            [kIOHIDElementUsagePageKey: 9,kIOHIDElementUsageKey: 2],
            [kIOHIDElementUsagePageKey: 9,kIOHIDElementUsageKey: 3]
        ]
        IOHIDManagerSetInputValueMatchingMultiple(hid, elements as CFArray)
        IOHIDManagerRegisterInputValueCallback(hid, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, { context, _, _, device in
            guard let context else { return }
            let service = Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue()
            service.normalizer.remove(deviceID: service.deviceID(device))
            service.normalizer.remove(deviceID: MouseInputRouter.sessionDeviceID)
            service.onReset?()
        }, context)
        IOHIDManagerScheduleWithRunLoop(hid, loop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { onError?("Input Monitoring is unavailable. Grant access in System Settings, then reopen Clicky if needed.") }
        else { onError?(nil) }
        installEventTap(context: context, loop: loop)
        CFRunLoopRun()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(loop, tapSource, .defaultMode) }
        IOHIDManagerUnscheduleFromRunLoop(hid, loop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil; tap = nil; tapSource = nil; normalizer.reset(); fallbackFnDown = false
        mouseInput = MouseInputRouter()
        finishWorker()
    }
    private func receive(_ value: IOHIDValue) {
        guard !paused else { return }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        guard page == 7 || page == 12 || (page == 9 && (1...3).contains(usage)) else { return }
        // Keyboard rollover/error codes and consumer arrays are not physical buttons.
        guard page != 7 || usage >= 4 else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let phase: InputPhase = IOHIDValueGetIntegerValue(value) == 0 ? .up : .down
        let id = page == 7 && usage == 255 ? UInt64.max : deviceID(IOHIDElementGetDevice(element))
        let event = PhysicalInputEvent(usagePage: page, usage: usage, deviceID: id, phase: phase, timestamp: timestamp)
        if page == 9 && mouseInput.hidEvent(event) == nil { return }
        if let event = normalizer.process(event) { onEvent?(event) }
    }
    private func deviceID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }
    private func installEventTap(context: UnsafeMutableRawPointer, loop: CFRunLoop) {
        let types: [CGEventType] = [.flagsChanged, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // An interrupted tap may miss releases; do not leave buttons held.
                service.resetInputState()
                if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == 0x3F {
                service.receiveFn(event)
            } else {
                service.receiveMouse(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context)
        if let tap {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap); self.tap = nil; return
            }
            tapSource = source
            mouseInput = MouseInputRouter(sessionEventTapAvailable: true)
            CFRunLoopAddSource(loop, source, .defaultMode); CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    private func receiveMouse(_ type: CGEventType, _ event: CGEvent) {
        guard !paused else { return }
        let buttonNumber: Int64
        let phase: InputPhase
        switch type {
        case .leftMouseDown: buttonNumber = 0; phase = .down
        case .leftMouseUp: buttonNumber = 0; phase = .up
        case .rightMouseDown: buttonNumber = 1; phase = .down
        case .rightMouseUp: buttonNumber = 1; phase = .up
        case .otherMouseDown: buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber); phase = .down
        case .otherMouseUp: buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber); phase = .up
        default: return
        }
        guard let raw = mouseInput.sessionEvent(buttonNumber: buttonNumber, phase: phase,
                                                timestamp: ProcessInfo.processInfo.systemUptime),
              let normalized = normalizer.process(raw) else { return }
        onEvent?(normalized)
    }
    private func receiveFn(_ event: CGEvent) {
        guard !paused else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != fallbackFnDown else { return }
        fallbackFnDown = down
        // HID and the narrow CG fallback share one identity, so either ordering deduplicates.
        let raw = PhysicalInputEvent(usage:255,deviceID:UInt64.max,phase:down ? .down : .up,timestamp:timestamp)
        if let normalized = normalizer.process(raw) { onEvent?(normalized) }
    }
    func setPaused(_ value: Bool) {
        stateLock.lock(); desiredPaused = value; stateLock.unlock()
        perform { [weak self] in
            guard let self, self.paused != value else { return }
            self.paused = value; self.resetInputState()
        }
    }
    private func resetInputState() { normalizer.reset(); fallbackFnDown = false; onReset?() }
    func reset() { perform { [weak self] in self?.resetInputState() } }
    private func perform(_ block: @escaping () -> Void) {
        stateLock.lock(); let loop = runLoop; stateLock.unlock()
        if let loop { CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block); CFRunLoopWakeUp(loop) }
    }
    func stop() {
        stateLock.lock(); desiredRunning = false; stateLock.unlock()
        perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}
