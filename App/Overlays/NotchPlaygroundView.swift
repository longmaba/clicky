import AppKit
import SwiftUI
import RealityKit
import ClickyCore

@MainActor
struct NotchPlaygroundView: View {
    @ObservedObject var model: AppModel
    @State private var showSwitch = false
    var onInteractionChanged: (Bool) -> Void

    init(model: AppModel, showSwitch: Bool = false, onInteractionChanged: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        _showSwitch = State(initialValue: showSwitch)
        self.onInteractionChanged = onInteractionChanged
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(Color.clickyAmber).frame(width: 5, height: 5)
                    Text("CLICKY").font(.system(size: 9, weight: .bold)).tracking(2)
                }
                Spacer()
                Picker("Preview object", selection: $showSwitch) {
                    Text("Keyboard").tag(false)
                    Text("Switch").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 158).controlSize(.mini)
                Spacer()
                Button { model.toggleEnabled() } label: {
                    Image(systemName: model.config.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }.buttonStyle(.plain).foregroundStyle(model.config.enabled ? Color.clickyAmber : .secondary)
                    .help("Enable or mute Clicky")
            }.padding(.horizontal, 20).padding(.top, 17)
            KeyboardRealityView(model: model, showSwitch: showSwitch, onInteractionChanged: onInteractionChanged)
                .frame(height: 173)
                .overlay(alignment: .bottom) {
                    Text("DRAG TO ROTATE · CLICK TO LISTEN").font(.system(size: 7, weight: .medium)).tracking(1.4).foregroundStyle(.white.opacity(0.38)).padding(.bottom, 5)
                        .allowsHitTesting(false)
                }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentProfile?.name ?? "Thocky").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Text((model.currentProfile?.releaseSamples?.isEmpty == false ? "Press + release · " : "") + (model.currentProfile?.subtitle ?? "Find your sound"))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        .help(model.currentProfile?.subtitle ?? "Find your sound")
                }
                Spacer()
                Button { model.previewProfile(model.config.sound.profileID) } label: {
                    Image(systemName: "play.fill").font(.system(size: 12)).padding(9).background(.white.opacity(0.09), in: Circle())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.profiles) { profile in
                            Button { model.selectProfile(profile.id); model.previewProfile(profile.id) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(clickyHex: profile.color)).frame(width: 5, height: 5)
                                    Text(profile.name).font(.system(size: 10, weight: .medium)).fixedSize()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(model.config.sound.profileID == profile.id ? Color.white.opacity(0.15) : Color.white.opacity(0.055), in: Capsule())
                                .overlay(Capsule().stroke(model.config.sound.profileID == profile.id ? Color.clickyAmber.opacity(0.55) : .clear))
                            }.buttonStyle(.plain).id(profile.id)
                        }
                    }.padding(.horizontal, 17)
                }.onAppear { proxy.scrollTo(model.config.sound.profileID, anchor: .center) }
                    .onChange(of: model.config.sound.profileID) { id in
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
            }.padding(.bottom, 15)
        }
        .foregroundStyle(.white.opacity(0.93))
        .background(Color(red: 0.055, green: 0.055, blue: 0.065), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .preferredColorScheme(.dark)
    }
}

/// Owns AppKit mouse delivery above RealityKit's private view hierarchy. The
/// nonactivating notch panel must accept the first click without becoming key.
@MainActor
final class NotchInteractionSurface: NSView {
    var onInteractionChanged: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    private(set) var isInteracting = false
    private var origin = CGPoint.zero
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        cancelInteraction()
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        origin = point
        didDrag = false
        isInteracting = true
        onDragBegan?()
        onInteractionChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteracting else { return }
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteracting else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateDrag(at: point)
        let shouldPreview = !didDrag && bounds.contains(point)
        // Finish the action before releasing the panel's hover hold, which may
        // remove the entire view when the pointer has left the panel.
        if shouldPreview { onClick?(point) }
        cancelInteraction()
    }

    private func updateDrag(at point: CGPoint) {
        let translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        if translation.width * translation.width + translation.height * translation.height >= 9 {
            didDrag = true
        }
        // This stays true even if the pointer returns to the mouse-down point.
        if didDrag { onDragChanged?(translation) }
    }

    func cancelInteraction() {
        guard isInteracting else { return }
        isInteracting = false
        didDrag = false
        onInteractionChanged?(false)
    }

    override func cancelOperation(_ sender: Any?) { cancelInteraction() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelInteraction() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelInteraction()
    }
}

