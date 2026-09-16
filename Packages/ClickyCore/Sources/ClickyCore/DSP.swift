import Foundation
import AVFoundation

public enum AudioSampleError: LocalizedError {
    case unreadable(String), tooLong, empty, bankFull, engine(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Could not read the sound file \(name)."
        case .tooLong: return "Choose a sound no longer than 15 seconds."
        case .empty: return "This sound file contains no audio."
        case .bankFull: return "The sound cache is full. Restart Clicky to load more imported sounds."
        case .engine(let message): return "Audio output: \(message)"
        }
    }
}

/// Decoding happens on the loading queue, never in the real-time callback.
public struct DecodedAudioSample: Sendable {
    public let frames: [Float]
    public let sampleRate: Double
    public let rms: Float
    public let peak: Float

    public static func read(url: URL) throws -> DecodedAudioSample {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw AudioSampleError.unreadable(url.lastPathComponent) }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { throw AudioSampleError.empty }
        guard Double(file.length) / rate <= 15 else { throw AudioSampleError.tooLong }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioSampleError.unreadable(url.lastPathComponent)
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw AudioSampleError.empty }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var frames = [Float](repeating: 0, count: count)
        var energy: Double = 0
        var peak: Float = 0
        for i in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][i] / Float(channelCount) }
            value = value.isFinite ? min(1, max(-1, value)) : 0
            frames[i] = value; energy += Double(value * value); peak = max(peak, abs(value))
        }
        return DecodedAudioSample(frames: frames, sampleRate: rate, rms: Float(sqrt(energy / Double(count))), peak: peak)
    }
}

public struct AudioDiagnostics: Sendable {
    public let renderedFrames: UInt64
    public let acceptedTriggers: UInt64
    public let droppedTriggers: UInt64
    public let stolenVoices: UInt64
    public let activeVoices: UInt32
    public let sampleCount: UInt32
    public let outputSampleRate: Double
    public let bufferFrameSize: UInt32
    public let renderBlockFrameSize: UInt32
    public var requestedBufferDuration: Double { outputSampleRate > 0 ? Double(bufferFrameSize) / outputSampleRate : 0 }
}

enum AudioSampleSelector {
    /// A deterministic selection primitive lets tests verify no immediate repeats.
    static func index(count: Int, excluding previous: Int?, random: UInt32) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, let previous, (0..<count).contains(previous) else { return Int(random) % count }
        let selected = Int(random) % (count - 1)
        return selected >= previous ? selected + 1 : selected
    }
}

enum AudioNormalization {
    static func gain(rms: Float, peak: Float, profileGain: Float, targetRMS: Float, silent: Bool) -> Float {
        guard rms > 0.00001, peak > 0, profileGain > 0 else { return 1 }
        // Partial RMS correction retains natural stroke differences. Leave at least
        // 3.7 dB sample headroom before overlap, panning and the final limiter.
        let correction = powf(targetRMS / (rms * profileGain), 0.75)
        return min(silent ? 1 : 1.8, 0.65 / (peak * profileGain), max(0.5, correction))
    }
}

enum AudioMixParameters {
    // Prepared recording assets retain 0.32 extraction gain for PCM headroom.
    // Restore 6 dB at playback after normalization; apply equally to every
    // keyboard profile, including Silent, without altering independent extras.
    static let keyboardPlaybackCalibration: Float = 2

    static func profileGain(sliderGain: Float, manifestGain: Float, normalization: Float, variation: Float) -> Float {
        sliderGain * manifestGain * normalization * variation * keyboardPlaybackCalibration
    }

    static func typingGain(volume: Float, override: Float?, isHomeRow: Bool, softness: Float, modifierGain: Float = 1) -> Float {
        let volume = override ?? volume
        return volume * (isHomeRow ? 1 - softness : 1) * modifierGain
    }

    static func modifierGain(for event: PhysicalInputEvent, mode: ModifierSoundMode) -> Float {
        guard event.usagePage == 7, !KeyboardLayout.modifier(for: event.usage).isEmpty else { return 1 }
        switch mode {
        case .soft: return 0.25
        case .silent: return 0
        case .full: return 1
        }
    }

    static func pan(position: Float, width: Float, headphones: Bool, orbitOffset: Float, headYaw: Double) -> Float {
        let keyboard = position * width * (headphones ? 0.55 : 1)
        return max(-1, min(1, keyboard + orbitOffset - Float(headYaw / (.pi / 2))))
    }
}

struct AudioReleaseTracker<Payload> {
    private struct Key: Hashable { let device: UInt64; let page: UInt32; let usage: UInt32 }
    private var pending: [Key: Payload] = [:]
    private var held: [Key: PhysicalInputEvent] = [:]
    mutating func beginPress(for event: PhysicalInputEvent) -> Bool {
        let key = Key(device: event.deviceID, page: event.usagePage, usage: event.usage)
        guard held[key] == nil else { return false }
        held[key] = event
        return true
    }
    mutating func remember(_ payload: Payload?, for event: PhysicalInputEvent) {
        let key = Key(device: event.deviceID, page: event.usagePage, usage: event.usage)
        held[key] = event; pending[key] = payload
    }
    mutating func release(for event: PhysicalInputEvent) -> Payload? {
        let key = Key(device: event.deviceID, page: event.usagePage, usage: event.usage)
        held.removeValue(forKey: key)
        return pending.removeValue(forKey: key)
    }
    mutating func removeReleases(where shouldRemove: (PhysicalInputEvent, Payload) -> Bool) {
        pending = pending.filter { key, payload in
            guard let event = held[key] else { return false }
            return !shouldRemove(event, payload)
        }
    }
    mutating func reset() { pending.removeAll(keepingCapacity: true); held.removeAll(keepingCapacity: true) }
}
