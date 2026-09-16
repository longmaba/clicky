import XCTest
import AVFoundation
@testable import ClickyCore

final class AudioControllerMouseTests: XCTestCase {
    private struct Fixture {
        let audio: AudioController
        let directory: URL
        let keyboard: SoundProfileManifest
        let mouse: SoundProfileManifest
        var settings: SoundSettings
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(loadMouse: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-mouse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sounds/Extras"), withIntermediateDirectories: true)
        func write(_ path: String, level: Float) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for i in 0..<960 { buffer.floatChannelData![0][i] = level }
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(path), settings: format.settings)
            try file.write(from: buffer)
        }
        try write("keyboard.wav", level: 0.1)
        try write("left-down.wav", level: 0.08); try write("left-up.wav", level: -0.04)
        try write("right-down.wav", level: 0.2); try write("right-up.wav", level: -0.16)
        for extra in ExtraSound.bundledSamples { try write("Sounds/Extras/\(extra.rawValue).wav", level: 0.05) }
        let keyboard = SoundProfileManifest(id: "thocky", name: "Keyboard", samples: ["keyboard.wav"])
        let left = SoundSampleSet(samples: ["left-down.wav"], releaseSamples: ["left-up.wav"])
        let right = SoundSampleSet(samples: ["right-down.wav"], releaseSamples: ["right-up.wav"])
        let mouse = SoundProfileManifest(id: "razer-orochi-v2", name: "Razer Orochi V2", samples: left.samples,
            releaseSamples: left.releaseSamples, keySamples: ["9:1": left, "9:2": right])
        let audio = AudioController(offline: true)
        try audio.load(profiles: [keyboard], mouseProfiles: loadMouse ? [mouse] : [], assetsURL: directory, importsURL: directory)
        var settings = SoundSettings()
        settings.mouseSound = .razerOrochiV2; settings.variation = false
        settings.volume = 0; settings.tone = 1; settings.pitch = 1; settings.homeRowSoftness = 1
        settings.modifierSoundMode = .silent; settings.normalization = true
        audio.update(settings: settings, keyOverrides: [:], enabled: true)
        _ = audio.renderOffline(frameCount: 4800)
        return Fixture(audio: audio, directory: directory, keyboard: keyboard, mouse: mouse, settings: settings)
    }

    private func event(_ phase: InputPhase, button: UInt32 = 1, device: UInt64 = 1) -> PhysicalInputEvent {
        PhysicalInputEvent(usagePage: 9, usage: button, deviceID: device, phase: phase)
    }
    private func count(_ audio: AudioController) -> UInt64 { audio.diagnostics.acceptedTriggers }
    private func waitForPreview() async throws { try await Task.sleep(nanoseconds: 180_000_000) }
    private func stroke(_ audio: AudioController, button: UInt32) -> (press: [Float], release: [Float]) {
        audio.trigger(event(.down, button: button)); let press = audio.renderOffline(frameCount: 4800)
        audio.trigger(event(.up, button: button)); let release = audio.renderOffline(frameCount: 4800)
        return (press, release)
    }

    func testRecordedButtonsAndMiddleFallbackKeepPressGainAndSoftenReleases() throws {
        let f = try fixture(); defer { f.cleanup() }
        XCTAssertEqual(f.audio.diagnostics.sampleCount, 10, "One keyboard, four mouse and five extra WAVs; left alias is shared")
        let left = stroke(f.audio, button: 1), right = stroke(f.audio, button: 2), middle = stroke(f.audio, button: 3)
        XCTAssertEqual(left.press.max()!, 0.08 * 0.25 / sqrt(2), accuracy: 0.000001)
        XCTAssertEqual(left.release.min()!, -0.04 * 0.25 * 0.7 / sqrt(2), accuracy: 0.000001)
        XCTAssertEqual(right.press.max()!, left.press.max()! * 2.5, accuracy: 0.000001)
        XCTAssertEqual(right.release.min()!, left.release.min()! * 4, accuracy: 0.000001)
        XCTAssertEqual(middle.press, left.press); XCTAssertEqual(middle.release, left.release)
        XCTAssertEqual(count(f.audio), 6)
    }

    func testMouseHoldsDuplicateOrphansAndMultipleButtonsStayIndependent() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 0)
        f.audio.trigger(event(.down)); f.audio.trigger(event(.down))
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 1)
        f.audio.trigger(event(.down, button: 2)); f.audio.trigger(event(.down, device: 2))
        XCTAssertEqual(count(f.audio), 3)
        for up in [event(.up, button: 2), event(.up, device: 2), event(.up)] {
            f.audio.trigger(up); f.audio.trigger(up)
        }
        XCTAssertEqual(count(f.audio), 6)
    }

    func testAudibleChoiceChangesKeepOriginalReleaseAndNonePrunesIt() throws {
        var f = try fixture(); defer { f.cleanup() }
        let reference = stroke(f.audio, button: 2)
        f.audio.trigger(event(.down, button: 2)); _ = f.audio.renderOffline(frameCount: 4800)
        f.settings.mouseSound = .soft
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up, button: 2))
        XCTAssertEqual(f.audio.renderOffline(frameCount: 4800), reference.release)
        f.settings.mouseSound = .razerOrochiV2
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.down)); XCTAssertEqual(count(f.audio), 5)
        f.settings.mouseSound = .none
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.settings.mouseSound = .razerOrochiV2
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 5)
    }

    func testMouseVolumeResetAndSuspensionDiscardPendingReleases() async throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.down))
        f.settings.mouseVolume = 0; f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.settings.mouseVolume = 0.25; f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 1)
        f.audio.trigger(event(.down)); f.audio.resetHeldInputs(); f.audio.trigger(event(.up))
        XCTAssertEqual(count(f.audio), 2)
        f.audio.trigger(event(.down)); f.audio.suspend(); f.audio.resume()
        try await waitForPreview()
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 3)
        f.settings.mouseVolume = 0; f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.down))
        f.settings.mouseVolume = 0.25; f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 4, "A zero-gain press cannot arm a release")
    }

    func testMousePreviewUsesLeftPairAndCancelsWhenMutedOrReset() async throws {
        var f = try fixture(); defer { f.cleanup() }
        let left = stroke(f.audio, button: 1)
        f.audio.previewExtra(.razerOrochiV2)
        XCTAssertEqual(count(f.audio), 3)
        XCTAssertEqual(f.audio.renderOffline(frameCount: 4800), left.press)
        try await waitForPreview()
        XCTAssertEqual(count(f.audio), 4)
        XCTAssertEqual(f.audio.renderOffline(frameCount: 4800), left.release)
        f.audio.previewExtra(.razerOrochiV2); f.settings.mouseSound = .none
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 5)
        f.audio.previewExtra(.razerOrochiV2); f.audio.resetHeldInputs()
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 6)
    }

    func testMissingMouseBankDoesNotBorrowKeyboardSamples() throws {
        let f = try fixture(loadMouse: false); defer { f.cleanup() }
        _ = stroke(f.audio, button: 1)
        f.audio.previewExtra(.razerOrochiV2)
        XCTAssertEqual(count(f.audio), 0)
    }

    func testMouseCatalogDoesNotChangeKeyboardNormalizationReference() throws {
        var f = try fixture(loadMouse: false); defer { f.cleanup() }
        f.settings.volume = 0.2; f.settings.tone = 0; f.settings.pitch = 0; f.settings.homeRowSoftness = 0; f.settings.spatial = false
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        func keyboardPress() -> [Float] {
            f.audio.trigger(PhysicalInputEvent(usage: 4, phase: .down))
            f.audio.trigger(PhysicalInputEvent(usage: 4, phase: .up))
            return f.audio.renderOffline(frameCount: 4800)
        }
        let before = keyboardPress()
        var mouse = f.mouse; mouse.gain = 10
        try f.audio.load(profiles: [f.keyboard], mouseProfiles: [mouse], assetsURL: f.directory, importsURL: f.directory)
        _ = f.audio.renderOffline(frameCount: 4800)
        XCTAssertEqual(keyboardPress(), before)
    }

    func testMouseChoiceAndFavoritesRoundTripWithoutChangingOldRawValuesOrDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-mouse-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        XCTAssertEqual(SoundSettings().mouseSound, .soft)
        XCTAssertEqual(ExtraSound.bundledSamples.map(\.rawValue), ["soft", "crisp", "hard", "ding", "typewriter"])
        XCTAssertEqual(ExtraSound.razerOrochiV2.mouseProfileID, "razer-orochi-v2")
        XCTAssertEqual(ExtraSound.razerOrochiV2.title, "Razer Orochi V2")
        for choice in ExtraSound.allCases {
            var config = AppConfiguration(); config.sound.mouseSound = choice
            config.favorites = [Favorite(name: "Mouse choice", sound: config.sound)]
            try store.save(config)
            XCTAssertEqual(try store.load(), config)
            XCTAssertEqual(config.schemaVersion, 1)
        }
    }
}
