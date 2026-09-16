import XCTest
@testable import ClickyCore

final class InputConfigurationTests: XCTestCase {
    func testPhysicalTransitionsAndTwoDevices() {
        var n = InputNormalizer()
        let a = PhysicalInputEvent(usage: 4, deviceID: 1, phase: .down)
        XCTAssertNotNil(n.process(a)); XCTAssertNil(n.process(a))
        XCTAssertNotNil(n.process(PhysicalInputEvent(usage:4,deviceID:2,phase:.down)))
        XCTAssertNotNil(n.process(PhysicalInputEvent(usage:4,deviceID:1,phase:.up)))
        XCTAssertNil(n.process(PhysicalInputEvent(usage:4,deviceID:1,phase:.up)))
        n.remove(deviceID:2)
        XCTAssertNotNil(n.process(PhysicalInputEvent(usage:4,deviceID:2,phase:.down)))
    }
    func testModifiersSurviveOneOfTwoCommandKeysReleased() {
        var n = InputNormalizer()
        _ = n.process(PhysicalInputEvent(usage:227,phase:.down))
        _ = n.process(PhysicalInputEvent(usage:231,phase:.down))
        XCTAssertEqual(n.process(PhysicalInputEvent(usage:227,phase:.up))?.modifiers,.command)
        n.reset()
        XCTAssertEqual(n.process(PhysicalInputEvent(usage:4,phase:.down))?.modifiers,[])
    }
    func testSessionMouseMapsSupportedButtonsAndPhases() throws {
        let mouse = MouseInputRouter(sessionEventTapAvailable: true)
        for button in Int64(0)...2 {
            for phase in [InputPhase.down, .up] {
                let event = try XCTUnwrap(mouse.sessionEvent(buttonNumber: button, phase: phase, timestamp: 12.5))
                XCTAssertEqual(event.usagePage, 9)
                XCTAssertEqual(event.usage, UInt32(button + 1))
                XCTAssertEqual(event.deviceID, MouseInputRouter.sessionDeviceID)
                XCTAssertEqual(event.phase, phase)
                XCTAssertEqual(event.timestamp, 12.5)
            }
        }
        for button: Int64 in [-1, 3, 4, Int64.max] {
            XCTAssertNil(mouse.sessionEvent(buttonNumber: button, phase: .down, timestamp: 0))
        }
    }
    func testSessionMouseSuppressesHIDDuplicatesInEitherDeliveryOrder() {
        let mouse = MouseInputRouter(sessionEventTapAvailable: true)
        for hidFirst in [true, false] {
            var n = InputNormalizer()
            for button in Int64(0)...2 {
                for phase in [InputPhase.down, .up] {
                    let hid = mouse.hidEvent(PhysicalInputEvent(usagePage: 9, usage: UInt32(button + 1), deviceID: 42, phase: phase))
                    let session = mouse.sessionEvent(buttonNumber: button, phase: phase, timestamp: 1)
                    let delivered = (hidFirst ? [hid, session] : [session, hid]).compactMap { $0 }.compactMap { n.process($0) }
                    XCTAssertEqual(delivered.count, 1)
                    XCTAssertEqual(delivered.first?.phase, phase)
                    if let session { XCTAssertNil(n.process(session), "Repeated mouse transitions must not play twice") }
                }
            }
        }
    }
    func testMouseHIDFallbackPreservesIndependentDevices() throws {
        let mouse = MouseInputRouter()
        var n = InputNormalizer()
        XCTAssertNil(mouse.sessionEvent(buttonNumber: 0, phase: .down, timestamp: 1))
        for device: UInt64 in [41, 42] {
            for usage in UInt32(1)...3 {
                let raw = PhysicalInputEvent(usagePage: 9, usage: usage, deviceID: device, phase: .down)
                let event = try XCTUnwrap(mouse.hidEvent(raw))
                XCTAssertEqual(event, raw)
                XCTAssertNotNil(n.process(event))
                XCTAssertNil(n.process(event))
            }
        }
        XCTAssertNil(mouse.hidEvent(PhysicalInputEvent(usagePage: 9, usage: 4, phase: .down)))
        XCTAssertNil(mouse.hidEvent(PhysicalInputEvent(usage: 4, phase: .down)))
    }
    func testChordedMouseButtonsReleaseIndependentlyAndKeepKeyboardModifiers() throws {
        let mouse = MouseInputRouter(sessionEventTapAvailable: true)
        var n = InputNormalizer()
        _ = n.process(PhysicalInputEvent(usage: 227, deviceID: 5, phase: .down))
        _ = n.process(PhysicalInputEvent(usage: 255, deviceID: UInt64.max, phase: .down))
        func event(_ button: Int64, _ phase: InputPhase) throws -> PhysicalInputEvent {
            try XCTUnwrap(mouse.sessionEvent(buttonNumber: button, phase: phase, timestamp: 1))
        }
        for button in Int64(0)...2 {
            XCTAssertEqual(n.process(try event(button, .down))?.modifiers, [.command, .function])
        }
        XCTAssertNotNil(n.process(try event(1, .up)))
        XCTAssertNil(n.process(try event(0, .down)), "Releasing right must not release left")
        XCTAssertNil(n.process(try event(2, .down)), "Releasing right must not release middle")
        XCTAssertNotNil(n.process(try event(1, .down)))
        n.remove(deviceID: MouseInputRouter.sessionDeviceID)
        XCTAssertEqual(n.process(try event(0, .down))?.modifiers, [.command, .function])
        XCTAssertNil(n.process(try event(2, .up)))
        n.reset()
        XCTAssertNil(n.process(try event(0, .up)), "A late release after pause/reset must not produce a sound")
        XCTAssertEqual(n.process(try event(0, .down))?.modifiers, [])
    }
    func testShortcutRequiresThreePhysicalTapsAndExpires() {
        var s = ShortcutRecognizer(); let shortcut = ShortcutConfiguration()
        func k(_ time: Double) -> PhysicalInputEvent { PhysicalInputEvent(usage:14,phase:.down,modifiers:.command,timestamp:time) }
        XCTAssertFalse(s.process(k(1),shortcut:shortcut)); XCTAssertFalse(s.process(k(1.2),shortcut:shortcut))
        XCTAssertTrue(s.process(k(1.4),shortcut:shortcut)); XCTAssertFalse(s.process(k(2),shortcut:shortcut))
        XCTAssertFalse(s.process(k(4),shortcut:shortcut)); XCTAssertFalse(s.process(k(4.2),shortcut:shortcut))
        XCTAssertTrue(s.process(k(4.3),shortcut:shortcut))
        XCTAssertFalse(s.process(PhysicalInputEvent(usage:14,phase:.up,modifiers:.command,timestamp:4.4),shortcut:shortcut))
    }
    func testLayoutHasUniqueStableKeysAndSpatialPosition() {
        XCTAssertEqual(Set(KeyboardLayout.keys.map(\.id)).count,KeyboardLayout.keys.count)
        XCTAssertLessThan(KeyboardLayout.pan(for:20),0)
        XCTAssertGreaterThan(KeyboardLayout.pan(for:19),0)
        XCTAssertEqual(KeyboardLayout.pan(for:999),0)
    }
    func testConfigurationRoundTripAndValidation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = ConfigurationStore(directory:dir)
        var c = AppConfiguration(); c.sound.profileID = "creamy"; c.sound.volume = 20
        c.keyOverrides["7:4"] = KeyOverride(profileID:"marbly",tone:0.5,volume:0.2)
        c.favorites = [Favorite(name:"My desk",sound:c.sound,keyOverrides:c.keyOverrides)]
        try store.save(c)
        let loaded = try store.load()
        XCTAssertEqual(loaded.sound.volume,1); XCTAssertEqual(loaded.keyOverrides,c.keyOverrides)
        XCTAssertEqual(loaded.favorites.first?.name,"My desk")
        XCTAssertEqual(loaded.general.shortcut.label,"⌘ KKK")
        c.schemaVersion = 2; try store.save(c)
        XCTAssertThrowsError(try store.load())
    }
}
