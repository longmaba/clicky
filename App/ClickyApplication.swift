import AppKit
import SwiftUI
import RealityKit
import ClickyCore

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var menuBar: MenuBarController!
    private var overlays: OverlayController!
    private var settingsWindow: NSWindow?
    private var diagnosticDirectory: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(where: { $0 == "--diagnostics" || $0 == "--audio-diagnostics" || $0 == "--notch-diagnostics" }), args.count > i+1 { diagnosticDirectory = URL(fileURLWithPath:args[i+1],isDirectory:true) }
        model = AppModel(diagnosticMode:diagnosticDirectory != nil)
        menuBar = MenuBarController(model:model)
        overlays = OverlayController(model:model)
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.onConfigurationChanged = { [weak self] in
            guard let self else { return }; self.menuBar.update(); self.overlays.configurationChanged(); self.updateActivationPolicy()
        }
        model.onInputEvent = { [weak self] event in self?.overlays.handle(event) }
        model.onResetVisuals = { [weak self] in self?.overlays.hideAll() }
        model.onPreviewVisuals = { [weak self] in self?.overlays.preview() }
        installMainMenu(); updateActivationPolicy(); overlays.configurationChanged()
        if args.contains("--notch-diagnostics"), let diagnosticDirectory {
            Task {
                await NotchDiagnostics.run(model: model, overlays: overlays, directory: diagnosticDirectory)
                NSApp.terminate(nil)
            }
            return
        }
        if !model.permissionGranted || args.contains("--settings") || diagnosticDirectory != nil { showSettings() }
        if let diagnosticDirectory { Task { await runDiagnostics(at:diagnosticDirectory) } }
        if let i = args.firstIndex(of:"--audio-report"), args.count > i+1 {
            let url = URL(fileURLWithPath:args[i+1])
            Task { await recordRunningAudio(at:url) }
        }
    }
    private func updateActivationPolicy() { NSApp.setActivationPolicy(model.config.general.showInDock ? .regular : .accessory) }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            window.title = "Clicky"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.toolbarStyle = .unified; window.minSize = NSSize(width:860,height:650)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView:SettingsView(model:model))
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        model.config.general.showMenuBar = true; menuBar.update(); showSettings(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { overlays?.hideAll(); model?.shutdown() }

    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(title:"Clicky")
        appMenu.addItem(withTitle:"About Clicky",action:#selector(about),keyEquivalent:"").target = self
        appMenu.addItem(withTitle:"Settings…",action:#selector(settings),keyEquivalent:",").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Clicky",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title:"Edit")
        for (title,action,key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {
            editMenu.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }
    @objc private func settings() { showSettings() }
    @objc private func about() { model.settingsTab = "about"; showSettings() }

    /// Opt-in troubleshooting: observe normal operation without changing settings
    /// or injecting input. Only audio counters/status are recorded, never keys.
    private func recordRunningAudio(at url: URL) async {
        var observations: [[String:Any]] = []
        for second in 1...20 {
            try? await Task.sleep(nanoseconds:1_000_000_000)
            let stats = model.audio.diagnostics
            observations.append(["second":second,"audioReady":model.audioReady,
                "status":model.audioStatus ?? "ready","inputMonitoringGranted":model.permissionGranted,
                "sampleRate":stats.outputSampleRate,"deviceBufferFrames":stats.bufferFrameSize,
                "renderBlockFrames":stats.renderBlockFrameSize,"renderedFrames":stats.renderedFrames])
            if let data = try? JSONSerialization.data(withJSONObject:observations,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:url,options:.atomic)
            }
        }
    }

    private func runDiagnostics(at directory: URL) async {
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for _ in 0..<100 {
                if model.audioReady || model.audioStatus != nil { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            if !CommandLine.arguments.contains("--audio-diagnostics") {
                for mode in [NSAppearance.Name.aqua,.darkAqua] {
                    settingsWindow?.appearance = NSAppearance(named:mode)
                    for tab in ["sound","keyboard","visualizer","general","extras","about"] {
                        model.settingsTab = tab
                        try await Task.sleep(nanoseconds:300_000_000)
                        if let view = settingsWindow?.contentView {
                            let scroll = descendants(of:NSScrollView.self,in:view).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
                            scroll?.contentView.scroll(to:.zero)
                            if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
                            try await Task.sleep(nanoseconds:100_000_000)
                            try snapshot(view,to:directory.appendingPathComponent("\(mode.rawValue)-\(tab).png"))
                            if let scroll, let document = scroll.documentView {
                                let height = max(0,document.bounds.height - scroll.contentView.bounds.height)
                                if height > 40 {
                                    for fraction in [0.5,1.0] {
                                        scroll.contentView.scroll(to:NSPoint(x:0,y:height*fraction)); scroll.reflectScrolledClipView(scroll.contentView)
                                        try await Task.sleep(nanoseconds:150_000_000)
                                        try snapshot(view,to:directory.appendingPathComponent("\(mode.rawValue)-\(tab)-scroll\(Int(fraction*100)).png"))
                                    }
                                }
                            }
                        }
                    }
                }
                model.config.visualizer.enabled = true; model.config.visualizer.placement = .bottomCenter
                for style in VisualizerStyle.allCases {
                    model.config.visualizer.style = style; overlays.configurationChanged(); overlays.preview()
                    try await Task.sleep(nanoseconds:250_000_000)
                    let windows = NSApp.windows.filter { $0 !== settingsWindow && $0.isVisible && $0.contentView != nil }
                    for (index,window) in windows.enumerated() {
                        try snapshot(window.contentView!,to:directory.appendingPathComponent("overlay-\(style.rawValue)-\(index).png"))
                    }
                }
                overlays.hideAll()
                for showSwitch in [false,true] {
                    overlays.previewNotch(showSwitch:showSwitch)
                    try await Task.sleep(nanoseconds:900_000_000)
                    let label = showSwitch ? "switch" : "keyboard"
                    for window in NSApp.windows where window !== settingsWindow && window.isVisible {
                        guard let view = window.contentView, let reality = descendants(of:ARView.self,in:view).first else { continue }
                        try snapshot(view,to:directory.appendingPathComponent("notch-\(label).png"))
                        let rendered: NSImage? = await withCheckedContinuation { continuation in
                            reality.snapshot(saveToHDR:false) { image in continuation.resume(returning:image) }
                        }
                        if let data = rendered?.tiffRepresentation, let rep = NSBitmapImageRep(data:data), let png = rep.representation(using:.png,properties:[:]) {
                            try png.write(to:directory.appendingPathComponent("notch-\(label)-3d.png"))
                        }
                    }
                    overlays.hideAll()
                }
            }
            // Exercise the real output callback at zero typing volume. This is a
            // software replay, never presented as a physical-key or acoustic test.
            var silent = SoundSettings(); silent.volume = 0; silent.mouseSound = .none; silent.enterSound = .none
            model.audio.update(settings:silent,keyOverrides:[:],enabled:true)
            try await Task.sleep(nanoseconds:100_000_000)
            let before = model.audio.diagnostics
            for i in 0..<500 {
                model.audio.trigger(PhysicalInputEvent(usage:UInt32(4 + i % 26),phase:.down))
                try await Task.sleep(nanoseconds:10_000_000)
            }
            try await Task.sleep(nanoseconds:200_000_000)
            let after = model.audio.diagnostics
            var modifierReplay: [String:Any] = [:]
            for mode in ModifierSoundMode.allCases {
                var settings = SoundSettings()
                settings.volume = 0; settings.mouseVolume = 0; settings.enterVolume = 0
                settings.enterSound = .ding; settings.modifierSoundMode = mode
                model.audio.update(settings:settings,keyOverrides:[:],enabled:true)
                let start = model.audio.diagnostics
                for usage in Array(UInt32(224)...UInt32(231)) + [255] {
                    model.audio.trigger(PhysicalInputEvent(usage:usage,phase:.down))
                    model.audio.trigger(PhysicalInputEvent(usage:usage,phase:.up))
                }
                for event in [PhysicalInputEvent(usage:6,phase:.down,modifiers:[.command,.shift]),
                              PhysicalInputEvent(usage:40,phase:.down,modifiers:.command),
                              PhysicalInputEvent(usagePage:9,usage:1,phase:.down),
                              PhysicalInputEvent(usagePage:12,usage:0xE9,phase:.down)] {
                    model.audio.trigger(event)
                }
                let end = model.audio.diagnostics
                modifierReplay[mode.rawValue] = ["expected":mode == .silent ? 4 : 22,
                    "accepted":end.acceptedTriggers-start.acceptedTriggers,
                    "dropped":end.droppedTriggers-start.droppedTriggers]
            }
            // Every bank plays a press and a separate, softer return on key-up.
            var profileReplay: [String: Any] = [:]
            for profile in model.profiles {
                var settings = silent
                settings.profileID = profile.id
                model.audio.update(settings: settings, keyOverrides: [:], enabled: true)
                let start = model.audio.diagnostics
                for index in 0..<60 {
                    let usage = UInt32(4 + index % 26)
                    model.audio.trigger(PhysicalInputEvent(usage: usage, phase: .down))
                    model.audio.trigger(PhysicalInputEvent(usage: usage, phase: .up))
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let end = model.audio.diagnostics
                profileReplay[profile.id] = ["pressReleasePairs": 60, "expected": 120,
                    "accepted": end.acceptedTriggers - start.acceptedTriggers,
                    "dropped": end.droppedTriggers - start.droppedTriggers]
            }
            model.audio.update(settings:configForDiagnostics(),keyOverrides:[:],enabled:false)
            settingsWindow?.performClose(nil)
            try await Task.sleep(nanoseconds:200_000_000)
            let audioContinuesAfterSettingsClose = model.audio.diagnostics.renderedFrames > after.renderedFrames
            let report: [String:Any] = [
                "profileCount":model.profiles.count,
                "recordedSampleCount":model.profiles.reduce(0) { $0 + $1.samples.count },
                "missingSamples":model.profiles.flatMap(\.samples).filter { !FileManager.default.fileExists(atPath:AppResources.assets.appendingPathComponent($0).path) },
                "audioReady":model.audioReady,
                "audioStatus":model.audioStatus ?? "ready",
                "inputMonitoringGranted":model.permissionGranted,
                "secureInputActive":model.secureInput,
                "audioContinuesAfterSettingsClose":audioContinuesAfterSettingsClose,
                "modifierReplay":modifierReplay,
                "profileReplay":profileReplay,
                "outputs":model.outputs.map { ["id":$0.id,"name":$0.name,"headphones":$0.isHeadphones] as [String:Any] },
                "os":ProcessInfo.processInfo.operatingSystemVersionString,
                "audioReplay":["submitted":500,"accepted":after.acceptedTriggers-before.acceptedTriggers,"dropped":after.droppedTriggers-before.droppedTriggers,"renderedFrames":after.renderedFrames-before.renderedFrames,"sampleRate":after.outputSampleRate,"bufferFrames":after.bufferFrameSize,"bufferMilliseconds":after.requestedBufferDuration*1000,"renderBlockFrames":after.renderBlockFrameSize,"renderBlockMilliseconds":Double(after.renderBlockFrameSize)/after.outputSampleRate*1000] as [String:Any],
                "hardwareInputTests":"Require physical typing and permission grant; not simulated by diagnostics."
            ]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
        } catch {
            try? Data(error.localizedDescription.utf8).write(to:directory.appendingPathComponent("error.txt"))
        }
        NSApp.terminate(nil)
    }
    private func configForDiagnostics() -> SoundSettings { var settings = SoundSettings(); settings.volume = 0; return settings }
    private func descendants<T: NSView>(of type: T.Type,in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants(of:type,in:$0) }
    }
    private func snapshot(_ view: NSView,to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { return }
        try png.write(to:url)
    }
}

@main struct ClickyApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
