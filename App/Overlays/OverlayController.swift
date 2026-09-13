import AppKit
import QuartzCore
import Combine
import ColorSync
import SwiftUI
import ClickyCore

func clickyDisplayIdentifier(_ screen: NSScreen) -> String {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return String(id) }
    return CFUUIDCreateString(nil, uuid) as String
}

/// Passive panels are deliberately unable to become key or main windows.
final class ClickyOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VisualizerState: ObservableObject {
    @Published var settings = VisualizerSettings()
    @Published var pressed: Set<String> = []
    @Published var pills: [KeystrokePill] = []
    @Published var combo = 0
    @Published var pulse = false
}

struct KeystrokePill: Identifiable {
    let id = UUID()
    var text: String
    var modifierOnly: Bool
}

@MainActor
final class OverlayController {
    private weak var model: AppModel?
    private let state = VisualizerState()
    private var visualizerPanel: ClickyOverlayPanel?
    private var notchPanel: ClickyOverlayPanel?
    private var idleTask: Task<Void, Never>?
    private var notchTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cursorMonitor: Any?
    private var localCursorMonitor: Any?
    private var lastEventTime = 0.0
    private var keyCounter = 0
    private var lastScreenID: UInt32?
    private var lastFullscreenCheck = 0.0
    private var isFullscreen = false
    private var notchLastInside = 0.0
    private var notchIsInteracting = false
    private var previewing = false
    private var observations: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        model.$comboCount.sink { [weak self] count in
            guard let self, !self.previewing else { return }
            self.state.combo = count
        }.store(in: &observations)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition(); self?.closeNotch() }
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastFullscreenCheck = 0
                    self?.reposition()
                    if self?.shouldHideForFullscreen() == true { self?.visualizerPanel?.orderOut(nil); self?.closeNotch(); self?.stopCursorTracking() }
                    else if self?.model?.config.enabled == true && self?.state.settings.enabled == true && self?.state.settings.keepVisible == true { self?.showVisualizer() }
                }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAll() }
        })
    }

    func configurationChanged() {
        guard let model else { return }
        let previous = state.settings
        state.settings = model.config.visualizer
        if state.settings.notchEnabled {
            if notchTimer == nil {
                notchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackNotchHover() }
                }
                if let notchTimer { RunLoop.main.add(notchTimer, forMode: .common) }
            }
        } else {
            notchTimer?.invalidate(); notchTimer = nil; closeNotch()
        }
        if !state.settings.enabled || !model.config.enabled {
            idleTask?.cancel(); visualizerPanel?.orderOut(nil); stopCursorTracking()
        } else if state.settings.keepVisible && !shouldHideForFullscreen() {
            showVisualizer()
        }
        if previous.style != state.settings.style || previous.scale != state.settings.scale || previous.verticalKeystrokes != state.settings.verticalKeystrokes {
            updatePanelSize()
        }
        if previous.placement != state.settings.placement || previous.displayID != state.settings.displayID || previous.offset != state.settings.offset { reposition() }
        if state.settings.placement != .cursor { stopCursorTracking() }
    }

    func handle(_ event: PhysicalInputEvent) {
        guard let model else { return }
        state.pressed = model.pressedKeys
        guard event.phase == .down else { return }
        guard state.settings.enabled else { return }
        if shouldHideForFullscreen() { visualizerPanel?.orderOut(nil); return }
        let elapsed = event.timestamp - lastEventTime
        if elapsed > state.settings.dismissDelay { state.pills.removeAll() }
        lastEventTime = event.timestamp
        state.combo = model.comboCount
        keyCounter += 1
        let modifierOnly = event.usagePage == 7 && !KeyboardLayout.modifier(for: event.usage).isEmpty
        if !modifierOnly { state.pills.removeAll(where: \.modifierOnly) }
        let label = KeyboardLayout.label(for: event.usage, page: event.usagePage)
        let text = modifierOnly ? event.modifiers.symbols : event.modifiers.symbols + (event.modifiers.isEmpty ? "" : " ") + label
        state.pills.append(KeystrokePill(text: text.isEmpty ? label : text, modifierOnly: modifierOnly))
        if state.pills.count > (state.settings.verticalKeystrokes ? 5 : 4) { state.pills.removeFirst() }
        state.pulse.toggle()
        showVisualizer()
        if state.settings.placement == .random && keyCounter % max(1, state.settings.shuffleEvery) == 0 { reposition(animated: true) }
        scheduleDismiss()
    }

    func preview() {
        guard let model else { return }
        state.settings = model.config.visualizer
        state.pressed = ["7:4", "7:22", "7:7", "7:9"]
        state.pills = [KeystrokePill(text: "⌘ K", modifierOnly: false), KeystrokePill(text: "space", modifierOnly: false)]
        state.combo = max(42, state.combo)
        state.pulse.toggle()
        previewing = true
        showVisualizer()
        scheduleDismiss(delay: 3)
    }

    func previewNotch(showSwitch: Bool = false) {
        guard let screen = targetScreen() else { return }
        showNotch(on: screen, showSwitch: showSwitch)
    }

    func hideAll() {
        idleTask?.cancel(); visualizerPanel?.orderOut(nil); closeNotch(); stopCursorTracking()
        state.pressed = []; state.pills = []
        if !state.settings.keepCombo { state.combo = 0 }
        previewing = false
    }

    private func makePanel() -> ClickyOverlayPanel {
        let panel = ClickyOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        return panel
    }

    private func showVisualizer() {
        if visualizerPanel == nil {
            let panel = makePanel()
            panel.contentView = NSHostingView(rootView: VisualizerOverlayView(state: state))
            visualizerPanel = panel
        }
        updatePanelSize()
        reposition()
        visualizerPanel?.alphaValue = 1
        visualizerPanel?.orderFrontRegardless()
        if state.settings.placement == .cursor && state.settings.style != .bezel { startCursorTracking() }
    }

    private func panelSize(on screen: NSScreen) -> NSSize {
        let scale = state.settings.scale
        switch state.settings.style {
        case .keyboard: return NSSize(width: 580 * scale, height: 225 * scale)
        case .keystrokes: return state.settings.verticalKeystrokes ? NSSize(width: 240 * scale, height: 310 * scale) : NSSize(width: 560 * scale, height: 90 * scale)
        case .combo: return NSSize(width: 235 * scale, height: 125 * scale)
        case .bezel: return screen.frame.size
        }
    }

    private func updatePanelSize() {
        guard let panel = visualizerPanel, let screen = targetScreen() else { return }
        let size = panelSize(on: screen)
        if panel.frame.size != size { panel.setContentSize(size) }
    }

    private func targetScreen() -> NSScreen? {
        if let id = state.settings.displayID, let selected = NSScreen.screens.first(where: { clickyDisplayIdentifier($0) == id || String(screenID($0)) == id }) { return selected }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func reposition(animated: Bool = false) {
        guard let panel = visualizerPanel, let screen = targetScreen() else { return }
        if state.settings.style == .bezel { panel.setFrame(screen.frame, display: true); return }
        let frame = screen.visibleFrame
        let size = panelSize(on: screen)
        let margin = state.settings.offset
        let id = screenID(screen)
        var origin = panel.frame.origin
        switch state.settings.placement {
        case .cursor:
            let mouse = NSEvent.mouseLocation
            origin = CGPoint(x: mouse.x + margin, y: mouse.y - size.height - margin)
        case .topLeft: origin = CGPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin)
        case .topCenter: origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - margin)
        case .topRight: origin = CGPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .bottomLeft: origin = CGPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomCenter: origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY + margin)
        case .bottomRight: origin = CGPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        case .random:
            if !panel.isVisible || animated || lastScreenID != id {
                origin = CGPoint(x: Double.random(in: frame.minX + margin...max(frame.minX + margin, frame.maxX - size.width - margin)), y: Double.random(in: frame.minY + margin...max(frame.minY + margin, frame.maxY - size.height - margin)))
            }
        }
        origin.x = min(max(frame.minX + 4, origin.x), max(frame.minX + 4, frame.maxX - size.width - 4))
        origin.y = min(max(frame.minY + 4, origin.y), max(frame.minY + 4, frame.maxY - size.height - 4))
        lastScreenID = id
        let destination = NSRect(origin: origin, size: size)
        if animated && state.settings.shuffleMotion == .slide {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.24; panel.animator().setFrame(destination, display: true) }
        } else if animated && state.settings.shuffleMotion == .bounce {
            panel.setFrame(destination.offsetBy(dx: 0, dy: 16), display: true)
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; context.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().setFrame(destination, display: true) }
        } else if animated {
            panel.alphaValue = state.settings.shuffleMotion == .pulse ? 0.45 : 0
            panel.setFrame(destination, display: true)
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().alphaValue = 1 }
        } else { panel.setFrame(destination, display: true) }
    }

    private func scheduleDismiss(delay: Double? = nil) {
        idleTask?.cancel()
        if state.settings.keepVisible && !previewing { return }
        let duration = delay ?? state.settings.dismissDelay
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, duration) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ context in context.duration = 0.2; self.visualizerPanel?.animator().alphaValue = 0 }, completionHandler: nil)
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            self.visualizerPanel?.orderOut(nil)
            self.stopCursorTracking()
            self.previewing = false
            self.state.pressed = []
        }
    }

    private func startCursorTracking() {
        guard cursorMonitor == nil else { return }
        cursorMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        localCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.reposition() }
            return event
        }
    }

    private func stopCursorTracking() {
        if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
        if let localCursorMonitor { NSEvent.removeMonitor(localCursorMonitor) }
        cursorMonitor = nil
        localCursorMonitor = nil
    }

    private func shouldHideForFullscreen() -> Bool {
        guard state.settings.hideInFullscreen, let screen = targetScreen() else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFullscreenCheck < 0.5 { return isFullscreen }
        lastFullscreenCheck = now
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { isFullscreen = false; return false }
        let displayBounds = CGDisplayBounds(screenID(screen))
        isFullscreen = windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return abs(bounds.minX - displayBounds.minX) < 3 && abs(bounds.minY - displayBounds.minY) < 3 && bounds.width >= displayBounds.width - 3 && bounds.height >= displayBounds.height - 3
        }
        return isFullscreen
    }

    func trackNotchHover(mouse: NSPoint = NSEvent.mouseLocation, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard state.settings.notchEnabled, let screen = targetScreen(), model != nil else { return }
        if shouldHideForFullscreen() { closeNotch(); return }
        // AppKit keeps delivering a captured drag outside the view. Preserve the
        // hosting tree until mouse-up so rotation does not stop at the panel edge.
        if notchIsInteracting && notchPanel?.isVisible == true {
            notchLastInside = now
            return
        }
        let top = screen.frame.maxY
        let trigger = NSRect(x: screen.frame.midX - 115, y: top - max(36, screen.safeAreaInsets.top + 8), width: 230, height: max(36, screen.safeAreaInsets.top + 8))
        if trigger.contains(mouse) || (notchPanel?.isVisible == true && notchPanel?.frame.insetBy(dx: -8, dy: -12).contains(mouse) == true) {
            notchLastInside = now
            if notchPanel?.isVisible != true {
                showNotch(on: screen)
            }
        } else if now - notchLastInside > 0.55 { closeNotch() }
    }

    private func showNotch(on screen: NSScreen, showSwitch: Bool = false) {
        guard let model else { return }
        if notchPanel == nil { notchPanel = makePanel(); notchPanel?.ignoresMouseEvents = false; notchPanel?.hasShadow = true }
        let size = NSSize(width: 438, height: 302)
        notchPanel?.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - max(25, screen.safeAreaInsets.top) - size.height, width: size.width, height: size.height), display: true)
        notchLastInside = ProcessInfo.processInfo.systemUptime
        notchPanel?.contentView = NSHostingView(rootView: NotchPlaygroundView(model: model, showSwitch: showSwitch, onInteractionChanged: { [weak self] active in
            self?.notchIsInteracting = active
            self?.notchLastInside = ProcessInfo.processInfo.systemUptime
        }))
        notchPanel?.alphaValue = 1
        notchPanel?.orderFrontRegardless()
    }

    private func closeNotch() {
        notchIsInteracting = false
        notchPanel?.orderOut(nil)
        // Releasing the hosting tree destroys ARView, so no hidden 3D renderer remains active.
        notchPanel?.contentView = nil
    }
}

