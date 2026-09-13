import AppKit
import SwiftUI
import ClickyCore

extension Color {
    static let clickyAmber = Color(red: 0.95, green: 0.56, blue: 0.19)
    init(clickyHex hex: String) {
        let n = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xED963D
        self.init(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case sound = "Sound", keyboard = "Your Keyboard", visualizer = "Visualizer", extras = "Extra Sounds", general = "General", about = "About"
    var id: String { rawValue }
    var stableID: String {
        switch self { case .sound: return "sound"; case .keyboard: return "keyboard"; case .visualizer: return "visualizer"; case .extras: return "extras"; case .general: return "general"; case .about: return "about" }
    }
    var symbol: String {
        switch self {
        case .sound: return "waveform"
        case .keyboard: return "keyboard"
        case .visualizer: return "sparkles.rectangle.stack"
        case .extras: return "cursorarrow.click.2"
        case .general: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .sound: return "Find the feel of your next favorite keyboard."
        case .keyboard: return "Make every key sound like yours."
        case .visualizer: return "A little personality with every keystroke."
        case .extras: return "Give your clicks and returns their own voice."
        case .general: return "At home in your menu bar."
        case .about: return "A better soundtrack for your fingertips."
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    private var page: SettingsPage { SettingsPage.allCases.first(where: { $0.stableID == model.settingsTab }) ?? .sound }
    @State private var selectedKey = "7:44"
    @State private var favoriteName = ""
    @State private var testText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !model.permissionGranted { permissionBanner }
                        if model.secureInput {
                            statusBanner("Secure input is active", detail: "Sounds resume when macOS allows keyboard monitoring again.", symbol: "lock.shield")
                        }
                        if let notice = model.notice {
                            HStack(alignment: .top) {
                                Image(systemName: "info.circle").foregroundStyle(Color.clickyAmber)
                                Text(notice).font(.callout)
                                Spacer()
                                Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            }.padding(14).background(Color.clickyAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        switch page {
                        case .sound: soundPage
                        case .keyboard: keyboardPage
                        case .visualizer: visualizerPage
                        case .extras: extrasPage
                        case .general: generalPage
                        case .about: aboutPage
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.clickyAmber)
        .frame(minWidth: 880, idealWidth: 1040, minHeight: 650, idealHeight: 790)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ClickyMark().frame(width: 40, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clicky").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("MAKE TYPING FEEL GOOD").font(.system(size: 7.5, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 31)
            VStack(spacing: 6) {
                ForEach(SettingsPage.allCases) { item in
                    Button { model.settingsTab = item.stableID } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 22)
                            Text(item.rawValue).font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            Spacer()
                            if page == item { Circle().fill(Color.clickyAmber).frame(width: 5, height: 5) }
                        }
                        .foregroundStyle(page == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(page == item ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Circle().fill(model.config.enabled && model.permissionGranted ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(model.config.enabled ? (model.permissionGranted ? "Ready when you are" : "Permission needed") : "Taking a quiet moment")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Keyboard sounds").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Keyboard sounds", isOn: $model.config.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text(model.config.general.shortcut.label + " to toggle")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }.padding(18).background(.primary.opacity(0.025))
        }
        .frame(width: 220)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.rawValue).font(.system(size: 25, weight: .bold, design: .rounded))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.previewProfile(model.config.sound.profileID) } label: {
                Label("Listen", systemImage: "play.fill").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 4)
            }.buttonStyle(.bordered).help("Preview the current sound")
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Let Clicky hear your physical keys", systemImage: "hand.raised.circle.fill").font(.system(size: 14, weight: .semibold))
            Text("Enable Input Monitoring in System Settings so sounds work in every app. Clicky never reads or saves what you type.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Enable Input Monitoring") { model.requestInputPermission() }.buttonStyle(.borderedProminent)
                Button("Open System Settings") { model.openInputSettings() }.buttonStyle(.borderless)
                Button("Show Clicky in Finder") { model.revealAppInFinder() }.buttonStyle(.borderless)
            }
            Text("If Clicky is missing, click + in Input Monitoring and add the app shown in Finder. Then turn on its switch.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clickyAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.clickyAmber.opacity(0.24)))
    }

    private func statusBanner(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var soundPage: some View {
        Group {
            VStack(alignment: .leading, spacing: 13) {
                sectionHeading("THE COLLECTION", trailing: "10 distinct personalities")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.profiles) { profile in
                        ProfileCard(profile: profile, selected: model.config.sound.profileID == profile.id,
                                    select: { model.selectProfile(profile.id) }, preview: { model.previewProfile(profile.id) })
                    }
                }
                Text("Hover to audition · Click to make it yours").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ClickyCard {
                VStack(alignment: .leading, spacing: 17) {
                    sliderRow("Volume", symbol: "speaker.wave.2", value: $model.config.sound.volume, range: 0...1, suffix: "%")
                    Divider()
                    HStack(spacing: 18) {
                        Text("Modifier sounds").font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 8)
                        Picker("Modifier sounds", selection: $model.config.sound.modifierSoundMode) {
                            ForEach(ModifierSoundMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                    }
                    Text("Soft plays Command, Shift, Option, Control, and Fn at 25% volume. Silent mutes them; Full uses normal volume. Other keys play immediately.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                sectionHeading("MAKE IT YOURS")
                HStack(alignment: .top, spacing: 14) {
                    ClickyCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tone & pitch").font(.system(size: 13, weight: .semibold))
                            TonePitchPad(tone: $model.config.sound.tone, pitch: $model.config.sound.pitch) { model.previewProfile(model.config.sound.profileID) }
                            HStack {
                                Text("Drag to shape your sound").font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset") { model.config.sound.tone = 0; model.config.sound.pitch = 0 }.font(.system(size: 10)).buttonStyle(.borderless)
                            }
                        }
                    }
                    ClickyCard {
                        VStack(spacing: 17) {
                            settingToggle("Spatial audio", detail: "Sound follows each key’s position.", value: $model.config.sound.spatial)
                            sliderRow("Stereo width", value: $model.config.sound.spatialWidth, range: 0...1, suffix: "%").disabled(!model.config.sound.spatial)
                            Divider()
                            settingToggle("Natural variation", detail: "Subtle changes with every stroke.", value: $model.config.sound.variation)
                            settingToggle("Normalize loudness", detail: "A balanced level across profiles.", value: $model.config.sound.normalization)
                            sliderRow("Home-row softness", value: $model.config.sound.homeRowSoftness, range: 0...1, suffix: "%")
                        }
                    }
                }
            }
            favoriteSection
            ClickyCard {
                VStack(alignment: .leading, spacing: 13) {
                    Text("Take it for a spin").font(.system(size: 13, weight: .semibold))
                    TextField("The quick brown fox has a very satisfying keyboard…", text: $testText).textFieldStyle(.roundedBorder)
                    Text("Your typing stays in this field and is never saved.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Reset sound settings") { model.resetSound() }.buttonStyle(.borderless).font(.callout) }
        }
    }

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionHeading("YOUR FAVORITES", trailing: "\(model.config.favorites.count) of 6")
            ClickyCard {
                VStack(spacing: 13) {
                    if model.config.favorites.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "star").font(.title2).foregroundStyle(Color.clickyAmber)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Keep a good thing close").font(.system(size: 13, weight: .medium))
                                Text("Save your complete sound setup, including individual keys.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    } else {
                        ForEach(model.config.favorites) { favorite in
                            HStack {
                                Image(systemName: "star.fill").foregroundStyle(Color.clickyAmber)
                                Button(favorite.name) { model.applyFavorite(favorite) }.buttonStyle(.plain)
                                Spacer()
                                Button("Apply") { model.applyFavorite(favorite) }.controlSize(.small)
                                Button { model.deleteFavorite(favorite.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }.font(.system(size: 12))
                        }
                    }
                    if model.config.favorites.count < 6 {
                        HStack {
                            TextField("Name this sound…", text: $favoriteName).textFieldStyle(.roundedBorder)
                            Button("Save favorite") {
                                let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
                                model.saveFavorite(name: name.isEmpty ? (model.currentProfile?.name ?? "My sound") : name)
                                favoriteName = ""
                            }.controlSize(.regular)
                        }
                    }
                }
            }
        }
    }

    private var keyboardPage: some View {
        Group {
            ClickyCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Your keyboard, your rules").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Label("Live", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(model.permissionGranted ? .green : .secondary)
                    }
                    KeyboardView(pressedKeys: model.pressedKeys, selectedKey: selectedKey, customizedKeys: Set(model.config.keyOverrides.keys), theme: .graphite) { selectedKey = $0 }
                        .frame(height: 208)
                    Text("Choose a key to customize it. Amber dots mark your overrides.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ClickyCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(KeyboardLayout.keys.first(where: { $0.id == selectedKey })?.label ?? selectedKey)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .frame(minWidth: 42).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Individual key sound").font(.headline)
                            Text(model.config.keyOverrides[selectedKey] == nil ? "Using your global sound settings" : "This key has its own character")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset key") { model.resetKey(selectedKey) }.disabled(model.config.keyOverrides[selectedKey] == nil)
                    }
                    Picker("Sound profile", selection: keyProfileBinding) {
                        Text("Use global profile").tag("")
                        ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                    }
                    keyOverrideSlider("Volume", keyPath: \.volume, global: model.config.sound.volume, range: 0...1, suffix: "%")
                    keyOverrideSlider("Tone", keyPath: \.tone, global: model.config.sound.tone, range: -1...1, suffix: "")
                    keyOverrideSlider("Pitch", keyPath: \.pitch, global: model.config.sound.pitch, range: -1...1, suffix: " st", displayMultiplier: 6)
                }
            }
            Text("Physical key positions are independent of your input language. External keyboards work too.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var keyProfileBinding: Binding<String> {
        Binding(get: { model.config.keyOverrides[selectedKey]?.profileID ?? "" }, set: { value in
            var override = model.config.keyOverrides[selectedKey] ?? KeyOverride()
            override.profileID = value.isEmpty ? nil : value
            storeKeyOverride(override)
        })
    }

    private func storeKeyOverride(_ override: KeyOverride) {
        if override == KeyOverride() { model.resetKey(selectedKey) }
        else { model.config.keyOverrides[selectedKey] = override }
    }

    private func keyOverrideSlider(_ title: String, keyPath: WritableKeyPath<KeyOverride, Float?>, global: Float, range: ClosedRange<Float>, suffix: String, displayMultiplier: Float = 1) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle("Override \(title.lowercased())", isOn: Binding(get: { model.config.keyOverrides[selectedKey]?[keyPath: keyPath] != nil }, set: { enabled in
                    var override = model.config.keyOverrides[selectedKey] ?? KeyOverride()
                    override[keyPath: keyPath] = enabled ? global : nil
                    storeKeyOverride(override)
                })).toggleStyle(.checkbox).font(.callout)
                Spacer()
            }
            sliderRow(title, value: Binding(get: { model.config.keyOverrides[selectedKey]?[keyPath: keyPath] ?? global }, set: { value in
                var override = model.config.keyOverrides[selectedKey] ?? KeyOverride()
                override[keyPath: keyPath] = value
                storeKeyOverride(override)
            }), range: range, suffix: suffix, displayMultiplier: displayMultiplier)
            .disabled(model.config.keyOverrides[selectedKey]?[keyPath: keyPath] == nil)
        }
    }

