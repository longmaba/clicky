import AppKit
import RealityKit
import ClickyCore

/// Opt-in native mouse replay in an isolated diagnostic configuration. Events
/// are sent only to Clicky's own windows; no global input is posted or recorded.
@MainActor
enum NotchDiagnostics {
    static func run(model: AppModel, overlays: OverlayController, directory: URL) async {
        var checks: [String: Bool] = [:]
        var measurements: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for _ in 0..<100 {
                if model.audioReady || model.audioStatus != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard model.audioReady else { throw Failure("Audio unavailable for click-preview checks") }
            var silent = model.config.sound
            silent.volume = 0
            model.audio.update(settings: silent, keyOverrides: [:], enabled: false)
            model.config.visualizer.hideInFullscreen = false
            NSApp.deactivate()

            for showSwitch in [false, true] {
                let label = showSwitch ? "switch" : "keyboard"
                model.config.visualizer.notchEnabled = false
                overlays.configurationChanged()
                overlays.previewNotch(showSwitch: showSwitch)
                try await Task.sleep(nanoseconds: 800_000_000)
                guard let (window, host) = preview() else { throw Failure("Missing \(label) preview") }
                let surface = host.interactionSurface
                let center = NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                checks["\(label).initiallyInactive"] = !NSApp.isActive && !window.isKeyWindow
                checks["\(label).acceptsFirstMouse"] = surface.acceptsFirstMouse(for: nil)
                checks["\(label).doesNotRequestKeyboardFocus"] = !surface.acceptsFirstResponder && !surface.needsPanelToBecomeKey && !window.canBecomeKey
                let hitPoint = surface.convert(center, to: window.contentView)
                checks["\(label).mouseHitsSurface"] = window.contentView?.hitTest(hitPoint) === surface
                try await snapshot(host.renderView, to: directory.appendingPathComponent("\(label)-before.png"))

                func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
                    guard let event = NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure("Cannot create mouse event") }
                    window.sendEvent(event)
                }
                func count() -> UInt64 { model.audio.diagnostics.acceptedTriggers }

                let beforeClick = count()
                try send(.leftMouseDown, center)
                checks["\(label).firstDownCaptured"] = surface.isInteracting
                try send(.leftMouseUp, center)
                checks["\(label).clickPreviewsOnce"] = count() - beforeClick == 1

                let beforeJitter = count()
                let jitterYaw = host.yaw
                try send(.leftMouseDown, center)
                try send(.leftMouseDragged, NSPoint(x: center.x + 1, y: center.y + 1))
                try send(.leftMouseUp, NSPoint(x: center.x + 1, y: center.y + 1))
                checks["\(label).smallJitterRemainsClick"] = count() - beforeJitter == 1 && host.yaw == jitterYaw

                let beforeDrag = count()
                let initialYaw = host.yaw, initialPitch = host.pitch
                try send(.leftMouseDown, center)
                try send(.leftMouseDragged, NSPoint(x: center.x + 75, y: center.y + 25))
                checks["\(label).rotatesWhileHeld"] = abs(host.yaw - initialYaw) > 0.1 && abs(host.pitch - initialPitch) > 0.05
                try send(.leftMouseUp, NSPoint(x: center.x + 75, y: center.y + 25))
                checks["\(label).dragDoesNotPreview"] = count() == beforeDrag
                checks["\(label).releaseEndsInteraction"] = !surface.isInteracting
                measurements["\(label).yawDelta"] = host.yaw - initialYaw
                measurements["\(label).pitchDelta"] = host.pitch - initialPitch
                try await Task.sleep(nanoseconds: 150_000_000)
                try await snapshot(host.renderView, to: directory.appendingPathComponent("\(label)-rotated.png"))
                checks["\(label).rotatedModelFitsViewport"] = fitsViewport(host.renderView)

                var allAnglesFit = true
                let beforeSweep = count()
                for dx in [-300.0, -150.0, 0.0, 150.0, 300.0] {
                    for dy in [-120.0, 120.0] {
                        try send(.leftMouseDown, center)
                        try send(.leftMouseDragged, NSPoint(x: center.x + dx, y: center.y + dy))
                        try await Task.sleep(nanoseconds: 50_000_000)
                        allAnglesFit = allAnglesFit && fitsViewport(host.renderView)
                        try send(.leftMouseDragged, center)
                        try send(.leftMouseUp, center)
                    }
                }
                checks["\(label).rotationSweepFitsViewport"] = allAnglesFit
                checks["\(label).rotationSweepDoesNotPreview"] = count() == beforeSweep

                let beforeReturn = count()
                let retainedYaw = host.yaw
                try send(.leftMouseDown, center)
                try send(.leftMouseDragged, NSPoint(x: center.x - 40, y: center.y))
                try send(.leftMouseDragged, center)
                try send(.leftMouseUp, center)
                checks["\(label).dragReturningToOriginDoesNotClick"] = count() == beforeReturn
                checks["\(label).nextDragKeepsPriorOrientation"] = abs(host.yaw - retainedYaw) < 0.0001

                let beforeOutside = count()
                try send(.leftMouseDown, center)
                model.config.visualizer.notchEnabled = true
                overlays.configurationChanged()
                let outside = NSPoint(x: center.x + 600, y: center.y + 200)
                try send(.leftMouseDragged, outside)
                // Wait past the real hover-dismiss timeout while the mouse is held.
                try await Task.sleep(nanoseconds: 750_000_000)
                let offscreen = NSPoint(x: -100_000, y: -100_000)
                overlays.trackNotchHover(mouse: offscreen, now: ProcessInfo.processInfo.systemUptime + 1)
                checks["\(label).heldDragSurvivesOutsideTimeout"] = window.isVisible && window.contentView != nil && surface.isInteracting
                checks["\(label).pitchIsClamped"] = host.pitch >= -0.4 && host.pitch <= 0.7
                try send(.leftMouseUp, outside)
                checks["\(label).outsideReleaseEndsWithoutPreview"] = !surface.isInteracting && count() == beforeOutside
                overlays.trackNotchHover(mouse: offscreen, now: ProcessInfo.processInfo.systemUptime + 1)
                checks["\(label).dismissesAfterRelease"] = !window.isVisible && window.contentView == nil
                checks["\(label).foregroundAppUnchanged"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !NSApp.isActive && !window.isKeyWindow
                model.config.visualizer.notchEnabled = false
                overlays.configurationChanged()
            }
            // Closing during a press (for example on sleep or a Space change)
            // must cancel tracking and release the renderer.
            overlays.previewNotch()
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let (window, host) = preview() else { throw Failure("Missing cancellation preview") }
            let surface = host.interactionSurface
            let point = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { window.sendEvent(down) }
            overlays.hideAll()
            try await Task.sleep(nanoseconds: 150_000_000)
            checks["closeCancelsTracking"] = !surface.isInteracting
            checks["closeReleasesScene"] = host.renderView.scene.anchors.isEmpty
        } catch {
            measurements["error"] = String(describing: error)
            checks["completed"] = false
        }
        let report: [String: Any] = [
            "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
            "checks": checks, "measurements": measurements,
            "inputMonitoringGranted": model.permissionGranted,
            "method": "NSWindow.sendEvent mouse replay through the non-key panel and real RealityKit renderer; no global input injection.",
            "limitations": "WindowServer delivery of a physical first click still requires user verification."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
    }

