import Foundation

public enum InputPhase: String, Sendable, Codable { case down, up }

public struct KeyModifiers: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
    public static let function = KeyModifiers(rawValue: 16)
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "") + (contains(.function) ? "fn " : "")
    }
}

public struct PhysicalInputEvent: Sendable, Codable, Equatable {
    public var usagePage: UInt32
    public var usage: UInt32
    public var deviceID: UInt64
    public var phase: InputPhase
    public var modifiers: KeyModifiers
    public var timestamp: Double
    public init(usagePage: UInt32 = 7, usage: UInt32, deviceID: UInt64 = 0, phase: InputPhase, modifiers: KeyModifiers = [], timestamp: Double = ProcessInfo.processInfo.systemUptime) {
        self.usagePage = usagePage; self.usage = usage; self.deviceID = deviceID
        self.phase = phase; self.modifiers = modifiers; self.timestamp = timestamp
    }
    public var keyID: String { "\(usagePage):\(usage)" }
    public var isMouse: Bool { usagePage == 9 }
}

public struct SampleProvenance: Sendable, Codable, Equatable {
    public var source: String
    public var sectionStart: Double?
    public var sectionEnd: Double?
    public init(source: String, sectionStart: Double? = nil, sectionEnd: Double? = nil) { self.source = source; self.sectionStart = sectionStart; self.sectionEnd = sectionEnd }
}

public struct SoundSampleSet: Sendable, Codable, Equatable {
    public var samples: [String]
    public var releaseSamples: [String]?
    public init(samples: [String], releaseSamples: [String]? = nil) {
        self.samples = samples; self.releaseSamples = releaseSamples
    }
}

public struct SoundProfileManifest: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var color: String
    public var samples: [String]
    public var releaseSamples: [String]?
    public var keySamples: [String: SoundSampleSet]?
    public var gain: Float
    public var provenance: SampleProvenance?
    /// Omitted for legacy profiles; catalog additions can preserve that corpus's
    /// normalization target without changing the loudness of existing profiles.
    public var normalizationReference: Bool?
    public var samplePaths: [String] {
        Array(Set(samples + (releaseSamples ?? []) + (keySamples ?? [:]).values.flatMap { $0.samples + ($0.releaseSamples ?? []) })).sorted()
    }
    public init(id: String, name: String, subtitle: String = "", color: String = "E99244", samples: [String] = [], releaseSamples: [String]? = nil, keySamples: [String: SoundSampleSet]? = nil, gain: Float = 1, provenance: SampleProvenance? = nil, normalizationReference: Bool? = nil) {
        self.id = id; self.name = name; self.subtitle = subtitle; self.color = color
        self.samples = samples; self.releaseSamples = releaseSamples; self.keySamples = keySamples
        self.gain = gain; self.provenance = provenance; self.normalizationReference = normalizationReference
    }
}

public enum ExtraSound: String, Sendable, Codable, CaseIterable, Identifiable {
    case none, soft, crisp, hard, ding, typewriter, custom
    case razerOrochiV2 = "razer-orochi-v2"
    public static let bundledSamples: [ExtraSound] = [.soft, .crisp, .hard, .ding, .typewriter]
    public var id: String { rawValue }
    public var title: String { self == .razerOrochiV2 ? "Razer Orochi V2" : rawValue.capitalized }
    public var mouseProfileID: String? { self == .razerOrochiV2 ? rawValue : nil }
}

public struct ImportedSound: Sendable, Codable, Equatable {
    public var name: String
    public var pressPath: String
    public var releasePath: String?
    public init(name: String, pressPath: String, releasePath: String? = nil) { self.name = name; self.pressPath = pressPath; self.releasePath = releasePath }
}

public enum ModifierSoundMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case soft, silent, full
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct SoundSettings: Sendable, Codable, Equatable {
    public var profileID = "thocky"
    public var volume: Float = 0.4
    public var tone: Float = 0
    public var pitch: Float = 0
    public var spatial = true
    public var spatialWidth: Float = 0.8
    public var normalization = true
    public var variation = true
    public var homeRowSoftness: Float = 0.15
    public var modifierSoundMode: ModifierSoundMode = .soft
    public var pauseOnHeadphones = false
    public var outputDeviceUID: String? = nil
    public var orbit = false
    public var headTracking = false
    public var mouseSound: ExtraSound = .soft
    public var mouseVolume: Float = 0.25
    public var enterSound: ExtraSound = .none
    public var enterVolume: Float = 0.4
    public var customMouse: ImportedSound? = nil
    public var customEnter: ImportedSound? = nil
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case profileID, volume, tone, pitch, spatial, spatialWidth, normalization, variation
        case homeRowSoftness, modifierSoundMode, pauseOnHeadphones, outputDeviceUID, orbit, headTracking
        case mouseSound, mouseVolume, enterSound, enterVolume, customMouse, customEnter
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID) ?? profileID
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? volume
        tone = try values.decodeIfPresent(Float.self, forKey: .tone) ?? tone
        pitch = try values.decodeIfPresent(Float.self, forKey: .pitch) ?? pitch
        spatial = try values.decodeIfPresent(Bool.self, forKey: .spatial) ?? spatial
        spatialWidth = try values.decodeIfPresent(Float.self, forKey: .spatialWidth) ?? spatialWidth
        normalization = try values.decodeIfPresent(Bool.self, forKey: .normalization) ?? normalization
        variation = try values.decodeIfPresent(Bool.self, forKey: .variation) ?? variation
        homeRowSoftness = try values.decodeIfPresent(Float.self, forKey: .homeRowSoftness) ?? homeRowSoftness
        // Existing schema-1 configurations and favorite sound snapshots omitted
        // this field. Migrate just the absent preference to the new soft default.
        modifierSoundMode = try values.decodeIfPresent(ModifierSoundMode.self, forKey: .modifierSoundMode) ?? .soft
        pauseOnHeadphones = try values.decodeIfPresent(Bool.self, forKey: .pauseOnHeadphones) ?? pauseOnHeadphones
        outputDeviceUID = try values.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        orbit = try values.decodeIfPresent(Bool.self, forKey: .orbit) ?? orbit
        headTracking = try values.decodeIfPresent(Bool.self, forKey: .headTracking) ?? headTracking
        mouseSound = try values.decodeIfPresent(ExtraSound.self, forKey: .mouseSound) ?? mouseSound
        mouseVolume = try values.decodeIfPresent(Float.self, forKey: .mouseVolume) ?? mouseVolume
        enterSound = try values.decodeIfPresent(ExtraSound.self, forKey: .enterSound) ?? enterSound
        enterVolume = try values.decodeIfPresent(Float.self, forKey: .enterVolume) ?? enterVolume
        customMouse = try values.decodeIfPresent(ImportedSound.self, forKey: .customMouse)
        customEnter = try values.decodeIfPresent(ImportedSound.self, forKey: .customEnter)
    }
}

