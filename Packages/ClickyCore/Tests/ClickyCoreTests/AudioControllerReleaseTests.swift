import XCTest
import AVFoundation
import CClickyAudio
@testable import ClickyCore

final class AudioControllerReleaseTests: XCTestCase {
    private struct Fixture {
        let audio: AudioController
        let directory: URL
        var settings: SoundSettings
        let profiles: [SoundProfileManifest]
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sounds/Extras"), withIntermediateDirectories: true)
        func write(_ path: String, level: Float) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for i in 0..<960 { buffer.floatChannelData![0][i] = level }
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(path), settings: format.settings)
            try file.write(from: buffer)
        }
        try write("press.wav", level: 0.1)
        try write("press-2.wav", level: 0.15)
        try write("release.wav", level: -0.1)
        try write("other-release.wav", level: -0.25)
        for extra in ExtraSound.bundledSamples {
            try write("Sounds/Extras/\(extra.rawValue).wav", level: 0.05)
        }
        // Unequal phase counts exercise optional, independently selected banks.
        let profiles = [
            SoundProfileManifest(id: "paired", name: "Paired", samples: ["press.wav", "press-2.wav"], releaseSamples: ["release.wav"]),
            SoundProfileManifest(id: "other", name: "Other", samples: ["press.wav"], releaseSamples: ["other-release.wav"]),
            SoundProfileManifest(id: "press-only", name: "Press only", samples: ["press.wav"])
        ]
        let audio = AudioController(offline: true)
        try audio.load(profiles: profiles, assetsURL: directory, importsURL: directory)
        var settings = SoundSettings()
        settings.profileID = "paired"; settings.variation = false; settings.normalization = false
        settings.spatial = false; settings.homeRowSoftness = 0
        settings.mouseSound = .none; settings.enterSound = .none
        audio.update(settings: settings, keyOverrides: [:], enabled: true)
        _ = audio.renderOffline(frameCount: 4800)
        return Fixture(audio: audio, directory: directory, settings: settings, profiles: profiles)
    }

    private func keyFixture() throws -> Fixture {
        let f = try fixture()
        var profiles = f.profiles
        let enter = SoundSampleSet(samples: ["press-2.wav"], releaseSamples: ["release.wav"])
        profiles[0].keySamples = [
            "7:44": SoundSampleSet(samples: ["press-2.wav"], releaseSamples: ["other-release.wav"]),
            "7:40": enter, "7:88": enter,
            "7:42": SoundSampleSet(samples: ["press.wav"], releaseSamples: ["other-release.wav"]),
            "7:46": SoundSampleSet(samples: ["press-2.wav"])
        ]
        profiles[1].keySamples = ["7:44": SoundSampleSet(samples: ["press.wav"], releaseSamples: ["release.wav"])]
        try f.audio.load(profiles: profiles, assetsURL: f.directory, importsURL: f.directory)
        _ = f.audio.renderOffline(frameCount: 4800)
        return Fixture(audio: f.audio, directory: f.directory, settings: f.settings, profiles: profiles)
    }

    private func renderStroke(_ audio: AudioController, usage: UInt32) -> (press: [Float], release: [Float]) {
        audio.trigger(event(.down, usage: usage)); let press = audio.renderOffline(frameCount: 4800)
        audio.trigger(event(.up, usage: usage)); let release = audio.renderOffline(frameCount: 4800)
        return (press, release)
    }

    private func event(_ phase: InputPhase, usage: UInt32 = 4, device: UInt64 = 1, page: UInt32 = 7) -> PhysicalInputEvent {
        PhysicalInputEvent(usagePage: page, usage: usage, deviceID: device, phase: phase)
    }
    private func count(_ audio: AudioController) -> UInt64 { audio.diagnostics.acceptedTriggers }
    private func waitForPreview() async throws { try await Task.sleep(nanoseconds: 180_000_000) }

    func testHoldingDuplicatesOrphanReleasesAndPressOnlyBank() async throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.up))
        XCTAssertEqual(count(f.audio), 0)
        f.audio.trigger(event(.down)); f.audio.trigger(event(.down))
        XCTAssertEqual(count(f.audio), 1)
        try await waitForPreview()
        XCTAssertEqual(count(f.audio), 1, "Physical holds do not schedule preview releases")
        _ = f.audio.renderOffline(frameCount: 4800)
        f.audio.trigger(event(.up)); f.audio.trigger(event(.up))
        XCTAssertEqual(count(f.audio), 2)
        XCTAssertLessThan(f.audio.renderOffline(frameCount: 128).min()!, 0)
        f.settings.profileID = "press-only"
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.down)); f.audio.trigger(event(.down)); f.audio.trigger(event(.up))
        XCTAssertEqual(count(f.audio), 3)
    }

    func testOverlappingKeysAndTwoKeyboardsReleaseIndependently() throws {
        let f = try fixture(); defer { f.cleanup() }
        for down in [event(.down), event(.down, device: 2), event(.down, usage: 5)] { f.audio.trigger(down) }
        XCTAssertEqual(count(f.audio), 3)
        for (index, up) in [event(.up, device: 2), event(.up, usage: 5), event(.up)].enumerated() {
            f.audio.trigger(up); f.audio.trigger(up)
            XCTAssertEqual(count(f.audio), UInt64(4 + index))
        }
    }

    func testReleaseKeepsOriginalProfileTuningAndNonzeroVolume() throws {
        var changed = try fixture(); defer { changed.cleanup() }
        let reference = try fixture(); defer { reference.cleanup() }
        for f in [changed, reference] { f.audio.trigger(event(.down)); _ = f.audio.renderOffline(frameCount: 4800) }
        changed.settings.profileID = "other"; changed.settings.tone = 0.75
        changed.settings.pitch = -0.8; changed.settings.volume = 0.9; changed.settings.spatial = true
        changed.audio.update(settings: changed.settings, keyOverrides: [:], enabled: true)
        changed.audio.trigger(event(.up)); reference.audio.trigger(event(.up))
        XCTAssertEqual(changed.audio.renderOffline(frameCount: 1024), reference.audio.renderOffline(frameCount: 1024))
        XCTAssertEqual(count(changed.audio), 2)
    }

    func testMutePrunesPendingReleaseEvenIfUnmutedBeforeUpAndHonorsOverrides() throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.down)); XCTAssertEqual(count(f.audio), 1)
        f.settings.volume = 0
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.settings.volume = 0.4
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 1)

        let overrides = ["7:4": KeyOverride(volume: 0.5)]
        f.audio.update(settings: f.settings, keyOverrides: overrides, enabled: true)
        f.audio.trigger(event(.down)); f.settings.volume = 0
        f.audio.update(settings: f.settings, keyOverrides: overrides, enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 3, "Absolute override stays audible at zero typing volume")
        f.audio.trigger(event(.down))
        f.audio.update(settings: f.settings, keyOverrides: ["7:4": KeyOverride(volume: 0)], enabled: true)
        f.audio.update(settings: f.settings, keyOverrides: overrides, enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 4)
    }

    func testModifierModePrunesSilentReleaseAndRetainsSoftGain() throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.down, usage: 227)); _ = f.audio.renderOffline(frameCount: 4800)
        f.settings.modifierSoundMode = .full
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up, usage: 227))
        let soft = f.audio.renderOffline(frameCount: 4800)
        f.audio.trigger(event(.down, usage: 227)); _ = f.audio.renderOffline(frameCount: 4800)
        f.audio.trigger(event(.up, usage: 227))
        let full = f.audio.renderOffline(frameCount: 4800)
        XCTAssertEqual(abs(soft.min()!), abs(full.min()!) * 0.25, accuracy: 0.00001)
        f.audio.trigger(event(.down, usage: 227)); XCTAssertEqual(count(f.audio), 5)
        f.settings.modifierSoundMode = .silent
        f.audio.update(settings: f.settings, keyOverrides: ["7:227": KeyOverride(volume: 1)], enabled: true)
        f.settings.modifierSoundMode = .full
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up, usage: 227)); XCTAssertEqual(count(f.audio), 5)
    }

    func testEnterUsesProfileUnlessSpecialSoundIsConfigured() throws {
        var f = try fixture(); defer { f.cleanup() }
        for usage: UInt32 in [40, 88] { f.audio.trigger(event(.down, usage: usage)); f.audio.trigger(event(.up, usage: usage)) }
        XCTAssertEqual(count(f.audio), 4)
        f.settings.enterSound = .ding
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.down, usage: 40)); f.audio.trigger(event(.up, usage: 40))
        XCTAssertEqual(count(f.audio), 5)
    }

    func testResetDisableSuspendAndOutputRebuildDiscardPhysicalReleases() async throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.down)); f.audio.resetHeldInputs(); f.audio.trigger(event(.up))
        XCTAssertEqual(count(f.audio), 1)
        f.audio.trigger(event(.down)); f.audio.update(settings: f.settings, keyOverrides: [:], enabled: false)
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true); f.audio.trigger(event(.up))
        XCTAssertEqual(count(f.audio), 2)
        f.audio.trigger(event(.down)); f.audio.suspend(); f.audio.resume()
        try await waitForPreview()
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 3)
        f.audio.trigger(event(.down)); f.settings.outputDeviceUID = "missing-test-output"
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 4)
    }

    func testRecordedKeyboardReleaseIsSofterWithoutChangingPressAndPreviewMatches() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let physical = renderStroke(f.audio, usage: 4)
        let expectedPress: Float = 0.1 * 0.4 * 2 / sqrt(2)
        XCTAssertEqual(physical.press.max()!, expectedPress, accuracy: 0.000001)
        XCTAssertEqual(physical.release.min()!, -expectedPress * 0.7, accuracy: 0.000001)
        f.audio.preview(profileID: "paired")
        XCTAssertEqual(f.audio.renderOffline(frameCount: 4800), physical.press)
        try await waitForPreview()
        XCTAssertEqual(f.audio.renderOffline(frameCount: 4800), physical.release)
    }

    func testPreviewIsCompleteAfterHundredMillisecondsAndUnsupportedIsSingle() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let clock = ContinuousClock()
        let requestedAt = clock.now
        let minimumReleaseAt = requestedAt.advanced(by: .milliseconds(100))
        let completionDeadline = requestedAt.advanced(by: .seconds(2))
        f.audio.preview(profileID: "paired")
        var pairedCount: UInt64 = 0
        repeat {
            pairedCount = count(f.audio)
            let observedAt = clock.now
            // A short sleep can resume after the release deadline on a busy
            // runner. Judge the observed transition using elapsed monotonic time.
            if pairedCount == 2 {
                XCTAssertGreaterThanOrEqual(observedAt, minimumReleaseAt, "The release must not play before the 100 ms hold")
                break
            }
            XCTAssertEqual(pairedCount, 1, "Only the press may play while waiting for its release")
            if observedAt >= completionDeadline { break }
            try await clock.sleep(for: .milliseconds(5))
        } while true
        XCTAssertEqual(pairedCount, 2, "A supported preview must complete within two seconds")

        f.audio.preview(profileID: "press-only")
        let unsupportedDeadline = clock.now.advanced(by: .milliseconds(180))
        repeat {
            XCTAssertEqual(count(f.audio), 3, "A press-only preview must never schedule an extra release")
            if clock.now >= unsupportedDeadline { break }
            try await clock.sleep(for: .milliseconds(5))
        } while true
    }

    func testChangedSettingsCancelPreviewButIdenticalUpdatesPreserveIt() async throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.preview(profileID: "paired")
        f.settings.profileID = "other"
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 1)

        f.audio.preview(profileID: "paired")
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 3)

        // Explicit auditions also work while capture is disabled; routine
        // unchanged configuration updates must not truncate their release.
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: false)
        f.audio.preview(profileID: "paired")
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: false)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 5)
    }

    func testSupersededResetMutedRebuiltAndSuspendedPreviewsCancelRelease() async throws {
        var f = try fixture(); defer { f.cleanup() }
        f.audio.preview(profileID: "paired"); f.audio.preview(profileID: "other")
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 3)
        f.audio.preview(profileID: "paired"); f.audio.resetHeldInputs()
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 4)
        f.audio.preview(profileID: "paired"); f.settings.volume = 0
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.settings.volume = 0.4; f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 5)
        f.audio.preview(profileID: "paired"); f.settings.outputDeviceUID = "missing-test-output"
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 6)
        f.audio.preview(profileID: "paired"); f.audio.suspend()
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 7)
    }

    func testMutedPressNeverArmsReleaseAndPerKeyProfileKeepsItsOwnRelease() throws {
        var f = try fixture(); defer { f.cleanup() }
        f.settings.volume = 0
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.down)); f.settings.volume = 0.4
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 1)
        let reference = try fixture(); defer { reference.cleanup() }
        let override = ["7:4": KeyOverride(profileID: "other", tone: 0.4, pitch: 0.5, volume: 0.3)]
        for audio in [f.audio, reference.audio] {
            audio.update(settings: f.settings, keyOverrides: override, enabled: true)
            audio.trigger(event(.down)); _ = audio.renderOffline(frameCount: 4800)
        }
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up)); reference.audio.trigger(event(.up))
        XCTAssertEqual(f.audio.renderOffline(frameCount: 1024), reference.audio.renderOffline(frameCount: 1024))
    }

    func testConfiguredCustomReleasesUseIndependentCategoryMuteAndPreview() async throws {
        var f = try fixture(); defer { f.cleanup() }
        f.settings.customMouse = ImportedSound(name: "Custom", pressPath: "press.wav", releasePath: "release.wav")
        f.settings.customEnter = f.settings.customMouse
        f.settings.mouseSound = .custom; f.settings.enterSound = .custom; f.settings.volume = 0
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        let originalSamples = Set(f.profiles.flatMap(\.samplePaths)).count + 5
        for _ in 0..<100 {
            if f.audio.diagnostics.sampleCount == originalSamples + 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(f.audio.diagnostics.sampleCount, UInt32(originalSamples + 2))
        f.audio.trigger(event(.down, usage: 1, page: 9)); f.audio.trigger(event(.up, usage: 1, page: 9))
        f.audio.trigger(event(.down, usage: 40)); f.audio.trigger(event(.up, usage: 40))
        XCTAssertEqual(count(f.audio), 4, "Mouse and Enter volumes are independent of typing mute")
        f.audio.trigger(event(.down, usage: 1, page: 9)); f.audio.trigger(event(.down, usage: 40))
        f.settings.mouseVolume = 0; f.settings.enterVolume = 0
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.settings.mouseVolume = 0.4; f.settings.enterVolume = 0.4
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        f.audio.trigger(event(.up, usage: 1, page: 9)); f.audio.trigger(event(.up, usage: 40))
        XCTAssertEqual(count(f.audio), 6)
        f.audio.previewExtra(.custom)
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 8)
    }

    func testReloadCancelsPendingPreviewAndHeldReleaseBeforeReplacingSampleIDs() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.audio.trigger(event(.down)); f.audio.preview(profileID: "paired")
        XCTAssertEqual(count(f.audio), 2)
        try f.audio.load(profiles: Array(f.profiles.reversed()), assetsURL: f.directory, importsURL: f.directory)
        f.audio.trigger(event(.up))
        try await waitForPreview(); XCTAssertEqual(count(f.audio), 0)
        f.audio.trigger(event(.down)); f.audio.trigger(event(.up)); XCTAssertEqual(count(f.audio), 2)
    }

    func testOptionalKeySetsAndSourceOnlyProvenanceRoundTripWithoutChangingLegacyDefaults() throws {
        let legacy = #"{"id":"legacy","name":"Legacy","subtitle":"","color":"E99244","samples":["down.wav"],"gain":1,"provenance":{"source":"video.mp4","sectionStart":2,"sectionEnd":3}}"#
        let decoded = try JSONDecoder().decode(SoundProfileManifest.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.keySamples); XCTAssertNil(decoded.normalizationReference)
        XCTAssertEqual(decoded.provenance?.sectionStart, 2)
        let catalog = #"{"id":"catalog","name":"Catalog","subtitle":"","color":"E99244","samples":["down.wav"],"releaseSamples":["up.wav"],"keySamples":{"7:40":{"samples":["enter-down.wav"],"releaseSamples":["enter-up.wav"]},"7:88":{"samples":["enter-down.wav"],"releaseSamples":["enter-up.wav"]}},"gain":1,"normalizationReference":false,"provenance":{"source":"https://example.com/catalog.zip"}}"#
        let profile = try JSONDecoder().decode(SoundProfileManifest.self, from: Data(catalog.utf8))
        XCTAssertNil(profile.provenance?.sectionStart); XCTAssertNil(profile.provenance?.sectionEnd)
        XCTAssertEqual(profile.samplePaths, ["down.wav", "enter-down.wav", "enter-up.wav", "up.wav"])
        XCTAssertEqual(try JSONDecoder().decode(SoundProfileManifest.self, from: JSONEncoder().encode(profile)), profile)
    }

    func testKeyCategoriesSelectBothPhasesAndAliasesShareDecodedRecordings() throws {
        let f = try keyFixture(); defer { f.cleanup() }
        XCTAssertEqual(f.audio.diagnostics.sampleCount, 9, "Four unique profile WAVs plus five extras; aliases share PCM")
        let generic = renderStroke(f.audio, usage: 4)
        let space = renderStroke(f.audio, usage: 44)
        let enter = renderStroke(f.audio, usage: 40)
        let keypadEnter = renderStroke(f.audio, usage: 88)
        let backspace = renderStroke(f.audio, usage: 42)
        XCTAssertEqual(space.press.max()!, generic.press.max()! * 1.5, accuracy: 0.00001)
        XCTAssertEqual(space.release.min()!, generic.release.min()! * 2.5, accuracy: 0.00001)
        XCTAssertEqual(enter.press, space.press); XCTAssertEqual(enter.release, generic.release)
        XCTAssertEqual(enter.press, keypadEnter.press); XCTAssertEqual(enter.release, keypadEnter.release)
        XCTAssertEqual(backspace.press, generic.press); XCTAssertEqual(backspace.release, space.release)
        let unmapped = renderStroke(f.audio, usage: 5)
        XCTAssertEqual(unmapped.press, generic.press); XCTAssertEqual(unmapped.release, generic.release)
        let before = count(f.audio)
        let pressOnlyKey = renderStroke(f.audio, usage: 46)
        XCTAssertEqual(pressOnlyKey.press, space.press)
        XCTAssertTrue(pressOnlyKey.release.allSatisfy { $0 == 0 })
        XCTAssertEqual(count(f.audio), before + 1, "Mapped press-only keys must not borrow the generic release")
    }

    func testMappedReleaseSurvivesProfileChangeAndOverridesChooseTheirOwnKeySet() throws {
        var changed = try keyFixture(); defer { changed.cleanup() }
        let reference = try keyFixture(); defer { reference.cleanup() }
        changed.audio.trigger(event(.down, usage: 44)); _ = changed.audio.renderOffline(frameCount: 4800)
        changed.settings.profileID = "other"
        changed.audio.update(settings: changed.settings, keyOverrides: [:], enabled: true)
        changed.audio.trigger(event(.up, usage: 44))
        let original = renderStroke(reference.audio, usage: 44)
        XCTAssertEqual(changed.audio.renderOffline(frameCount: 4800), original.release)
        changed.settings.profileID = "paired"
        changed.audio.update(settings: changed.settings, keyOverrides: ["7:44": KeyOverride(profileID: "other")], enabled: true)
        let overridden = renderStroke(changed.audio, usage: 44)
        let generic = renderStroke(reference.audio, usage: 4)
        XCTAssertEqual(overridden.press, generic.press); XCTAssertEqual(overridden.release, generic.release)
    }

    func testExplicitEnterExtraTakesPrecedenceOverMappedProfileEnter() throws {
        var f = try keyFixture(); defer { f.cleanup() }
        f.settings.enterSound = .ding
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        for usage: UInt32 in [40, 88] {
            let pair = renderStroke(f.audio, usage: usage)
            XCTAssertGreaterThan(pair.press.max()!, 0)
            XCTAssertTrue(pair.release.allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(count(f.audio), 2)
    }

    func testKeycapPreviewUsesMappedSetWhileProfilePreviewUsesGeneric() async throws {
        let f = try keyFixture(); defer { f.cleanup() }
        f.audio.preview(profileID: "paired")
        let generic = f.audio.renderOffline(frameCount: 4800)
        try await waitForPreview(); let genericUp = f.audio.renderOffline(frameCount: 4800)
        f.audio.preview(profileID: "paired", keyID: "7:44")
        let space = f.audio.renderOffline(frameCount: 4800)
        try await waitForPreview(); let spaceUp = f.audio.renderOffline(frameCount: 4800)
        XCTAssertEqual(space.max()!, generic.max()! * 1.5, accuracy: 0.00001)
        XCTAssertEqual(spaceUp.min()!, genericUp.min()! * 2.5, accuracy: 0.00001)
        XCTAssertEqual(count(f.audio), 4)
    }

    func testAddingNonreferenceCatalogBanksPreservesExistingNormalizedAudio() throws {
        var f = try fixture(); defer { f.cleanup() }
        f.settings.profileID = "press-only"; f.settings.normalization = true
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        let before = renderStroke(f.audio, usage: 4)
        let additions = (0..<10).map { SoundProfileManifest(id: "catalog-\($0)", name: "Catalog", samples: ["other-release.wav"], releaseSamples: ["release.wav"], normalizationReference: false) }
        try f.audio.load(profiles: f.profiles + additions, assetsURL: f.directory, importsURL: f.directory)
        _ = f.audio.renderOffline(frameCount: 4800)
        let after = renderStroke(f.audio, usage: 4)
        XCTAssertEqual(after.press, before.press)
        XCTAssertEqual(after.release, before.release)
    }

    func testPairedNormalizationPreservesPhaseRatioAndSharesLouderReleaseHeadroom() throws {
        var f = try fixture(); defer { f.cleanup() }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        buffer.frameLength = 960
        for i in 0..<960 { buffer.floatChannelData![0][i] = -0.8 }
        do {
            let file = try AVAudioFile(forWriting: f.directory.appendingPathComponent("release.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        try f.audio.load(profiles: f.profiles, assetsURL: f.directory, importsURL: f.directory)
        f.settings.volume = 0.1
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        _ = f.audio.renderOffline(frameCount: 4800)
        let raw = renderStroke(f.audio, usage: 4)
        f.settings.normalization = true
        f.audio.update(settings: f.settings, keyOverrides: [:], enabled: true)
        let normalized = renderStroke(f.audio, usage: 4)
        let rawRatio = abs(raw.release.min()!) / raw.press.max()!
        let normalizedRatio = abs(normalized.release.min()!) / normalized.press.max()!
        XCTAssertEqual(rawRatio, 8 * 0.7, accuracy: 0.00001)
        XCTAssertEqual(normalizedRatio, rawRatio, accuracy: 0.00001)
        XCTAssertEqual(normalized.press.max()!, raw.press.max()! * (0.65 / 0.8), accuracy: 0.00001)
        XCTAssertEqual(abs(normalized.release.min()!), 0.65 * 0.1 * 2 * 0.7 / sqrt(2), accuracy: 0.00001)
    }

    func testSustainedOverlappingPairedStrokesStayBoundedWithoutDroppedTriggers() throws {
        let f = try fixture(); defer { f.cleanup() }
        var maximum: Float = 0
        // One down every 10 ms, with its physical up 30 ms later. Drain the
        // last three held keys after 500 downs while rendering each interval.
        for interval in 0..<503 {
            if interval < 500 {
                f.audio.trigger(event(.down, usage: UInt32(4 + interval % 26)))
            }
            if interval >= 3 {
                f.audio.trigger(event(.up, usage: UInt32(4 + (interval - 3) % 26)))
            }
            let output = f.audio.renderOffline(frameCount: 480)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            maximum = max(maximum, output.map(abs).max()!)
        }
        let diagnostics = f.audio.diagnostics
        XCTAssertEqual(diagnostics.acceptedTriggers, 1000)
        XCTAssertEqual(diagnostics.droppedTriggers, 0)
        XCTAssertEqual(diagnostics.stolenVoices, 0)
        XCTAssertGreaterThan(maximum, 0)
        XCTAssertLessThan(maximum, 1)
    }

    func testRejectedPressCannotArmRelease() async throws {
        let f = try fixture(); defer { f.cleanup() }
        for index in 0..<(Int(CA_QUEUE_CAPACITY) - 1) { f.audio.trigger(event(.down, device: UInt64(index + 10))) }
        let accepted = count(f.audio)
        f.audio.trigger(event(.down)); f.audio.preview(profileID: "paired")
        XCTAssertEqual(count(f.audio), accepted)
        XCTAssertEqual(f.audio.diagnostics.droppedTriggers, 2)
        _ = f.audio.renderOffline(frameCount: 4800)
        f.audio.trigger(event(.up))
        try await waitForPreview(); XCTAssertEqual(count(f.audio), accepted)
    }
}
