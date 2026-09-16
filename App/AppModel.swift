import AppKit
import AVFoundation
import Carbon
import Combine
import CoreMotion
import ServiceManagement
import UniformTypeIdentifiers
import ClickyCore

enum AppResources {
    static var assets: URL {
        if let resources = Bundle.main.resourceURL {
            let assets = resources.appendingPathComponent("Assets",isDirectory:true)
            if FileManager.default.fileExists(atPath:assets.appendingPathComponent("profiles.json").path) { return assets }
        }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "Assets", withExtension: nil)!
        #else
        return Bundle.main.resourceURL!.appendingPathComponent("Assets")
        #endif
    }
}

/// The short input → audio path bypasses the main actor and its UI rendering.
private final class InputRouter {
    let audio: AudioController
    private let lock = NSLock()
    private var shortcut = ShortcutConfiguration()
    private var recognizer = ShortcutRecognizer()
    private var recording = false
    var onToggle: (() -> Void)?
    var onRecord: ((PhysicalInputEvent) -> Void)?
    var onVisual: ((PhysicalInputEvent) -> Void)?
    init(audio: AudioController) { self.audio = audio }
    func update(shortcut: ShortcutConfiguration, recording: Bool) {
        lock.lock(); self.shortcut = shortcut; self.recording = recording; recognizer.reset(); lock.unlock()
    }
    func reset() { lock.lock(); recognizer.reset(); lock.unlock() }
    func receive(_ event: PhysicalInputEvent) {
        lock.lock()
        let capture = recording && event.phase == .down && event.usagePage == 7 && KeyboardLayout.modifier(for:event.usage).isEmpty
        if capture { recording = false }
        let toggle = !recording && !capture && recognizer.process(event, shortcut:shortcut)
        lock.unlock()
        if capture { onRecord?(event); return }
        if toggle { onToggle?(); return }
        audio.trigger(event)
        onVisual?(event)
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var config: AppConfiguration
    let profiles: [SoundProfileManifest]
    let mouseProfiles: [SoundProfileManifest]
    @Published var outputs: [AudioOutputDevice] = []
    @Published var permissionGranted = false
    @Published var secureInput = false
    @Published var audioStatus: String?
    @Published var notice: String?
    @Published var latestEvent: PhysicalInputEvent?
    @Published var pressedKeys: Set<String> = []
    @Published var comboCount = 0
    @Published var isRecordingShortcut = false
    @Published var settingsTab = "sound"
    @Published var audioReady = false
    // Keep Settings/menu hover auditions out of opt-in playback replay counters.
    var diagnosticReplayInProgress = false
    var currentProfile: SoundProfileManifest? { profiles.first { $0.id == config.sound.profileID } }
    var onShowSettings: (() -> Void)?
    var onConfigurationChanged: (() -> Void)?
    var onInputEvent: ((PhysicalInputEvent) -> Void)?
    var onResetVisuals: (() -> Void)?
    var onPreviewVisuals: (() -> Void)?
    let audio = AudioController()
    private let input = InputService()
    private let store: ConfigurationStore
    let supportURL: URL
    var importsURL: URL { supportURL.appendingPathComponent("Imported Sounds", isDirectory:true) }
    private var router: InputRouter!
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var previousConfig: AppConfiguration
    private var lastKeyAt: Double = 0
    private var deviceHolds: [String: Set<UInt64>] = [:]
    private var motion: AnyObject?
    private var sleeping = false
    private var sessionActive = true
    private var lastDeviceRefresh: Double = 0
    private let diagnosticMode: Bool
    private var workspaceObservers: [NSObjectProtocol] = []

    init(diagnosticMode: Bool = false) {
        self.diagnosticMode = diagnosticMode
        supportURL = diagnosticMode ? FileManager.default.temporaryDirectory.appendingPathComponent("Clicky-Diagnostics-\(ProcessInfo.processInfo.processIdentifier)") : FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Clicky",isDirectory:true)
        store = ConfigurationStore(directory:supportURL)
        let loaded: AppConfiguration
        var initialNotice: String?
        do { loaded = try store.load() }
        catch {
            loaded = AppConfiguration()
            let backup = store.fileURL.deletingLastPathComponent().appendingPathComponent("configuration-backup-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at:store.fileURL,to:backup)
            initialNotice = "Your previous settings could not be read. A backup was kept; Clicky is using defaults."
        }
        config = loaded; previousConfig = loaded
        do {
            profiles = try JSONDecoder().decode([SoundProfileManifest].self,from:Data(contentsOf:AppResources.assets.appendingPathComponent("profiles.json")))
        } catch { profiles = []; initialNotice = "The bundled sounds could not be loaded: \(error.localizedDescription)" }
        do {
            mouseProfiles = try JSONDecoder().decode([SoundProfileManifest].self, from: Data(contentsOf: AppResources.assets.appendingPathComponent("mouse-profiles.json")))
        } catch { mouseProfiles = []; initialNotice = "The bundled mouse sounds could not be loaded: \(error.localizedDescription)" }
        notice = initialNotice
        router = InputRouter(audio:audio)
        wireServices()
        router.update(shortcut:config.general.shortcut,recording:false)
        config.sound.profileID = profiles.contains(where: { $0.id == config.sound.profileID }) ? config.sound.profileID : (profiles.first?.id ?? "thocky")
        permissionGranted = InputService.permissionGranted
        secureInput = IsSecureEventInputEnabled()
        if !diagnosticMode {
            config.general.launchAtLogin = SMAppService.mainApp.status == .enabled
            $config.dropFirst().removeDuplicates().sink { [weak self] value in
                DispatchQueue.main.async { self?.configurationDidChange(value) }
            }.store(in:&cancellables)
            timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
                Task { @MainActor in self?.pollSystemState() }
            }
            observeWorkspace()
        }
        let profiles = self.profiles, mouseProfiles = self.mouseProfiles, assets = AppResources.assets, imports = importsURL, audio = self.audio
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                try audio.load(profiles: profiles, mouseProfiles: mouseProfiles, assetsURL: assets, importsURL: imports)
                Task { @MainActor in
                    guard let self else { return }; self.audioReady = true; self.applyAudioSettings(); self.refreshDevices()
                }
            } catch {
                Task { @MainActor in self?.audioStatus = error.localizedDescription }
            }
        }
        applyAudioSettings()
        if permissionGranted && !diagnosticMode { input.setPaused(secureInput); input.start() }
        if !diagnosticMode && config.sound.headTracking { updateHeadTracking() }
    }

    private func wireServices() {
        input.onEvent = { [router] event in router?.receive(event) }
        input.onReset = { [weak self, router, audio] in
            router?.reset(); audio.resetHeldInputs()
            DispatchQueue.main.async { self?.clearVisualState() }
        }
        input.onError = { [weak self] error in
            if let error { DispatchQueue.main.async { self?.notice = error } }
        }
        audio.onStatus = { [weak self] message in DispatchQueue.main.async { self?.audioStatus = message } }
        router.onToggle = { [weak self] in DispatchQueue.main.async { self?.toggleEnabled() } }
        router.onRecord = { [weak self] event in DispatchQueue.main.async { self?.recordShortcut(event) } }
        router.onVisual = { [weak self] event in DispatchQueue.main.async { self?.receiveVisual(event) } }
    }
    private func configurationDidChange(_ value: AppConfiguration) {
        let sanitized = value.validated()
        if sanitized != value { config = sanitized; return }
        let old = previousConfig; previousConfig = value
        applyAudioSettings()
        router.update(shortcut:value.general.shortcut,recording:isRecordingShortcut)
        if old.general.launchAtLogin != value.general.launchAtLogin { updateLoginItem(value.general.launchAtLogin) }
        if old.sound.headTracking != value.sound.headTracking { updateHeadTracking() }
        if !value.enabled || !value.visualizer.enabled { onResetVisuals?() }
        if old.enabled != value.enabled { clearVisualState() }
        onConfigurationChanged?()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.store.save(self.config) }
            catch { self.notice = "Could not save settings: \(error.localizedDescription)" }
        }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:work)
    }
    private func applyAudioSettings() {
        audio.update(settings:config.sound,keyOverrides:config.keyOverrides,enabled:config.enabled && permissionGranted && !secureInput && !sleeping && sessionActive && !diagnosticMode)
    }
    private func pollSystemState() {
        let granted = InputService.permissionGranted
        if granted != permissionGranted {
            permissionGranted = granted
            if granted { input.setPaused(secureInput || sleeping || !sessionActive); input.start() } else { input.stop(); clearVisualState() }
            applyAudioSettings()
        }
        let secure = IsSecureEventInputEnabled()
        if secure != secureInput {
            secureInput = secure; input.setPaused(secure || sleeping || !sessionActive); clearVisualState(); applyAudioSettings()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDeviceRefresh > 3 { lastDeviceRefresh = now; refreshDevices() }
        if comboCount != 0 && !config.visualizer.keepCombo && now - lastKeyAt > config.visualizer.comboTimeout { comboCount = 0 }
    }
    private func receiveVisual(_ event: PhysicalInputEvent) {
        guard config.enabled, !secureInput, !sleeping, sessionActive else { return }
        if event.phase == .down {
            deviceHolds[event.keyID,default:[]].insert(event.deviceID)
            if !event.isMouse && KeyboardLayout.modifier(for:event.usage).isEmpty {
                if !config.visualizer.keepCombo && event.timestamp - lastKeyAt > config.visualizer.comboTimeout { comboCount = 0 }
                comboCount += 1; lastKeyAt = event.timestamp
            }
        } else { deviceHolds[event.keyID]?.remove(event.deviceID) }
        pressedKeys = Set(deviceHolds.compactMap { $0.value.isEmpty ? nil : $0.key })
        latestEvent = event; onInputEvent?(event)
    }
    private func clearVisualState() {
        pressedKeys.removeAll(); deviceHolds.removeAll(); latestEvent = nil; comboCount = 0
        router.reset(); onResetVisuals?()
    }

    func toggleEnabled() { config.enabled.toggle() }
    func selectProfile(_ id: String) { config.sound.profileID = id }
    func previewProfile(_ id: String, keyID: String? = nil) {
        guard !diagnosticReplayInProgress else { return }
        audio.preview(profileID: id, keyID: keyID)
    }
    func previewExtra(_ sound: ExtraSound, forMouse: Bool = true) {
        guard !diagnosticReplayInProgress else { return }
        audio.previewExtra(sound, forEnter:!forMouse)
    }
    func requestInputPermission() {
        _ = InputService.requestPermission(); pollSystemState()
        if !permissionGranted { openInputSettings() }
    }
    func openInputSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func revealAppInFinder() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func showSettings() { onShowSettings?() }
    func resetSound() { config.sound = SoundSettings(); config.keyOverrides = [:] }
    func resetKey(_ keyID: String) { config.keyOverrides.removeValue(forKey:keyID) }
    func refreshDevices() { let next = audio.outputs(); if next != outputs { outputs = next } }
    func previewVisualizer() { onPreviewVisuals?() }
    func saveFavorite(name: String) {
        guard config.favorites.count < 6 else { notice = "All six favorite slots are filled. Remove one to save another."; return }
        let clean = name.trimmingCharacters(in:.whitespacesAndNewlines)
        config.favorites.append(Favorite(name:clean.isEmpty ? (currentProfile?.name ?? "My sound") : clean,sound:config.sound,keyOverrides:config.keyOverrides))
    }
    func applyFavorite(_ favorite: Favorite) { config.sound = favorite.sound; config.keyOverrides = favorite.keyOverrides }
    func deleteFavorite(_ id: UUID) { config.favorites.removeAll { $0.id == id } }
    func beginShortcutRecording() {
        guard permissionGranted else { notice = "Enable Input Monitoring to record a global shortcut."; return }
        isRecordingShortcut = true; router.update(shortcut:config.general.shortcut,recording:true)
    }
    func endShortcutRecording() { isRecordingShortcut = false; router.update(shortcut:config.general.shortcut,recording:false) }
    private func recordShortcut(_ event: PhysicalInputEvent) {
        config.general.shortcut.usage = event.usage; config.general.shortcut.modifiers = event.modifiers
        endShortcutRecording()
    }

    func importSound(forMouse: Bool, release: Bool) {
        let existing = forMouse ? config.sound.customMouse : config.sound.customEnter
        if release && existing == nil { notice = "Import a press sound first, then add its release sound."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav,.aiff,.mp3,.mpeg4Audio]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = release ? "Choose the sound that plays when you release." : "Choose a short sound for each press."
        panel.prompt = "Import sound"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let targetDirectory = importsURL
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                let decoded = try DecodedAudioSample.read(url:source)
                guard Double(decoded.frames.count) / decoded.sampleRate <= 15 else { throw ImportError.tooLong }
                try FileManager.default.createDirectory(at:targetDirectory,withIntermediateDirectories:true)
                let relative = UUID().uuidString + "." + source.pathExtension.lowercased()
                try FileManager.default.copyItem(at:source,to:targetDirectory.appendingPathComponent(relative))
                Task { @MainActor in
                    guard let self else { return }
                    var imported = (forMouse ? self.config.sound.customMouse : self.config.sound.customEnter) ?? ImportedSound(name:source.deletingPathExtension().lastPathComponent,pressPath:relative)
                    if release { imported.releasePath = relative } else { imported.name = source.deletingPathExtension().lastPathComponent; imported.pressPath = relative }
                    if forMouse { self.config.sound.customMouse = imported; self.config.sound.mouseSound = .custom }
                    else { self.config.sound.customEnter = imported; self.config.sound.enterSound = .custom }
                    self.notice = "Imported \(source.lastPathComponent)."
                }
            } catch { Task { @MainActor in self?.notice = "Could not import this sound: \(error.localizedDescription)" } }
        }
    }
    private enum ImportError: LocalizedError {
        case empty, tooLong
        var errorDescription: String? { self == .empty ? "This file contains no audio." : "Choose a sound no longer than 15 seconds." }
    }
    private func updateLoginItem(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { notice = "Login setting could not be changed: \(error.localizedDescription)"; config.general.launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    private func updateHeadTracking() {
        if #available(macOS 14, *) {
            if config.sound.headTracking {
                let controller = HeadMotionController(audio:audio) { [weak self] text in self?.notice = text }
                motion = controller; controller.start()
            } else { (motion as? HeadMotionController)?.stop(); motion = nil; audio.setHeadYaw(0) }
        } else if config.sound.headTracking { notice = "Head tracking requires macOS 14 or later. Spatial stereo remains available." }
    }
    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = true; self.input.setPaused(true); self.clearVisualState(); self.audio.suspend()
                if #available(macOS 14, *) { (self.motion as? HeadMotionController)?.stop() }
            }
        })
        workspaceObservers.append(nc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = false; self.pollSystemState(); self.input.setPaused(self.secureInput || !self.sessionActive)
                self.audio.resume(); self.applyAudioSettings(); self.updateHeadTracking(); self.onConfigurationChanged?()
            }
        })
        workspaceObservers.append(nc.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.sessionActive = false; self?.input.setPaused(true); self?.audio.suspend(); self?.clearVisualState() }
        })
        workspaceObservers.append(nc.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.sessionActive = true; self.input.setPaused(self.secureInput || self.sleeping); self.audio.resume(); self.applyAudioSettings() }
        })
    }
    func shutdown() {
        timer?.invalidate(); input.stop(); audio.suspend(); saveWork?.cancel()
        if !diagnosticMode { try? store.save(config) }
        if #available(macOS 14, *) { (motion as? HeadMotionController)?.stop() }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}

@available(macOS 14, *)
@MainActor private final class HeadMotionController: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private let audio: AudioController
    private let status: (String) -> Void
    private var referenceYaw: Double?
    init(audio: AudioController,status: @escaping (String) -> Void) { self.audio = audio; self.status = status; super.init(); manager.delegate = self }
    func start() {
        referenceYaw = nil
        if !manager.isConnectionStatusActive { manager.startConnectionStatusUpdates() }
        guard manager.isDeviceMotionAvailable else { status("Head tracking is waiting for compatible headphones. Spatial stereo is active."); return }
        manager.startDeviceMotionUpdates(to:.main) { [weak self] motion,error in
            guard let self else { return }
            if let error { self.audio.setHeadYaw(0); self.status("Head tracking unavailable: \(error.localizedDescription)"); return }
            guard let motion else { return }
            if self.referenceYaw == nil { self.referenceYaw = motion.attitude.yaw }
            let angle = motion.attitude.yaw - (self.referenceYaw ?? 0)
            self.audio.setHeadYaw(atan2(sin(angle),cos(angle)))
        }
    }
    func stop() { manager.stopDeviceMotionUpdates(); manager.stopConnectionStatusUpdates(); referenceYaw = nil; audio.setHeadYaw(0) }
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { Task { @MainActor in self.start() } }
    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) { Task { @MainActor in self.audio.setHeadYaw(0); self.referenceYaw = nil } }
}
