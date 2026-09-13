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