    private var visualizerPage: some View {
        Group {
            ClickyCard {
                settingToggle("Show visualizer", detail: "A floating companion for your keystrokes.", value: $model.config.visualizer.enabled)
            }
            VStack(alignment: .leading, spacing: 13) {
                sectionHeading("CHOOSE YOUR LOOK")
                HStack(spacing: 10) {
                    ForEach(VisualizerStyle.allCases) { style in
                        Button { model.config.visualizer.style = style; model.previewVisualizer() } label: {
                            VStack(spacing: 12) {
                                Image(systemName: style.symbol).font(.system(size: 28, weight: .light)).frame(height: 34)
                                Text(style == .keystrokes ? "Keystrokes" : style.title).font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 23)
                            .foregroundStyle(model.config.visualizer.style == style ? Color.clickyAmber : .secondary)
                            .background(model.config.visualizer.style == style ? Color.clickyAmber.opacity(0.1) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.config.visualizer.style == style ? Color.clickyAmber.opacity(0.6) : Color.primary.opacity(0.07)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            ClickyCard {
                VStack(spacing: 19) {
                    HStack {
                        Text("Theme").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("Theme", selection: $model.config.visualizer.theme) {
                            ForEach(VisualizerTheme.allCases) { theme in Text(theme.title).tag(theme) }
                        }.labelsHidden().frame(width: 180)
                    }
                    Picker("Position", selection: $model.config.visualizer.placement) {
                        ForEach(VisualizerPlacement.allCases) { position in Text(position.title).tag(position) }
                    }
                    Picker("Display", selection: Binding(get: { model.config.visualizer.displayID ?? "" }, set: { model.config.visualizer.displayID = $0.isEmpty ? nil : $0 })) {
                        Text("Display under cursor").tag("")
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                            Text(screen.localizedName).tag(clickyDisplayIdentifier(screen))
                        }
                    }
                    doubleSlider("Size", value: $model.config.visualizer.scale, range: 0.5...2, format: "%.0f%%", multiplier: 100)
                    doubleSlider("Edge / cursor offset", value: $model.config.visualizer.offset, range: 8...120, format: "%.0f pt")
                    doubleSlider("Hide after inactivity", value: $model.config.visualizer.dismissDelay, range: 0.3...5, format: "%.1f s")
                    settingToggle("Always visible", detail: "Keep the visualizer on screen between keystrokes.", value: $model.config.visualizer.keepVisible)
                    settingToggle("Hide in fullscreen", detail: "Keep fullscreen apps free of distractions.", value: $model.config.visualizer.hideInFullscreen)
                    if model.config.visualizer.style == .keystrokes {
                        settingToggle("Vertical keystrokes", detail: "Stack recent shortcuts from top to bottom.", value: $model.config.visualizer.verticalKeystrokes)
                    }
                    if model.config.visualizer.style == .combo {
                        doubleSlider("Combo timeout", value: $model.config.visualizer.comboTimeout, range: 0.5...10, format: "%.1f s")
                        settingToggle("Keep your combo", detail: "Preserve the count during typing breaks.", value: $model.config.visualizer.keepCombo)
                    }
                    if model.config.visualizer.placement == .random {
                        Stepper("Change position every \(model.config.visualizer.shuffleEvery) keys", value: $model.config.visualizer.shuffleEvery, in: 1...30)
                        Picker("Motion", selection: $model.config.visualizer.shuffleMotion) {
                            ForEach(ShuffleMotion.allCases) { motion in Text(motion.title).tag(motion) }
                        }
                    }
                    HStack { Spacer(); Button("Preview visualizer") { model.previewVisualizer() }.buttonStyle(.borderedProminent) }
                }
            }
            ClickyCard {
                VStack(alignment: .leading, spacing: 14) {
                    settingToggle("Notch playground", detail: "A tiny 3D keyboard with a sound picker at the top of your screen.", value: $model.config.visualizer.notchEnabled)
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.topthird.inset.filled").font(.title2).foregroundStyle(Color.clickyAmber)
                        Text("Hover near the center of the menu bar to open. Scroll through profiles, click to select, and drag the keyboard to look around.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var extrasPage: some View {
        Group {
            extraSoundCard(isMouse: true)
            extraSoundCard(isMouse: false)
            ClickyCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Bring your own sounds", systemImage: "waveform.badge.plus").font(.headline)
                    Text("Import WAV, AIFF, MP3, or M4A. Use one recording for a whole stroke, or add a separate release sound for paired playback.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Imported files are copied into Clicky’s library and decoded before playback.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func extraSoundCard(isMouse: Bool) -> some View {
        let sound = isMouse ? $model.config.sound.mouseSound : $model.config.sound.enterSound
        let volume = isMouse ? $model.config.sound.mouseVolume : $model.config.sound.enterVolume
        let custom = isMouse ? model.config.sound.customMouse : model.config.sound.customEnter
        return ClickyCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 13) {
                    Image(systemName: isMouse ? "computermouse" : "return").font(.system(size: 24, weight: .light)).foregroundStyle(Color.clickyAmber).frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isMouse ? "Mouse clicks" : "Enter key").font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(isMouse ? "A satisfying click, wherever you click." : "Put a little punctuation on your day.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.previewExtra(sound.wrappedValue, forMouse: isMouse) } label: { Image(systemName: "play.fill") }
                        .disabled(sound.wrappedValue == .none || (sound.wrappedValue == .custom && custom == nil))
                }
                Picker("Sound", selection: sound) {
                    ForEach(ExtraSound.allCases) { item in Text(item == .none && !isMouse ? "Use keyboard profile" : item.title).tag(item) }
                }
                sliderRow("Volume", symbol: "speaker.wave.2", value: volume, range: 0...1, suffix: "%")
                    .disabled(sound.wrappedValue == .none)
                if sound.wrappedValue == .custom {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(.secondary)
                            Text(custom?.name ?? "No sound imported").font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(custom == nil ? "Import press sound…" : "Replace press…") { model.importSound(forMouse: isMouse, release: false) }
                        }
                        HStack {
                            Text(custom?.releasePath == nil ? "Release sound is optional" : "Separate release sound added").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            if custom?.releasePath != nil {
                                Button("Remove release") {
                                    if isMouse { model.config.sound.customMouse?.releasePath = nil } else { model.config.sound.customEnter?.releasePath = nil }
                                }.buttonStyle(.borderless)
                            }
                            Button("Import release…") { model.importSound(forMouse: isMouse, release: true) }.disabled(custom == nil)
                        }
                    }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var generalPage: some View {
        Group {
            sectionHeading("AT YOUR FINGERTIPS")
            ClickyCard {
                VStack(spacing: 19) {
                    settingToggle("Launch at login", detail: "Your keyboard soundtrack, ready when you are.", value: $model.config.general.launchAtLogin)
                    settingToggle("Show in Dock", detail: "Keep Clicky alongside your other apps.", value: $model.config.general.showInDock)
                    settingToggle("Show in menu bar", detail: "Quick access to sounds and settings.", value: $model.config.general.showMenuBar)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Toggle shortcut").font(.system(size: 12, weight: .medium))
                            Text(model.isRecordingShortcut ? "Press a key with your preferred modifiers." : "Enable or mute sounds from any app.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.isRecordingShortcut ? "Cancel recording" : model.config.general.shortcut.label) {
                            if model.isRecordingShortcut { model.endShortcutRecording() } else { model.beginShortcutRecording() }
                        }.font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    Stepper("Shortcut taps: \(model.config.general.shortcut.tapCount)", value: $model.config.general.shortcut.tapCount, in: 1...5)
                    doubleSlider("Tap window", value: $model.config.general.shortcut.interval, range: 0.3...3, format: "%.1f s")
                }
            }
            sectionHeading("AUDIO OUTPUT")
            ClickyCard {
                VStack(spacing: 19) {
                    HStack {
                        Picker("Play through", selection: Binding(get: { model.config.sound.outputDeviceUID ?? "" }, set: { model.config.sound.outputDeviceUID = $0.isEmpty ? nil : $0 })) {
                            Text("System default").tag("")
                            ForEach(model.outputs) { output in Text(output.name + (output.isHeadphones ? "  ♫" : "")).tag(output.id) }
                        }
                        Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh audio devices")
                    }
                    settingToggle("Mute on headphones", detail: "Pause sounds while the selected output is headphones.", value: $model.config.sound.pauseOnHeadphones)
                    settingToggle("Orbiting stereo", detail: "Gently move the sound around the stereo field.", value: $model.config.sound.orbit)
                    settingToggle("Head tracking", detail: "Follow supported headphone motion on macOS 14 or later.", value: $model.config.sound.headTracking)
                        .disabled(!headTrackingOSAvailable)
                    if let status = model.audioStatus {
                        HStack { Image(systemName: "waveform"); Text(status); Spacer() }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            sectionHeading("PRIVACY & PERMISSIONS")
            ClickyCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 12) {
                        Image(systemName: model.permissionGranted ? "checkmark.shield.fill" : "hand.raised.fill")
                            .font(.title2).foregroundStyle(model.permissionGranted ? .green : Color.clickyAmber)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input Monitoring").font(.system(size: 13, weight: .semibold))
                            Text(model.permissionGranted ? "Allowed · Physical keys only · Never recorded" : "Required for sounds outside Clicky").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("System Settings…") { model.openInputSettings() }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Text("If Clicky is missing, click + in Input Monitoring and add the app shown in Finder. Then turn on its switch.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Show Clicky in Finder") { model.revealAppInFinder() }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var headTrackingOSAvailable: Bool { if #available(macOS 14, *) { return true }; return false }

    private var aboutPage: some View {
        VStack(spacing: 23) {
            ClickyMark().frame(width: 106, height: 110).padding(.top, 25)
            VStack(spacing: 8) {
                Text("Clicky").font(.system(size: 36, weight: .bold, design: .rounded))
                Text("Every key has a little personality.").font(.system(size: 15)).foregroundStyle(.secondary)
                Text("Version " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            ClickyCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Ten keyboard personalities", systemImage: "keyboard").font(.headline)
                    Text("Recorded mechanical keyboard sounds, shaped to feel at home on your Mac. Built with native SwiftUI, AppKit, and a low-latency audio engine.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Label("Your words are yours", systemImage: "lock.shield").font(.headline)
                    Text("Clicky reacts to physical key positions. It works offline, does not reconstruct typed text, and stores only your settings and sound library.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Text("Sound source: Thock vs Creamy vs Marbly vs Clack | Best Sound Profile? Ultimate Keyboard Sound Test · Gzko0BoULdw.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            Text("Made for the joy of typing.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity)
    }
}

struct ClickyMark: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: g.size.width * 0.23).fill(Color(red: 0.66, green: 0.29, blue: 0.06)).offset(y: g.size.height * 0.04)
                RoundedRectangle(cornerRadius: g.size.width * 0.23)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.73, blue: 0.29), .clickyAmber, Color(red: 0.91, green: 0.4, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: g.size.width * 0.23).stroke(.white.opacity(0.55), lineWidth: 1))
                RoundedRectangle(cornerRadius: g.size.width * 0.17).stroke(.white.opacity(0.24), lineWidth: 1).padding(g.size.width * 0.1)
                Image(systemName: "waveform").font(.system(size: g.size.width * 0.48, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .brown.opacity(0.3), radius: 1, y: 2)
            }
        }
    }
}

struct ClickyCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.07)))
    }
}

private struct ProfileCard: View {
    var profile: SoundProfileManifest
    var selected: Bool
    var select: () -> Void
    var preview: () -> Void
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(clickyHex: profile.color).opacity(selected ? 0.23 : 0.13))
                    Image(systemName: "waveform").font(.system(size: 20, weight: .medium)).foregroundStyle(Color(clickyHex: profile.color))
                }.frame(width: 43, height: 43)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(profile.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 3)
                Image(systemName: selected ? "checkmark.circle.fill" : "play.circle")
                    .font(.system(size: 17)).foregroundStyle(selected ? Color.clickyAmber : Color.secondary.opacity(hovered ? 0.8 : 0.3))
            }
            .padding(12)
            .background(selected ? Color.clickyAmber.opacity(0.075) : Color(nsColor: .controlBackgroundColor).opacity(hovered ? 1 : 0.65), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? Color.clickyAmber.opacity(0.8) : Color.primary.opacity(hovered ? 0.16 : 0.07), lineWidth: selected ? 1.3 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            hoverTask?.cancel()
            if inside {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    if !Task.isCancelled { preview() }
                }
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .accessibilityLabel(profile.name + (selected ? ", selected" : ""))
    }
}

struct TonePitchPad: View {
    @Binding var tone: Float
    @Binding var pitch: Float
    var onEnd: () -> Void = {}
    var body: some View {
        VStack(spacing: 6) {
            Text("HIGHER").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(.tertiary)
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color.clickyAmber.opacity(0.13), Color.purple.opacity(0.035), Color.blue.opacity(0.07)], startPoint: .topTrailing, endPoint: .bottomLeading))
                    Path { p in
                        p.move(to: CGPoint(x: geometry.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
                        p.move(to: CGPoint(x: 0, y: geometry.size.height / 2)); p.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }.stroke(.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    HStack { Text("DARK"); Spacer(); Text("BRIGHT") }.font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary).padding(9).offset(y: 12)
                    Circle().fill(Color.clickyAmber).frame(width: 17, height: 17).overlay(Circle().stroke(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
                        .position(x: max(9, min(geometry.size.width - 9, (Double(tone) + 1) / 2 * geometry.size.width)),
                                  y: max(9, min(geometry.size.height - 9, (1 - Double(pitch)) / 2 * geometry.size.height)))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    tone = Float(max(-1, min(1, value.location.x / geometry.size.width * 2 - 1)))
                    pitch = Float(max(-1, min(1, 1 - value.location.y / geometry.size.height * 2)))
                }.onEnded { _ in onEnd() })
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tone and pitch")
                .accessibilityValue("Tone \(Int(tone * 100)), pitch \(Int(pitch * 6)) semitones")
                .accessibilityRepresentation {
                    VStack {
                        Slider(value: $tone, in: -1...1) { Text("Tone") }
                        Slider(value: $pitch, in: -1...1) { Text("Pitch") }
                    }
                }
            }.frame(height: 165)
            Text("LOWER").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundStyle(.tertiary)
            HStack {
                Text(String(format: "Tone %+.0f", tone * 100))
                Spacer()
                Text(String(format: "Pitch %+.1f st", pitch * 6))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

func sectionHeading(_ title: String, trailing: String? = nil) -> some View {
    HStack {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
        Spacer()
        if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary) }
    }
}

func settingToggle(_ title: String, detail: String, value: Binding<Bool>) -> some View {
    HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 5)
        Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

func sliderRow(_ title: String, symbol: String? = nil, value: Binding<Float>, range: ClosedRange<Float>, suffix: String, displayMultiplier: Float = 1) -> some View {
    VStack(spacing: 9) {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(title).fontWeight(.medium)
            Spacer()
            Text(String(format: suffix == "%" ? "%.0f%%" : "%.1f%@", suffix == "%" ? value.wrappedValue * 100 : value.wrappedValue * displayMultiplier, suffix))
                .monospacedDigit().foregroundStyle(.secondary)
        }.font(.system(size: 12))
        Slider(value: value, in: range).controlSize(.small)
    }
}

private func doubleSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, multiplier: Double = 1) -> some View {
    VStack(spacing: 7) {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer()
            Text(String(format: format, value.wrappedValue * multiplier)).monospacedDigit().foregroundStyle(.secondary)
        }.font(.system(size: 12))
        Slider(value: value, in: range).controlSize(.small)
    }
}