private struct VisualizerOverlayView: View {
    @ObservedObject var state: VisualizerState
    var body: some View {
        let scale = state.settings.scale
        Group {
            switch state.settings.style {
            case .keyboard:
                KeyboardView(pressedKeys: state.pressed, theme: state.settings.theme)
                    .padding(14 * scale)
                    .shadow(color: .black.opacity(0.28), radius: 9 * scale, y: 4 * scale)
            case .keystrokes:
                if state.settings.verticalKeystrokes {
                    VStack(spacing: 7 * scale) { pills(scale: scale) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(13 * scale)
                } else {
                    HStack(spacing: 7 * scale) { pills(scale: scale) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .combo:
                HStack(spacing: 13 * scale) {
                    Image(systemName: "flame.fill").font(.system(size: 32 * scale)).foregroundStyle(Color.clickyAmber)
                        .scaleEffect(state.pulse ? 1.08 : 0.96)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(state.combo)").font(.system(size: 34 * scale, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("KEY COMBO").font(.system(size: 8 * scale, weight: .semibold)).tracking(1.7 * scale).opacity(0.6)
                    }
                }.foregroundStyle(state.settings.theme.keyText)
                    .padding(.horizontal, 24 * scale).padding(.vertical, 16 * scale)
                    .background(state.settings.theme.baseColor, in: RoundedRectangle(cornerRadius: 20 * scale))
                    .overlay(RoundedRectangle(cornerRadius: 20 * scale).stroke(.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.2), radius: 9, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.12), value: state.pulse)
            case .bezel:
                RoundedRectangle(cornerRadius: 18)
                    .stroke(state.settings.theme.glowColor.opacity(state.pulse ? 0.8 : 0.5), lineWidth: 5 * scale)
                    .shadow(color: state.settings.theme.glowColor.opacity(0.7), radius: state.pulse ? 16 : 8)
                    .padding(3 * scale)
                    .animation(.easeOut(duration: 0.15), value: state.pulse)
            }
        }.allowsHitTesting(false)
    }

    @ViewBuilder private func pills(scale: Double) -> some View {
        ForEach(state.pills) { pill in
            Text(pill.text).font(.system(size: 17 * scale, weight: .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(state.settings.theme.keyText)
                .padding(.horizontal, 17 * scale).padding(.vertical, 13 * scale)
                .background(state.settings.theme.baseColor, in: RoundedRectangle(cornerRadius: 12 * scale))
                .overlay(RoundedRectangle(cornerRadius: 12 * scale).stroke(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
        }
    }
}
