import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import CClickyAudio

/// Owns decoding, routing and the single trigger producer. The render callback uses C only.
// Mutable engine/bank state is confined to `queue`; public status access uses
// statusLock. C render state is shared exclusively through lock-free atomics.
public final class AudioController: @unchecked Sendable {
    private struct Sample { let id: UInt32; let rms: Float; var normalization: Float = 1 }
    private struct Bank { let press: [Sample]; let release: [Sample]; let gain: Float }
    private struct Listener { let object: AudioObjectID; var address: AudioObjectPropertyAddress; let block: AudioObjectPropertyListenerBlock }

    private let queue = DispatchQueue(label: "app.clicky.audio", qos: .userInteractive)
    private let loader = DispatchQueue(label: "app.clicky.decode", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let statusLock = NSLock()
    private var statusHandler: ((String?) -> Void)?
    private var headphones = false
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var mixer: OpaquePointer
    private var configurationObserver: NSObjectProtocol?
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var banks: [String: Bank] = [:]
    private var extras: [ExtraSound: Sample] = [:]
    private var imported: [String: Sample] = [:]
    private var importsLoading: Set<String> = []
    private var importsURL: URL?
    private var settings = SoundSettings()
    private var overrides: [String: KeyOverride] = [:]
    private var enabled = true
    private var suspended = false
    private var headYaw: Double = 0
    private var lastSample: [String: UInt32] = [:]
    private var releases = AudioReleaseTracker<CATrigger>()
    private var loadGeneration: UInt64 = 0
    private var rebuildGeneration: UInt64 = 0
    private var ignoreEngineChangesUntil: TimeInterval = 0
    private var outputRate: Double = 48000
    private var outputDeviceID: AudioDeviceID?

    public var onStatus: ((String?) -> Void)? {
        get { statusLock.lock(); defer { statusLock.unlock() }; return statusHandler }
        set { statusLock.lock(); statusHandler = newValue; statusLock.unlock() }
    }
    public var isHeadphones: Bool {
        statusLock.lock(); defer { statusLock.unlock() }; return headphones
    }
    public var diagnostics: AudioDiagnostics {
        queue.sync {
            let stats = ca_mixer_stats(mixer)
            let observedFrames = outputDeviceID.flatMap { AudioDevices.uint32($0, selector: kAudioDevicePropertyBufferFrameSize) } ?? 0
            return AudioDiagnostics(renderedFrames: stats.renderedFrames, acceptedTriggers: stats.acceptedTriggers,
                droppedTriggers: stats.droppedTriggers, stolenVoices: stats.stolenVoices, activeVoices: stats.activeVoices,
                sampleCount: stats.sampleCount, outputSampleRate: outputRate, bufferFrameSize: observedFrames, renderBlockFrameSize: stats.lastRenderFrames)
        }
    }

    public init() {
        guard let mixer = ca_mixer_create(48000) else { fatalError("Cannot allocate the Clicky audio mixer") }
        self.mixer = mixer
        queue.setSpecific(key: queueKey, value: true)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let listener = listen(object: AudioObjectID(kAudioObjectSystemObject), selector: selector) { systemListeners.append(listener) }
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let changedEngine = note.object as? AVAudioEngine else { return }
            self?.queue.async { [weak self, weak changedEngine] in
                guard let self, let changedEngine, changedEngine === self.engine,
                      ProcessInfo.processInfo.systemUptime >= self.ignoreEngineChangesUntil else { return }
                self.scheduleRebuild()
            }
        }
    }

