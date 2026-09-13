import XCTest
import CClickyAudio
@testable import ClickyCore

final class ModifierSoundTests: XCTestCase {
    func testLegacySchemaOneMigrationPreservesSettingsAndFavoriteSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var expected = AppConfiguration()
        expected.enabled = false
        expected.sound.profileID = "marbly"
        expected.sound.volume = 0.73; expected.sound.tone = -0.42; expected.sound.pitch = 0.26
        expected.sound.spatial = false; expected.sound.spatialWidth = 0.35
        expected.sound.normalization = false; expected.sound.variation = false
        expected.sound.homeRowSoftness = 0.62; expected.sound.pauseOnHeadphones = true
        expected.sound.outputDeviceUID = "favorite-headphones"
        expected.sound.orbit = true; expected.sound.headTracking = true
        expected.sound.mouseSound = .custom; expected.sound.mouseVolume = 0.57
        expected.sound.enterSound = .custom; expected.sound.enterVolume = 0.81
        expected.sound.customMouse = ImportedSound(name: "Mouse", pressPath: "mouse.wav", releasePath: "mouse-up.wav")
        expected.sound.customEnter = ImportedSound(name: "Enter", pressPath: "enter.m4a", releasePath: "enter-up.aiff")
        expected.general.shortcut.usage = 19; expected.general.shortcut.modifiers = [.command, .shift]
        expected.visualizer.theme = .porcelain; expected.visualizer.enabled = true
        expected.keyOverrides = ["7:227": KeyOverride(profileID: "silent", tone: 0.6, pitch: -0.3, volume: 0.93)]
        expected.favorites = [Favorite(name: "Favorite A", sound: expected.sound, keyOverrides: expected.keyOverrides),
            Favorite(name: "Favorite B", sound: SoundSettings())]

