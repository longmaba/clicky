import XCTest
import CClickyAudio
import AVFoundation
@testable import ClickyCore

final class AudioTests: XCTestCase {
    func testDerivedReleaseIsShorterSofterAndHasCleanEdges() throws {
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets")
        let profiles = try JSONDecoder().decode([SoundProfileManifest].self,
            from: Data(contentsOf: assets.appendingPathComponent("profiles.json")))
        for profile in profiles {
            for path in profile.samples {
                let press = try DecodedAudioSample.read(url: assets.appendingPathComponent(path))
                let release = press.releaseStroke()
                XCTAssertLessThanOrEqual(Double(release.frames.count) / release.sampleRate, 0.045)
                XCTAssertLessThan(release.frames.count, press.frames.count)
                XCTAssertGreaterThan(release.rms, 0, path)
                XCTAssertLessThan(release.rms, press.rms, path)
                XCTAssertLessThanOrEqual(release.peak, press.peak * 0.45, path)
                XCTAssertEqual(release.frames.first, 0)
                XCTAssertEqual(release.frames.last, 0)
                XCTAssertTrue(release.frames.allSatisfy(\.isFinite))
            }
        }
    }

    private func makeMixer() -> OpaquePointer { ca_mixer_create(48000)! }
    private func sample(_ mixer: OpaquePointer, count: Int = 4800, amplitude: Float = 0.5) -> UInt32 {
        let angularStep: Float = .pi * 2 * 440 / 48000
        let data = (0..<count).map { amplitude * sin(Float($0) * angularStep) }
        return data.withUnsafeBufferPointer { UInt32(ca_mixer_add_sample(mixer, $0.baseAddress, UInt32($0.count), 48000)) }
    }
    private func render(_ mixer: OpaquePointer, count: Int) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: count), r = l
        l.withUnsafeMutableBufferPointer { left in r.withUnsafeMutableBufferPointer { right in
            ca_mixer_render(mixer, left.baseAddress, right.baseAddress, UInt32(count), 1)
        } }
        return (l, r)
    }
    private func trigger(_ id: UInt32, gain: Float = 1, pan: Float = 0, pitch: Float = 1, tone: Float = 0, audition: Bool = false) -> CATrigger {
        CATrigger(sample: id, gain: gain, pan: pan, pitch: pitch, tone: tone, audition: audition)
    }

    func testPanningPreservesPowerAndPositionsEdges() {
        for step in -10...10 {
            var left: Float = 0, right: Float = 0
            ca_pan_gains(Float(step) / 10, &left, &right)
            XCTAssertEqual(left * left + right * right, 1, accuracy: 0.00001)
            if step == -10 { XCTAssertEqual(left, 1, accuracy: 0.00001); XCTAssertEqual(right, 0, accuracy: 0.00001) }
            if step == 10 { XCTAssertEqual(left, 0, accuracy: 0.00001); XCTAssertEqual(right, 1, accuracy: 0.00001) }
        }
    }

    func testMixerOwnsSampleMemoryAfterSourceIsChangedAndReleased() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        var source = [Float](repeating: 0.5, count: 1024)
        let id = source.withUnsafeBufferPointer { ca_mixer_add_sample(mixer, $0.baseAddress, UInt32($0.count), 48000) }
        source = [Float](repeating: -0.5, count: 1024)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(UInt32(id))))
        let output = render(mixer, count: 512)
        XCTAssertGreaterThan(output.0[256], 0.1)
        XCTAssertEqual(output.0, output.1)
        XCTAssertEqual(ca_mixer_stats(mixer).sampleCount, 1)
        XCTAssertEqual(source[0], -0.5)
    }

    func testBoundedQueueDropsWithoutOverwritingAndLimitsVoices() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        let id = sample(mixer)
        for _ in 0..<(Int(CA_QUEUE_CAPACITY) - 1) { XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id))) }
        XCTAssertFalse(ca_mixer_enqueue(mixer, trigger(id)))
        XCTAssertEqual(ca_mixer_stats(mixer).droppedTriggers, 1)
        let output = render(mixer, count: 256)
        let stats = ca_mixer_stats(mixer)
        XCTAssertEqual(stats.acceptedTriggers, UInt64(CA_QUEUE_CAPACITY - 1))
        XCTAssertEqual(stats.activeVoices, UInt32(CA_MAX_VOICES))
        XCTAssertEqual(stats.stolenVoices, UInt64(CA_QUEUE_CAPACITY - 1 - CA_MAX_VOICES))
        XCTAssertLessThan(output.0.map(abs).max()!, 1)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id)))
    }

    func testPitchChangesDurationAndSampleRateConversion() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        let id = sample(mixer, count: 4800)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, pitch: 2)))
        _ = render(mixer, count: 2401)
        XCTAssertEqual(ca_mixer_stats(mixer).activeVoices, 0)
        ca_mixer_set_sample_rate(mixer, 96000)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id)))
        _ = render(mixer, count: 4801)
        XCTAssertEqual(ca_mixer_stats(mixer).activeVoices, 1)
        _ = render(mixer, count: 4800)
        XCTAssertEqual(ca_mixer_stats(mixer).activeVoices, 0)
    }

    func testAuditionBypassesDisabledCapture() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        let id = sample(mixer)
        ca_mixer_set_enabled(mixer, false)
        _ = render(mixer, count: 4800)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id)))
        let muted = render(mixer, count: 512)
        XCTAssertLessThan(muted.0.map(abs).max()!, 0.00001)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, audition: true)))
        let audition = render(mixer, count: 512)
        XCTAssertGreaterThan(audition.0.map(abs).max()!, 0.1)
    }

    func testLimiterTransparentBelowKneeAndBoundedUnderExtremeOverlap() {
        XCTAssertEqual(ca_limit(0.3), 0.3)
        XCTAssertEqual(ca_limit(-0.3), -0.3)
        for value in [Float(0.7), 1, 4, 100, 1000] {
            XCTAssertLessThan(ca_limit(value), 1)
            XCTAssertEqual(ca_limit(-value), -ca_limit(value), accuracy: 0.000001)
        }
    }

    func testHundredTriggersPerSecondForFiveSecondsWithoutDropsOrClipping() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        let id = sample(mixer)
        var maximum: Float = 0
        for index in 0..<500 {
            XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, pan: Float(index % 21 - 10) / 10, pitch: 0.9 + Float(index % 3) * 0.1)))
            let output = render(mixer, count: 480)
            maximum = max(maximum, output.0.map(abs).max()!, output.1.map(abs).max()!)
        }
        let stats = ca_mixer_stats(mixer)
        XCTAssertEqual(stats.acceptedTriggers, 500)
        XCTAssertEqual(stats.droppedTriggers, 0)
        XCTAssertEqual(stats.stolenVoices, 0)
        XCTAssertEqual(stats.renderedFrames, 240000)
        XCTAssertLessThan(maximum, 1)
    }

    func testInterleavedBuffersAndClearingVoices() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        let id = sample(mixer)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, pan: -1)))
        var data = [Float](repeating: 0, count: 1024)
        data.withUnsafeMutableBufferPointer { ca_mixer_render(mixer, $0.baseAddress, $0.baseAddress! + 1, 512, 2) }
        XCTAssertGreaterThan(stride(from: 0, to: data.count, by: 2).map { abs(data[$0]) }.max()!, 0.1)
        XCTAssertEqual(stride(from: 1, to: data.count, by: 2).map { abs(data[$0]) }.max()!, 0)
        ca_mixer_clear(mixer)
        let silence = render(mixer, count: 512)
        XCTAssertTrue(silence.0.allSatisfy { $0 == 0 })
        XCTAssertEqual(ca_mixer_stats(mixer).activeVoices, 0)
    }

    func testDecodedStereoFileMixesToMonoAndRejectsMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-decoder-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for i in 0..<480 { buffer.floatChannelData![0][i] = 0.6; buffer.floatChannelData![1][i] = 0.2 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let decoded = try DecodedAudioSample.read(url: url)
        XCTAssertEqual(decoded.frames.count, 480)
        XCTAssertEqual(decoded.sampleRate, 48000)
        XCTAssertEqual(decoded.peak, 0.4, accuracy: 0.00001)
        XCTAssertEqual(decoded.rms, 0.4, accuracy: 0.00001)
        XCTAssertThrowsError(try DecodedAudioSample.read(url: url.appendingPathExtension("missing")))
    }

    func testInvalidSampleAndTriggerAreRejected() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        XCTAssertEqual(ca_mixer_add_sample(mixer, nil, 1, 48000), -1)
        XCTAssertFalse(ca_mixer_enqueue(mixer, trigger(99)))
        let id = sample(mixer)
        XCTAssertFalse(ca_mixer_enqueue(mixer, trigger(id, gain: .nan)))
    }

    func testVariationNeverRepeatsPreviousSampleAndHandlesTinyBanks() {
        XCTAssertNil(AudioSampleSelector.index(count: 0, excluding: nil, random: 0))
        XCTAssertEqual(AudioSampleSelector.index(count: 1, excluding: 0, random: .max), 0)
        for previous in 0..<6 {
            var selected: Set<Int> = []
            for random in UInt32(0)..<100 {
                let index = AudioSampleSelector.index(count: 6, excluding: previous, random: random)!
                XCTAssertNotEqual(index, previous)
                XCTAssertTrue((0..<6).contains(index))
                selected.insert(index)
            }
            XCTAssertEqual(selected.count, 5)
        }
    }

    func testReleasePairsRememberPressConfigurationAndSeparateDevices() {
        var tracker = AudioReleaseTracker<String>()
        let first = PhysicalInputEvent(usage: 40, deviceID: 1, phase: .down)
        let second = PhysicalInputEvent(usage: 40, deviceID: 2, phase: .down)
        tracker.remember("original-release.wav", for: first)
        tracker.remember("new-release.wav", for: second)
        XCTAssertEqual(tracker.release(for: first), "original-release.wav")
        XCTAssertNil(tracker.release(for: first))
        XCTAssertEqual(tracker.release(for: second), "new-release.wav")
        tracker.remember("held.wav", for: first)
        tracker.reset()
        XCTAssertNil(tracker.release(for: first))
        tracker.remember(nil, for: second) // whole-stroke sample has no extra release
        XCTAssertNil(tracker.release(for: second))
    }

    func testNormalizationBalancesProfilesPreservesSilentAndLeavesHeadroom() {
        let quiet = AudioNormalization.gain(rms: 0.04, peak: 0.3, profileGain: 1, targetRMS: 0.07, silent: false)
        let loud = AudioNormalization.gain(rms: 0.11, peak: 0.6, profileGain: 1, targetRMS: 0.07, silent: false)
        XCTAssertGreaterThan(quiet, 1)
        XCTAssertLessThan(loud, 1)
        XCTAssertLessThan(abs(0.04 * quiet - 0.11 * loud), 0.11 - 0.04)
        XCTAssertLessThanOrEqual(AudioNormalization.gain(rms: 0.006, peak: 0.06, profileGain: 1, targetRMS: 0.07, silent: true), 1)
        XCTAssertLessThanOrEqual(AudioNormalization.gain(rms: 0.02, peak: 0.95, profileGain: 1.5, targetRMS: 0.07, silent: false) * 0.95 * 1.5, 0.65001)
    }

    func testMatchingAbsoluteKeyOverrideKeepsOutputUnchanged() {
        let baseline = makeMixer(), overridden = makeMixer()
        defer { ca_mixer_destroy(baseline); ca_mixer_destroy(overridden) }
        let first = sample(baseline), second = sample(overridden)
        ca_mixer_set_gain(baseline, 1); ca_mixer_set_gain(overridden, 1)
        let inherited = AudioMixParameters.typingGain(volume: 0.4, override: nil, isHomeRow: true, softness: 0.15)
        let explicit = AudioMixParameters.typingGain(volume: 0.4, override: 0.4, isHomeRow: true, softness: 0.15)
        XCTAssertTrue(ca_mixer_enqueue(baseline, trigger(first, gain: inherited)))
        XCTAssertTrue(ca_mixer_enqueue(overridden, trigger(second, gain: explicit)))
        let inheritedOutput = render(baseline, count: 512)
        let explicitOutput = render(overridden, count: 512)
        XCTAssertEqual(inheritedOutput.0, explicitOutput.0)
        XCTAssertGreaterThan(explicitOutput.0.map(abs).max()!, 0.03)
        // An override is still audible when the overall typing volume is zero.
        XCTAssertGreaterThan(AudioMixParameters.typingGain(volume: 0, override: 0.4, isHomeRow: false, softness: 0.15), 0)
    }

    func testZeroTypingVolumeLeavesIndependentMouseVolumeAudible() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        ca_mixer_set_gain(mixer, 1)
        let id = sample(mixer)
        let typing = AudioMixParameters.typingGain(volume: 0, override: nil, isHomeRow: false, softness: 0.15)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, gain: typing)))
        XCTAssertTrue(render(mixer, count: 512).0.allSatisfy { $0 == 0 })
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, gain: 0.25)))
        XCTAssertGreaterThan(render(mixer, count: 512).0.map(abs).max()!, 0.05)
    }

    func testHeadphoneStageNarrowsKeyboardButRetainsOrientationAndOrbit() {
        for side: Float in [-1, 1] {
            let speaker = AudioMixParameters.pan(position: side, width: 0.8, headphones: false, orbitOffset: 0, headYaw: 0)
            let headphone = AudioMixParameters.pan(position: side, width: 0.8, headphones: true, orbitOffset: 0, headYaw: 0)
            XCTAssertLessThan(abs(headphone), abs(speaker))
            XCTAssertGreaterThan(headphone * side, 0)
        }
        let orbit = AudioMixParameters.pan(position: 0, width: 0.8, headphones: true, orbitOffset: 0.3, headYaw: 0)
        XCTAssertGreaterThan(orbit, 0)
        let turned = AudioMixParameters.pan(position: 0, width: 0.8, headphones: true, orbitOffset: 0, headYaw: .pi / 4)
        XCTAssertLessThan(turned, 0)
        XCTAssertLessThanOrEqual(abs(AudioMixParameters.pan(position: 1, width: 1, headphones: true, orbitOffset: 0.5, headYaw: -.pi)), 1)
    }

    func testKeyboardCalibrationAddsSixDecibelsAfterNormalization() {
        let old = makeMixer(), calibrated = makeMixer()
        defer { ca_mixer_destroy(old); ca_mixer_destroy(calibrated) }
        let oldSample = sample(old), newSample = sample(calibrated)
        ca_mixer_set_gain(old, 1); ca_mixer_set_gain(calibrated, 1)
        _ = render(old, count: 4800); _ = render(calibrated, count: 4800)
        let oldGain: Float = 0.4 * 0.85 * 0.9
        let newGain = AudioMixParameters.profileGain(sliderGain: 0.4 * 0.85, manifestGain: 1, normalization: 0.9, variation: 1)
        XCTAssertTrue(ca_mixer_enqueue(old, trigger(oldSample, gain: oldGain)))
        XCTAssertTrue(ca_mixer_enqueue(calibrated, trigger(newSample, gain: newGain)))
        let previous = render(old, count: 512).0
        let updated = render(calibrated, count: 512).0
        for i in previous.indices { XCTAssertEqual(updated[i], previous[i] * 2, accuracy: 0.000001) }
        let ratio = updated.map(abs).max()! / previous.map(abs).max()!
        XCTAssertEqual(20 * log10(ratio), 6.0206, accuracy: 0.001)
        // A common calibration keeps Silent's original relative level intact.
        XCTAssertEqual(AudioMixParameters.profileGain(sliderGain: 0.4, manifestGain: 1, normalization: 1, variation: 1), 0.8)
    }

    func testCalibratedFullVolumeOverlapRemainsBounded() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        ca_mixer_set_gain(mixer, 1)
        let id = sample(mixer)
        let gain = AudioMixParameters.profileGain(sliderGain: 1, manifestGain: 1, normalization: 1.8, variation: 1)
        for _ in 0..<96 { XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(id, gain: gain))) }
        let output = render(mixer, count: 1024)
        XCTAssertLessThan(output.0.map(abs).max()!, 1)
        XCTAssertTrue(output.0.allSatisfy(\.isFinite))
        XCTAssertEqual(ca_mixer_stats(mixer).droppedTriggers, 0)
    }

    func testMixerBeginsOnFirstFrameAndReportsActualBlockSize() {
        let mixer = makeMixer(); defer { ca_mixer_destroy(mixer) }
        let frames = [Float](repeating: 0.5, count: 1024)
        let id = frames.withUnsafeBufferPointer { ca_mixer_add_sample(mixer, $0.baseAddress, UInt32($0.count), 48000) }
        ca_mixer_set_gain(mixer, 1)
        _ = render(mixer, count: 4800)
        XCTAssertTrue(ca_mixer_enqueue(mixer, trigger(UInt32(id))))
        let output = render(mixer, count: 128).0
        XCTAssertGreaterThan(output[0], 0)
        XCTAssertEqual(output[23], output[24], accuracy: 0.000001)
        XCTAssertEqual(ca_mixer_stats(mixer).lastRenderFrames, 128)
        _ = render(mixer, count: 512)
        XCTAssertEqual(ca_mixer_stats(mixer).lastRenderFrames, 512)
    }
}