    deinit {
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        let clean = {
            self.removeListeners(self.systemListeners)
            self.removeListeners(self.deviceListeners)
            self.engine?.stop()
            self.engine = nil; self.sourceNode = nil
            ca_mixer_destroy(self.mixer)
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { clean() } else { queue.sync(execute: clean) }
    }

    public func load(profiles: [SoundProfileManifest], assetsURL: URL, importsURL: URL) throws {
        // Decode into temporary storage first so a failed reload retains the working bank.
        var decodedProfiles: [(SoundProfileManifest, [DecodedAudioSample], [DecodedAudioSample])] = []
        for profile in profiles {
            let press = try profile.samples.map { try DecodedAudioSample.read(url: assetsURL.appendingPathComponent($0)) }
            guard !press.isEmpty else { throw AudioSampleError.empty }
            let release = try (profile.releaseSamples ?? []).map { try DecodedAudioSample.read(url: assetsURL.appendingPathComponent($0)) }
            decodedProfiles.append((profile, press, release))
        }
        var decodedExtras: [ExtraSound: DecodedAudioSample] = [:]
        for extra in ExtraSound.allCases where extra != .none && extra != .custom {
            decodedExtras[extra] = try DecodedAudioSample.read(url: assetsURL.appendingPathComponent("Sounds/Extras/\(extra.rawValue).wav"))
        }
        try queue.sync {
            guard let replacement = ca_mixer_create(outputRate) else { throw AudioSampleError.bankFull }
            var newBanks: [String: Bank] = [:]
            var newExtras: [ExtraSound: Sample] = [:]
            let levels = decodedProfiles.filter { $0.0.id != "silent" }.compactMap { profile, press, _ -> Float? in
                let levels = press.map { $0.rms * profile.gain }.sorted()
                return levels.isEmpty ? nil : levels[levels.count / 2]
            }.sorted()
            let targetRMS = levels.isEmpty ? 0.06 : max(0.04, min(0.12, levels[levels.count / 2]))
            do {
                for (profile, press, release) in decodedProfiles {
                    let pressSamples = try register(press, in: replacement, silent: profile.id == "silent", targetRMS: targetRMS, calibration: profile.gain)
                    let releaseSamples: [Sample]
                    if release.isEmpty {
                        let derived = try register(press.map { $0.releaseStroke() }, in: replacement)
                        // Inherit press correction so normalization preserves the softer release.
                        releaseSamples = zip(derived, pressSamples).map { sample, press in
                            Sample(id: sample.id, rms: sample.rms, normalization: press.normalization)
                        }
                    } else {
                        releaseSamples = try register(release, in: replacement, silent: profile.id == "silent", calibration: profile.gain)
                    }
                    newBanks[profile.id] = Bank(press: pressSamples, release: releaseSamples, gain: profile.gain)
                }
                for (extra, decoded) in decodedExtras { newExtras[extra] = try register([decoded], in: replacement).first }
            } catch { ca_mixer_destroy(replacement); throw error }
            engine?.stop(); engine = nil; sourceNode = nil
            ca_mixer_destroy(mixer); mixer = replacement
            banks = newBanks; extras = newExtras; imported.removeAll(); importsLoading.removeAll(); lastSample.removeAll(); releases.reset()
            self.importsURL = importsURL; loadGeneration &+= 1
            loadImports(); rebuildEngine()
        }
    }

    public func update(settings: SoundSettings, keyOverrides: [String: KeyOverride], enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let outputChanged = self.settings.outputDeviceUID != settings.outputDeviceUID
            self.settings = settings; self.overrides = keyOverrides; self.enabled = enabled
            self.applyGain(); self.loadImports()
            if outputChanged { self.scheduleRebuild() }
        }
    }