public struct KeyOverride: Sendable, Codable, Equatable {
    public var profileID: String?
    public var tone: Float?
    public var pitch: Float?
    public var volume: Float?
    public init(profileID: String? = nil, tone: Float? = nil, pitch: Float? = nil, volume: Float? = nil) {
        self.profileID = profileID; self.tone = tone; self.pitch = pitch; self.volume = volume
    }
}

public enum VisualizerStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case keyboard, keystrokes, combo, bezel
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String { switch self { case .keyboard: return "keyboard"; case .keystrokes: return "command.square"; case .combo: return "flame"; case .bezel: return "rectangle.inset.filled" } }
}
public enum VisualizerPlacement: String, Sendable, Codable, CaseIterable, Identifiable {
    case cursor, topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight, random
    public var id: String { rawValue }
    public var title: String { switch self {
        case .cursor: return "Follow cursor"; case .topLeft: return "Top left"; case .topCenter: return "Top center"; case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"; case .bottomCenter: return "Bottom center"; case .bottomRight: return "Bottom right"; case .random: return "Random"
    } }
}
public enum VisualizerTheme: String, Sendable, Codable, CaseIterable, Identifiable {
    case graphite, porcelain, amber, glassDark, glassClear
    public var id: String { rawValue }
    public var title: String { switch self { case .glassDark: return "Glass dark"; case .glassClear: return "Glass clear"; default: return rawValue.capitalized } }
}
public enum ShuffleMotion: String, Sendable, Codable, CaseIterable, Identifiable {
    case pop, slide, bounce, pulse
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
public struct VisualizerSettings: Sendable, Codable, Equatable {
    public var enabled = false
    public var style: VisualizerStyle = .keyboard
    public var placement: VisualizerPlacement = .cursor
    public var theme: VisualizerTheme = .graphite
    public var scale: Double = 1
    public var offset: Double = 28
    public var dismissDelay: Double = 1
    public var hideInFullscreen = true
    public var notchEnabled = false
    public var displayID: String? = nil
    public var shuffleEvery = 5
    public var shuffleMotion: ShuffleMotion = .pop
    public var comboTimeout: Double = 2
    public var keepCombo = false
    public var keepVisible = false
    public var verticalKeystrokes = false
    public init() {}
}

public struct ShortcutConfiguration: Sendable, Codable, Equatable {
    public var usage: UInt32 = 14
    public var modifiers: KeyModifiers = .command
    public var tapCount = 3
    public var interval: Double = 1
    public init() {}
    public var label: String { modifiers.symbols + " " + String(repeating: KeyboardLayout.label(for: usage), count: max(1, min(tapCount, 5))) }
}
public struct GeneralSettings: Sendable, Codable, Equatable {
    public var launchAtLogin = false
    public var showInDock = false
    public var showMenuBar = true
    public var shortcut = ShortcutConfiguration()
    public init() {}
}
public struct Favorite: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var sound: SoundSettings
    public var keyOverrides: [String: KeyOverride]
    public init(name: String, sound: SoundSettings, keyOverrides: [String: KeyOverride] = [:]) {
        self.id = UUID(); self.name = name; self.sound = sound; self.keyOverrides = keyOverrides
    }
}
public struct AppConfiguration: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var enabled = true
    public var sound = SoundSettings()
    public var visualizer = VisualizerSettings()
    public var general = GeneralSettings()
    public var keyOverrides: [String: KeyOverride] = [:]
    public var favorites: [Favorite] = []
    public init() {}
}

public struct AudioOutputDevice: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var isHeadphones: Bool
    public init(id: String, name: String, isHeadphones: Bool) { self.id = id; self.name = name; self.isHeadphones = isHeadphones }
}
