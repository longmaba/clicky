import Foundation

public enum ConfigurationError: LocalizedError {
    case unsupportedVersion(Int)
    public var errorDescription: String? { switch self { case .unsupportedVersion(let v): return "These settings were saved by a newer version of Clicky (format \(v))." } }
}

public final class ConfigurationStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("configuration.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppConfiguration() }
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fileURL))
        guard config.schemaVersion == 1 else { throw ConfigurationError.unsupportedVersion(config.schemaVersion) }
        return config.validated()
    }
    public func save(_ config: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config.validated()).write(to: fileURL, options: .atomic)
    }
}

extension AppConfiguration {
    public func validated() -> AppConfiguration {
        var c = self
        func unit(_ v: Float, _ fallback: Float) -> Float { v.isFinite ? min(1,max(0,v)) : fallback }
        func bipolar(_ v: Float) -> Float { v.isFinite ? min(1,max(-1,v)) : 0 }
        c.sound.volume = unit(c.sound.volume, 0.4); c.sound.mouseVolume = unit(c.sound.mouseVolume, 0.25); c.sound.enterVolume = unit(c.sound.enterVolume, 0.4)
        c.sound.tone = bipolar(c.sound.tone); c.sound.pitch = bipolar(c.sound.pitch)
        c.sound.spatialWidth = unit(c.sound.spatialWidth,0.8); c.sound.homeRowSoftness = unit(c.sound.homeRowSoftness,0.15)
        c.visualizer.scale = c.visualizer.scale.isFinite ? min(2,max(0.5,c.visualizer.scale)) : 1
        c.visualizer.offset = min(150,max(0,c.visualizer.offset))
        c.visualizer.dismissDelay = min(5,max(0.3,c.visualizer.dismissDelay))
        c.visualizer.comboTimeout = min(30,max(0.3,c.visualizer.comboTimeout))
        c.visualizer.shuffleEvery = min(100,max(1,c.visualizer.shuffleEvery))
        c.general.shortcut.tapCount = min(5,max(1,c.general.shortcut.tapCount))
        c.general.shortcut.interval = min(3,max(0.3,c.general.shortcut.interval))
        c.favorites = Array(c.favorites.prefix(6))
        c.keyOverrides = c.keyOverrides.mapValues { value in
            var v = value; v.volume = v.volume.map { unit($0,0.4) }; v.tone = v.tone.map(bipolar); v.pitch = v.pitch.map(bipolar); return v
        }
        return c
    }
}