    public func trigger(_ event: PhysicalInputEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            let savedRelease = event.phase == .up ? self.releases.release(for: event) : nil
            guard self.enabled, !self.suspended, self.engine?.isRunning == true,
                  !(self.settings.pauseOnHeadphones && self.isHeadphones) else { return }
            if event.phase == .up {
                if let savedRelease { _ = ca_mixer_enqueue(self.mixer, savedRelease) }
                return
            }
            let modifierGain = AudioMixParameters.modifierGain(for: event, mode: self.settings.modifierSoundMode)
            guard modifierGain > 0 else {
                self.releases.remember(nil, for: event)
                return
            }
            let press: CATrigger?, release: CATrigger?
            if event.isMouse {
                press = self.extraTrigger(self.settings.mouseSound, importedSound: self.settings.customMouse, phase: .down, volume: self.settings.mouseVolume, pan: 0)
                release = self.extraTrigger(self.settings.mouseSound, importedSound: self.settings.customMouse, phase: .up, volume: self.settings.mouseVolume, pan: 0)
            } else if event.usagePage == 7, event.usage == 40 || event.usage == 88, self.settings.enterSound != .none {
                press = self.extraTrigger(self.settings.enterSound, importedSound: self.settings.customEnter, phase: .down, volume: self.settings.enterVolume, pan: self.pan(event))
                release = self.extraTrigger(self.settings.enterSound, importedSound: self.settings.customEnter, phase: .up, volume: self.settings.enterVolume, pan: self.pan(event))
            } else {
                let custom = self.overrides[event.keyID]
                let gain = AudioMixParameters.typingGain(volume: self.settings.volume, override: custom?.volume,
                    isHomeRow: event.usagePage == 7 && KeyboardLayout.isHomeRow(event.usage), softness: self.settings.homeRowSoftness,
                    modifierGain: modifierGain)
                press = self.profileTrigger(custom?.profileID ?? self.settings.profileID, phase: .down,
                    tone: custom?.tone ?? self.settings.tone, pitch: custom?.pitch ?? self.settings.pitch,
                    gain: gain, pan: self.pan(event))
                release = self.profileTrigger(custom?.profileID ?? self.settings.profileID, phase: .up,
                    tone: custom?.tone ?? self.settings.tone, pitch: custom?.pitch ?? self.settings.pitch, gain: gain, pan: self.pan(event))
            }
            // The matching release is chosen at press time, so changing a profile or
            // import while a key is held cannot play a release from a different sound.
            if let press, ca_mixer_enqueue(self.mixer, press) { self.releases.remember(release, for: event) }
        }
    }

    public func preview(profileID: String) {
        queue.async { [weak self] in
            guard let self, !self.suspended, self.engine?.isRunning == true else { return }
            self.playProfile(profileID, phase: .down, tone: self.settings.tone, pitch: self.settings.pitch, gain: self.settings.volume, pan: 0, audition: true)
        }
    }

    public func previewExtra(_ sound: ExtraSound, forEnter: Bool = false) {
        queue.async { [weak self] in
            guard let self, !self.suspended, self.engine?.isRunning == true else { return }
            self.playExtra(sound, importedSound: forEnter ? self.settings.customEnter : self.settings.customMouse,
                phase: .down, volume: forEnter ? self.settings.enterVolume : self.settings.mouseVolume, pan: 0, audition: true)
        }
    }

    public func outputs() -> [AudioOutputDevice] { AudioDevices.all().map(\.1) }
    public func setHeadYaw(_ yaw: Double) { queue.async { [weak self] in self?.headYaw = yaw.isFinite ? yaw : 0 } }
    public func resetHeldInputs() { queue.async { [weak self] in self?.releases.reset() } }
    public func suspend() {
        queue.async { [weak self] in
            guard let self else { return }; self.suspended = true; self.rebuildGeneration &+= 1
            self.engine?.stop(); ca_mixer_clear(self.mixer); self.releases.reset()
        }
    }
    public func resume() {
        queue.async { [weak self] in guard let self else { return }; self.suspended = false; self.scheduleRebuild() }
    }

    private func register(_ decoded: [DecodedAudioSample], in mixer: OpaquePointer, silent: Bool = false, targetRMS: Float? = nil, calibration: Float = 1) throws -> [Sample] {
        let energies = decoded.map(\.rms).sorted()
        let median = energies.isEmpty ? 0 : energies[energies.count / 2]
        return try decoded.map { sample in
            let id = sample.frames.withUnsafeBufferPointer { ca_mixer_add_sample(mixer, $0.baseAddress, UInt32($0.count), sample.sampleRate) }
            guard id >= 0 else { throw AudioSampleError.bankFull }
            let normalized = AudioNormalization.gain(rms: sample.rms, peak: sample.peak, profileGain: calibration, targetRMS: targetRMS ?? median * calibration, silent: silent)
            return Sample(id: UInt32(id), rms: sample.rms, normalization: normalized)
        }
    }

    private func loadImports() {
        guard let directory = importsURL else { return }
        let paths = [settings.customMouse, settings.customEnter].compactMap { $0 }.flatMap { [$0.pressPath, $0.releasePath].compactMap { $0 } }
        let generation = loadGeneration
        for path in paths where imported[path] == nil && !importsLoading.contains(path) {
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(directory.standardizedFileURL.path + "/") else { report("Imported sound is outside Clicky’s sound folder."); continue }
            importsLoading.insert(path)
            loader.async { [weak self] in
                let result = Result { try DecodedAudioSample.read(url: url) }
                self?.queue.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.importsLoading.remove(path)
                    do { self.imported[path] = try self.register([result.get()], in: self.mixer).first }
                    catch { self.report(error.localizedDescription) }
                }
            }
        }
    }

    private func playProfile(_ id: String, phase: InputPhase, tone: Float, pitch: Float, gain: Float, pan: Float, audition: Bool = false) {
        if let trigger = profileTrigger(id, phase: phase, tone: tone, pitch: pitch, gain: gain, pan: pan, audition: audition) { _ = ca_mixer_enqueue(mixer, trigger) }
    }
    private func profileTrigger(_ id: String, phase: InputPhase, tone: Float, pitch: Float, gain: Float, pan: Float, audition: Bool = false) -> CATrigger? {
        guard let bank = banks[id] ?? banks["thocky"] else { return nil }
        let samples = phase == .down ? bank.press : bank.release
        guard !samples.isEmpty else { return nil }
        let selectionKey = id + phase.rawValue
        let sample: Sample
        if settings.variation, samples.count > 1 {
            let previous = samples.firstIndex { $0.id == lastSample[selectionKey] }
            let index = AudioSampleSelector.index(count: samples.count, excluding: previous, random: UInt32.random(in: .min ... .max))!
            sample = samples[index]
        } else { sample = samples[0] }
        lastSample[selectionKey] = sample.id
        let variation: Float = settings.variation ? Float.random(in: 0.975...1.025) : 1
        let strength: Float = settings.variation ? Float.random(in: 0.94...1) : 1
        let correction = settings.normalization ? sample.normalization : 1
        let speed = powf(2, max(-1, min(1, pitch)) * 0.5) * variation
        return CATrigger(sample: sample.id,
            gain: AudioMixParameters.profileGain(sliderGain: gain, manifestGain: bank.gain, normalization: correction, variation: strength),
            pan: pan, pitch: speed, tone: tone, audition: audition)
    }

    private func playExtra(_ extra: ExtraSound, importedSound: ImportedSound?, phase: InputPhase, volume: Float, pan: Float, audition: Bool = false) {
        if let trigger = extraTrigger(extra, importedSound: importedSound, phase: phase, volume: volume, pan: pan, audition: audition) { _ = ca_mixer_enqueue(mixer, trigger) }
    }
    private func extraTrigger(_ extra: ExtraSound, importedSound: ImportedSound?, phase: InputPhase, volume: Float, pan: Float, audition: Bool = false) -> CATrigger? {
        let sample: Sample?
        if extra == .custom {
            let path = phase == .down ? importedSound?.pressPath : importedSound?.releasePath
            sample = path.flatMap { imported[$0] }
        } else { sample = phase == .down ? extras[extra] : nil }
        guard let sample else { return nil }
        return CATrigger(sample: sample.id, gain: volume, pan: pan, pitch: 1, tone: 0, audition: audition)
    }

    private func pan(_ event: PhysicalInputEvent) -> Float {
        guard settings.spatial else { return 0 }
        return AudioMixParameters.pan(position: KeyboardLayout.pan(for: event.usage, page: event.usagePage),
            width: settings.spatialWidth, headphones: isHeadphones,
            orbitOffset: settings.orbit ? Float(sin(ProcessInfo.processInfo.systemUptime * 0.9)) * 0.5 : 0,
            headYaw: settings.headTracking ? headYaw : 0)
    }

    private func applyGain() {
        let muted = !enabled || (settings.pauseOnHeadphones && isHeadphones)
        if muted { releases.reset() }
        // Category volumes are absolute trigger gains. Keeping the mixer at unity
        // avoids scaling mouse/Enter twice or multiplying a per-key override.
        ca_mixer_set_gain(mixer, 1)
        ca_mixer_set_enabled(mixer, !muted)
    }

    private func report(_ message: String?) {
        statusLock.lock(); let handler = statusHandler; statusLock.unlock()
        DispatchQueue.main.async { handler?(message) }
    }

    private func listen(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Listener? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }
    private func removeListeners(_ listeners: [Listener]) {
        for var listener in listeners { _ = AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, queue, listener.block) }
    }
    private func scheduleRebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.rebuildGeneration == generation, !self.suspended else { return }
            self.rebuildEngine()
        }
    }

    private func rebuildEngine() {
        guard !suspended, !banks.isEmpty else { return }
        ignoreEngineChangesUntil = ProcessInfo.processInfo.systemUptime + 0.5
        engine?.stop(); engine = nil; sourceNode = nil; releases.reset(); outputDeviceID = nil
        removeListeners(deviceListeners); deviceListeners.removeAll()
        guard let defaultID = AudioDevices.defaultOutput() else { report("No audio output is connected."); return }
        let inventory = AudioDevices.all()
        let selected = inventory.first { $0.1.id == settings.outputDeviceUID }
        var deviceID = selected?.0 ?? defaultID
        outputDeviceID = deviceID
        let fallback = settings.outputDeviceUID != nil && selected == nil
        statusLock.lock(); headphones = AudioDevices.isHeadphones(deviceID); statusLock.unlock()
        applyGain()
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { report("The audio output could not be opened."); return }
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { report("The selected output is unavailable (\(result))."); return }
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        outputRate = hardwareFormat.sampleRate
        guard outputRate > 0, hardwareFormat.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) else { report("The output has no playable channels."); return }
        ca_mixer_set_sample_rate(mixer, outputRate)
        let renderMixer = mixer // Opaque pointer only: no controller or sample ARC on render.
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            if buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData {
                ca_mixer_render(renderMixer, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self), frameCount, 1)
            } else if buffers.count == 1, buffers[0].mNumberChannels == 2, let data = buffers[0].mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                ca_mixer_render(renderMixer, samples, samples.advanced(by: 1), frameCount, 2)
            } else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.engine = engine; sourceNode = source
        do {
            engine.prepare()
            // Configure this client's prepared output before callbacks start.
            // Diagnostics query this process and the actual callback; another
            // process can read a different buffer size for the same device.
            AudioDevices.requestSmallBuffer(deviceID)
            try engine.start()
            report(fallback ? "Selected output disconnected; using the system output." : nil)
        } catch { report(error.localizedDescription) }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            if let listener = listen(object: deviceID, selector: selector) { deviceListeners.append(listener) }
        }
        if let listener = listen(object: deviceID, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) { deviceListeners.append(listener) }
    }
}
