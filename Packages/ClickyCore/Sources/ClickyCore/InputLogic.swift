import Foundation

/// Selects one mouse stream so a hardware click observed by both HID and the
/// window server produces only one transition. Session events also include
/// trackpad tap-to-click, which is not guaranteed to expose a HID button value.
public struct MouseInputRouter {
    public static let sessionDeviceID = UInt64.max - 1
    private let sessionEventTapAvailable: Bool

    public init(sessionEventTapAvailable: Bool = false) {
        self.sessionEventTapAvailable = sessionEventTapAvailable
    }

    public func hidEvent(_ event: PhysicalInputEvent) -> PhysicalInputEvent? {
        guard !sessionEventTapAvailable, event.usagePage == 9, (1...3).contains(event.usage) else { return nil }
        return event
    }

    public func sessionEvent(buttonNumber: Int64, phase: InputPhase, timestamp: Double) -> PhysicalInputEvent? {
        guard sessionEventTapAvailable, (0...2).contains(buttonNumber) else { return nil }
        return PhysicalInputEvent(usagePage: 9, usage: UInt32(buttonNumber + 1),
                                  deviceID: Self.sessionDeviceID, phase: phase, timestamp: timestamp)
    }
}

public struct InputNormalizer {
    private struct HeldKey: Hashable { var device: UInt64; var page: UInt32; var usage: UInt32 }
    private var held: Set<HeldKey> = []
    public init() {}
    public mutating func process(_ event: PhysicalInputEvent) -> PhysicalInputEvent? {
        guard (event.usagePage == 7 && event.usage >= 4 && event.usage <= 255) || (event.usagePage == 9 && (1...3).contains(event.usage)) || event.usagePage == 12 else { return nil }
        let key = HeldKey(device: event.deviceID, page: event.usagePage, usage: event.usage)
        if event.phase == .down { guard held.insert(key).inserted else { return nil } }
        else { guard held.remove(key) != nil else { return nil } }
        var normalized = event
        normalized.modifiers = held.reduce(into: KeyModifiers()) { flags, key in
            if key.page == 7 { flags.formUnion(KeyboardLayout.modifier(for: key.usage)) }
        }
        return normalized
    }
    public mutating func remove(deviceID: UInt64) { held = held.filter { $0.device != deviceID } }
    public mutating func reset() { held.removeAll(keepingCapacity: true) }
}

public struct ShortcutRecognizer {
    private var taps: [Double] = []
    public init() {}
    public mutating func process(_ event: PhysicalInputEvent, shortcut: ShortcutConfiguration) -> Bool {
        guard event.phase == .down, event.usagePage == 7 else { return false }
        guard KeyboardLayout.modifier(for: event.usage).isEmpty else { return false }
        guard event.usage == shortcut.usage, event.modifiers == shortcut.modifiers else { taps.removeAll(keepingCapacity: true); return false }
        taps.removeAll { event.timestamp - $0 > shortcut.interval || event.timestamp < $0 }
        taps.append(event.timestamp)
        if taps.count >= max(1, shortcut.tapCount) { taps.removeAll(keepingCapacity: true); return true }
        return false
    }
    public mutating func reset() { taps.removeAll(keepingCapacity: true) }
}