    private static func preview() -> (NSWindow, NotchInteractionHostView)? {
        func find(in view: NSView) -> NotchInteractionHostView? {
            if let host = view as? NotchInteractionHostView { return host }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        for window in NSApp.windows where window.isVisible {
            if let view = window.contentView, let host = find(in: view) { return (window, host) }
        }
        return nil
    }

    private static func snapshot(_ view: ARView, to url: URL) async throws {
        let rendered: NSImage? = await withCheckedContinuation { continuation in
            view.snapshot(saveToHDR: false) { continuation.resume(returning: $0) }
        }
        guard let data = rendered?.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { throw Failure("Missing 3D snapshot") }
        try png.write(to: url)
    }

    private static func fitsViewport(_ view: ARView) -> Bool {
        guard let object = view.scene.anchors.first?.children.first else { return false }
        let bounds = object.visualBounds(relativeTo: object)
        for x in [bounds.min.x, bounds.max.x] {
            for y in [bounds.min.y, bounds.max.y] {
                for z in [bounds.min.z, bounds.max.z] {
                    let worldPoint = object.convert(position: SIMD3(x, y, z), to: nil)
                    guard let point = view.project(worldPoint), view.bounds.insetBy(dx: 1, dy: 1).contains(point) else { return false }
                }
            }
        }
        return true
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