        // Recreate exactly the old schema-1 shape by removing only the newly
        // introduced field at the top level and within every favorite snapshot.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        var sound = try XCTUnwrap(legacy["sound"] as? [String: Any]); sound.removeValue(forKey: "modifierSoundMode"); legacy["sound"] = sound
        var favorites = try XCTUnwrap(legacy["favorites"] as? [[String: Any]])
        for i in favorites.indices {
            var sound = try XCTUnwrap(favorites[i]["sound"] as? [String: Any])
            sound.removeValue(forKey: "modifierSoundMode"); favorites[i]["sound"] = sound
        }
        legacy["favorites"] = favorites
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.fileURL)

        let migrated = try store.load()
        XCTAssertEqual(migrated, expected)
        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertEqual(migrated.sound.modifierSoundMode, .soft)
        XCTAssertTrue(migrated.favorites.allSatisfy { $0.sound.modifierSoundMode == .soft })
        try store.save(migrated)
        XCTAssertEqual(try store.load(), expected)
    }

    func testEveryModifierModeRoundTripsInSettingsAndFavorites() throws {
        for mode in ModifierSoundMode.allCases {
            var config = AppConfiguration(); config.sound.modifierSoundMode = mode
            config.favorites = [Favorite(name: mode.title, sound: config.sound)]
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(decoded, config)
            XCTAssertEqual(decoded.favorites[0].sound.modifierSoundMode, mode)
        }
        XCTAssertEqual(SoundSettings().modifierSoundMode, .soft)
    }

    func testPolicyCoversBothModifierSidesAndFnButNotChordMainKey() {
        for usage in Array(UInt32(224)...UInt32(231)) + [255] {
            let event = PhysicalInputEvent(usage: usage, phase: .down)
            XCTAssertEqual(AudioMixParameters.modifierGain(for: event, mode: .soft), 0.25)
            XCTAssertEqual(AudioMixParameters.modifierGain(for: event, mode: .silent), 0)
            XCTAssertEqual(AudioMixParameters.modifierGain(for: event, mode: .full), 1)
        }
        for mode in ModifierSoundMode.allCases {
            let chordKey = PhysicalInputEvent(usage: 14, phase: .down, modifiers: [.command, .shift, .option, .control, .function])
            XCTAssertEqual(AudioMixParameters.modifierGain(for: chordKey, mode: mode), 1)
            XCTAssertEqual(AudioMixParameters.modifierGain(for: PhysicalInputEvent(usage: 40, phase: .down, modifiers: .command), mode: mode), 1)
            XCTAssertEqual(AudioMixParameters.modifierGain(for: PhysicalInputEvent(usagePage: 9, usage: 1, phase: .down, modifiers: .command), mode: mode), 1)
            XCTAssertEqual(AudioMixParameters.modifierGain(for: PhysicalInputEvent(usagePage: 12, usage: 227, phase: .down), mode: mode), 1)
        }
    }

    func testSilentCannotBeBypassedByPerKeyVolumeOverride() {
        let command = PhysicalInputEvent(usage: 227, phase: .down)
        let silent = AudioMixParameters.modifierGain(for: command, mode: .silent)
        let soft = AudioMixParameters.modifierGain(for: command, mode: .soft)
        XCTAssertEqual(AudioMixParameters.typingGain(volume: 0.4, override: 1, isHomeRow: false, softness: 0.15, modifierGain: silent), 0)
        XCTAssertEqual(AudioMixParameters.typingGain(volume: 0.4, override: 1, isHomeRow: false, softness: 0.15, modifierGain: soft), 0.25)
    }

    func testSoftModifierRendersQuarterAmplitudeWithoutDelayingAttack() {
        func render(mode: ModifierSoundMode) -> [Float] {
            let mixer = ca_mixer_create(48000)!
            defer { ca_mixer_destroy(mixer) }
            let sample = [Float](repeating: 0.3, count: 1024)
            let id = sample.withUnsafeBufferPointer { ca_mixer_add_sample(mixer, $0.baseAddress, UInt32($0.count), 48000) }
            let modifier = AudioMixParameters.modifierGain(for: PhysicalInputEvent(usage: 227, phase: .down), mode: mode)
            let gain = AudioMixParameters.typingGain(volume: 0.4, override: 0.8, isHomeRow: false, softness: 0.15, modifierGain: modifier)
            if gain > 0 {
                XCTAssertTrue(ca_mixer_enqueue(mixer, CATrigger(sample: UInt32(id), gain: gain, pan: 0, pitch: 1, tone: 0, audition: false)))
            }
            var left = [Float](repeating: 0, count: 128), right = left
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in ca_mixer_render(mixer, l.baseAddress, r.baseAddress, 128, 1) } }
            XCTAssertEqual(ca_mixer_stats(mixer).acceptedTriggers, mode == .silent ? 0 : 1)
            return left
        }
        let full = render(mode: .full), soft = render(mode: .soft), silent = render(mode: .silent)
        XCTAssertGreaterThan(full[0], 0); XCTAssertGreaterThan(soft[0], 0)
        for i in full.indices { XCTAssertEqual(soft[i], full[i] * 0.25, accuracy: 0.000001) }
        XCTAssertTrue(silent.allSatisfy { $0 == 0 })
    }

    func testModifierReleaseUsesPolicyChosenAtPressTime() {
        var tracker = AudioReleaseTracker<Float>()
        let command = PhysicalInputEvent(usage: 227, phase: .down)
        tracker.remember(AudioMixParameters.modifierGain(for: command, mode: .soft), for: command)
        let currentMode = ModifierSoundMode.full
        XCTAssertEqual(AudioMixParameters.modifierGain(for: command, mode: currentMode), 1)
        XCTAssertEqual(tracker.release(for: command), 0.25)
        tracker.remember(nil, for: command)
        XCTAssertNil(tracker.release(for: command))
    }

    func testSilentModifiersStillNormalizeAndRecognizeImmediateCommandShortcut() throws {
        for mode in ModifierSoundMode.allCases {
            var normalizer = InputNormalizer(), recognizer = ShortcutRecognizer()
            let command = try XCTUnwrap(normalizer.process(PhysicalInputEvent(usage: 227, phase: .down, timestamp: 10)))
            XCTAssertTrue(command.modifiers.contains(.command))
            _ = AudioMixParameters.modifierGain(for: command, mode: mode)
            var matches = 0
            for tap in 0..<3 {
                let timestamp = 10.01 + Double(tap) * 0.1
                let key = try XCTUnwrap(normalizer.process(PhysicalInputEvent(usage: 14, phase: .down, timestamp: timestamp)))
                XCTAssertEqual(key.timestamp, timestamp)
                XCTAssertEqual(key.modifiers, .command)
                XCTAssertEqual(AudioMixParameters.modifierGain(for: key, mode: mode), 1)
                if recognizer.process(key, shortcut: ShortcutConfiguration()) { matches += 1 }
                _ = normalizer.process(PhysicalInputEvent(usage: 14, phase: .up, timestamp: timestamp + 0.02))
            }
            XCTAssertEqual(matches, 1)
            XCTAssertEqual(normalizer.process(PhysicalInputEvent(usage: 227, phase: .up, timestamp: 11))?.modifiers, [])
        }
    }
}