@MainActor
final class NotchInteractionHostView: NSView {
    let renderView = ARView(frame: .zero)
    let interactionSurface = NotchInteractionSurface(frame: .zero)
    fileprivate var readRotation: (() -> SIMD2<Float>)?
    fileprivate var refitViewport: (() -> Void)?
    var yaw: Float { readRotation?().x ?? 0 }
    var pitch: Float { readRotation?().y ?? 0 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        renderView.environment.background = .color(NSColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1))
        renderView.autoresizingMask = [.width, .height]
        interactionSurface.autoresizingMask = [.width, .height]
        addSubview(renderView)
        addSubview(interactionSurface, positioned: .above, relativeTo: renderView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        renderView.frame = bounds
        interactionSurface.frame = bounds
        refitViewport?()
    }
}

@MainActor
private struct KeyboardRealityView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var showSwitch: Bool
    var onInteractionChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NotchInteractionHostView {
        let host = NotchInteractionHostView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.view = host.renderView
        coordinator.build(showSwitch: showSwitch)
        host.interactionSurface.onInteractionChanged = onInteractionChanged
        host.interactionSurface.onDragBegan = { [weak coordinator] in coordinator?.beginDrag() }
        host.interactionSurface.onDragChanged = { [weak coordinator] translation in coordinator?.drag(translation) }
        host.interactionSurface.onClick = { [weak coordinator, weak host] point in
            guard let host else { return }
            coordinator?.click(at: host.renderView.convert(point, from: host.interactionSurface))
        }
        host.readRotation = { [weak coordinator] in SIMD2(coordinator?.yaw ?? 0, coordinator?.pitch ?? 0) }
        host.refitViewport = { [weak coordinator] in coordinator?.fitCamera() }
        return host
    }

    func updateNSView(_ host: NotchInteractionHostView, context: Context) {
        let coordinator = context.coordinator
        host.interactionSurface.onInteractionChanged = onInteractionChanged
        if coordinator.showSwitch != showSwitch {
            host.interactionSurface.cancelInteraction()
            coordinator.build(showSwitch: showSwitch)
        }
        coordinator.update(pressedKeys: model.pressedKeys, color: model.currentProfile?.color ?? "E99244")
    }

    static func dismantleNSView(_ host: NotchInteractionHostView, coordinator: Coordinator) {
        host.interactionSurface.cancelInteraction()
        host.interactionSurface.onInteractionChanged = nil
        host.interactionSurface.onDragBegan = nil
        host.interactionSurface.onDragChanged = nil
        host.interactionSurface.onClick = nil
        host.readRotation = nil
        host.refitViewport = nil
        host.renderView.isHidden = true
        host.renderView.scene.anchors.removeAll()
        coordinator.view = nil
        coordinator.keys.removeAll()
        coordinator.camera = nil
        coordinator.modelCorners.removeAll()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var model: AppModel?
        weak var view: ARView?
        var showSwitch = false
        var object = Entity()
        var camera: PerspectiveCamera?
        var modelCorners: [SIMD3<Float>] = []
        var keys: [String: ModelEntity] = [:]
        var lastPressed: Set<String> = []
        var lastColor = ""
        var yaw: Float = -0.12
        var pitch: Float = 0
        var startYaw: Float = 0
        var startPitch: Float = 0

        init(model: AppModel) { self.model = model }

        func build(showSwitch: Bool) {
            guard let view else { return }
            self.showSwitch = showSwitch
            view.scene.anchors.removeAll()
            keys.removeAll(); lastPressed = []; lastColor = ""
            object = Entity()
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(object)
            let camera = PerspectiveCamera()
            self.camera = camera
            camera.camera.fieldOfViewInDegrees = 28
            if #available(macOS 15.0, *) { camera.camera.fieldOfViewOrientation = .vertical }
            camera.look(at: SIMD3<Float>(0, 0, 0), from: showSwitch ? SIMD3<Float>(0, 2.0, 3.6) : SIMD3<Float>(0, 3.7, 4.5), relativeTo: nil)
            anchor.addChild(camera)
            let light = DirectionalLight()
            light.light.intensity = 1800
            light.light.color = .white
            light.look(at: .zero, from: SIMD3<Float>(-3, 6, 4), relativeTo: nil)
            anchor.addChild(light)
            let fill = PointLight()
            fill.light.intensity = 550
            fill.light.attenuationRadius = 12
            fill.position = SIMD3<Float>(3, 3, -2)
            anchor.addChild(fill)
            if showSwitch { buildSwitch() } else { buildKeyboard() }
            let bounds = object.visualBounds(relativeTo: object)
            modelCorners = [bounds.min.x, bounds.max.x].flatMap { x in
                [bounds.min.y, bounds.max.y].flatMap { y in
                    [bounds.min.z, bounds.max.z].map { z in SIMD3<Float>(x, y, z) }
                }
            }
            object.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
            object.generateCollisionShapes(recursive: true)
            view.scene.addAnchor(anchor)
            fitCamera()
        }

        func fitCamera() {
            guard let view, let camera, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let initialPosition = showSwitch ? SIMD3<Float>(0, 2.0, 3.6) : SIMD3<Float>(0, 3.7, 4.5)
            let backward = simd_normalize(initialPosition)
            let right = SIMD3<Float>(1, 0, 0)
            let up = simd_cross(backward, right)
            let tangentY = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
            let tangentX = tangentY * Float(view.bounds.width / view.bounds.height)
            // A centered 90% viewing area leaves 5% padding at every edge.
            // Solve each corner's perspective inequality for camera distance;
            // keeping the nearest depth term avoids clipping at steep angles.
            var distance = simd_length(initialPosition)
            for corner in modelCorners {
                let point = object.convert(position: corner, to: nil)
                let horizontal = abs(simd_dot(point, right)) / (tangentX * 0.9)
                let vertical = abs(simd_dot(point, up)) / (tangentY * 0.9)
                distance = max(distance, simd_dot(point, backward) + max(horizontal, vertical))
            }
            camera.look(at: .zero, from: backward * distance, relativeTo: nil)
        }

        private func box(_ size: SIMD3<Float>, color: NSColor, corner: Float = 0.025, metallic: Bool = false) -> ModelEntity {
            ModelEntity(mesh: .generateBox(size: size, cornerRadius: corner), materials: [SimpleMaterial(color: color, roughness: 0.5, isMetallic: metallic)])
        }

        private func buildKeyboard() {
            let base = box(SIMD3<Float>(4.62, 0.21, 1.91), color: NSColor(white: 0.26, alpha: 1), corner: 0.1, metallic: true)
            base.position.y = -0.1
            object.addChild(base)
            let plate = box(SIMD3<Float>(4.53, 0.045, 1.81), color: NSColor(white: 0.12, alpha: 1), corner: 0.065)
            plate.position.y = 0.025
            object.addChild(plate)
            for key in KeyboardLayout.keys {
                let unit: Float = 0.29
                let cap = box(SIMD3<Float>(Float(key.width) * unit - 0.025, 0.14, 0.245), color: .init(white: 0.83, alpha: 1), corner: 0.025)
                cap.position = SIMD3<Float>((Float(key.x + key.width / 2) - 7.5) * unit, 0.12, (Float(key.y) - 2.5) * 0.285)
                cap.name = key.id
                object.addChild(cap)
                keys[key.id] = cap
            }
        }

        private func buildSwitch() {
            let housing = box(SIMD3<Float>(1.1, 0.43, 1.1), color: NSColor(white: 0.68, alpha: 1), corner: 0.1)
            housing.position.y = -0.15
            object.addChild(housing)
            let top = box(SIMD3<Float>(0.95, 0.25, 0.95), color: NSColor(white: 0.89, alpha: 1), corner: 0.08)
            top.position.y = 0.13
            object.addChild(top)
            let stem = Entity()
            let x = box(SIMD3<Float>(0.53, 0.26, 0.17), color: .orange, corner: 0.018)
            let z = box(SIMD3<Float>(0.17, 0.26, 0.53), color: .orange, corner: 0.018)
            x.position.y = 0.37; z.position.y = 0.37
            stem.addChild(x); stem.addChild(z); object.addChild(stem)
            keys["switch-x"] = x; keys["switch-z"] = z
            for side: Float in [-1, 1] {
                let leg = box(SIMD3<Float>(0.08, 0.35, 0.045), color: NSColor(red: 0.75, green: 0.6, blue: 0.24, alpha: 1), corner: 0.005, metallic: true)
                leg.position = SIMD3<Float>(side * 0.27, -0.5, 0.1)
                object.addChild(leg)
            }
        }

        func update(pressedKeys: Set<String>, color: String) {
            if color != lastColor {
                let nsColor = NSColor(Color(clickyHex: color))
                for (id, key) in keys {
                    let accent = showSwitch || ["7:41", "7:40", "7:44"].contains(id)
                    key.model?.materials = [SimpleMaterial(color: accent ? nsColor : NSColor(white: 0.83, alpha: 1), roughness: 0.6, isMetallic: false)]
                }
                lastColor = color
            }
            if pressedKeys != lastPressed {
                for (id, key) in keys {
                    let down = showSwitch ? !pressedKeys.isEmpty : pressedKeys.contains(id)
                    var transform = key.transform
                    transform.translation.y = (showSwitch ? 0.37 : 0.12) - (down ? 0.075 : 0)
                    key.move(to: transform, relativeTo: object, duration: 0.07, timingFunction: .easeOut)
                }
                lastPressed = pressedKeys
            }
        }

        func beginDrag() {
            startYaw = yaw
            startPitch = pitch
        }

        func drag(_ translation: CGSize) {
            yaw = startYaw + Float(translation.width) * 0.008
            pitch = max(-0.4, min(0.7, startPitch + Float(translation.height) * 0.006))
            object.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
            fitCamera()
        }

        func click(at point: CGPoint) {
            guard let model, let view else { return }
            let hit = view.entity(at: point)
            let keyID = hit?.name ?? ""
            model.previewProfile(model.config.keyOverrides[keyID]?.profileID ?? model.config.sound.profileID, keyID: keyID)
            if showSwitch {
                for key in keys.values {
                    var down = key.transform; down.translation.y = 0.295
                    key.move(to: down, relativeTo: object, duration: 0.08, timingFunction: .easeOut)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak key, weak self] in
                        guard let key, let self, self.view != nil else { return }
                        var up = key.transform; up.translation.y = 0.37
                        key.move(to: up, relativeTo: self.object, duration: 0.08, timingFunction: .easeOut)
                    }
                }
            } else if let cap = keys[keyID] {
                var down = cap.transform; down.translation.y = 0.045
                cap.move(to: down, relativeTo: object, duration: 0.07, timingFunction: .easeOut)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak cap, weak self] in
                    guard let cap, let self, self.view != nil else { return }
                    var up = cap.transform; up.translation.y = 0.12
                    cap.move(to: up, relativeTo: self.object, duration: 0.08, timingFunction: .easeOut)
                }
            }
        }
    }
}
