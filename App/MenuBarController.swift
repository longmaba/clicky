import AppKit
import SwiftUI
import ClickyCore

private final class MenuCommand: NSObject {
    let run: () -> Void
    let preview: (() -> Void)?
    init(preview: (() -> Void)? = nil, run: @escaping () -> Void) { self.preview = preview; self.run = run }
}

@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private var item: NSStatusItem?
    private var lastPreview: NSMenuItem?
    init(model: AppModel) { self.model = model; super.init(); update() }
    func update() {
        if model.config.general.showMenuBar {
            if item == nil {
                item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
                let menu = NSMenu(); menu.delegate = self; item?.menu = menu
            }
            item?.button?.image = Self.icon(enabled:model.config.enabled)
            item?.button?.toolTip = "Clicky · \(model.config.enabled ? (model.currentProfile?.name ?? "Ready") : "Muted")"
            item?.button?.setAccessibilityLabel("Clicky keyboard sounds")
        } else if let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
    }
    func menuWillOpen(_ menu: NSMenu) {
        lastPreview = nil
        guard menu == item?.menu else { return }
        menu.removeAllItems()
        let volume = NSMenuItem()
        volume.view = NSHostingView(rootView:MenuVolumeView(model:model).frame(width:256,height:70))
        menu.addItem(volume)
        add(menu,model.config.enabled ? "Mute sounds" : "Enable sounds",symbol:model.config.enabled ? "speaker.slash" : "speaker.wave.2") { [weak model] in model?.toggleEnabled() }
        menu.addItem(.separator())
        let profiles = submenu(menu,"Switches",symbol:"keyboard")
        for group in model.profileGroups {
            header(profiles,group.title)
            for profile in group.profiles {
                // The brand header above already names the manufacturer.
                let row = add(profiles,group.isBrand ? profile.modelName : profile.name,symbol:"square.fill",
                              tint:NSColor(Color(clickyHex:profile.color)),
                              preview:{ [weak model] in model?.previewProfile(profile.id) }) { [weak model] in model?.selectProfile(profile.id) }
                row.state = profile.id == model.config.sound.profileID ? .on : .off
                row.toolTip = profile.name + " · " + profile.subtitle + (profile.releaseSamples?.isEmpty == false ? " · Press + release" : "")
            }
        }
        let favorites = submenu(menu,"Favorites",symbol:"star")
        if model.config.favorites.isEmpty { let empty = NSMenuItem(title:"Save your favorite sound",action:nil,keyEquivalent:""); empty.isEnabled = false; favorites.addItem(empty) }
        for favorite in model.config.favorites { add(favorites,favorite.name,symbol:"star.fill") { [weak model] in model?.applyFavorite(favorite) } }
        favorites.addItem(.separator())
        let save = add(favorites,"Save current sound…",symbol:"plus") { [weak self] in self?.saveFavorite() }
        save.isEnabled = model.config.favorites.count < 6
        add(menu,"Sound…",symbol:"slider.horizontal.3") { [weak self] in self?.settings("sound") }
        let mouse = submenu(menu,"Mouse clicks",symbol:"computermouse")
        for choice in [ExtraSound.none,.soft,.crisp,.hard,.razerOrochiV2,.custom] {
            let row = add(mouse,choice.title,preview: { [weak model] in model?.previewExtra(choice) }) { [weak model] in model?.config.sound.mouseSound = choice }
            row.state = model.config.sound.mouseSound == choice ? .on : .off
            if choice.mouseProfileID != nil { row.toolTip = "Recorded left and right clicks · Press + release" }
            row.isEnabled = choice != .custom || model.config.sound.customMouse != nil
        }
        let enter = submenu(menu,"Enter sound",symbol:"return")
        for choice in [ExtraSound.none,.ding,.typewriter,.custom] {
            let row = add(enter,choice.title,preview: { [weak model] in model?.previewExtra(choice,forMouse:false) }) { [weak model] in model?.config.sound.enterSound = choice }
            row.state = model.config.sound.enterSound == choice ? .on : .off
            row.isEnabled = choice != .custom || model.config.sound.customEnter != nil
        }
        menu.addItem(.separator())
        add(menu,model.config.visualizer.enabled ? "Disable visualizer" : "Enable visualizer",symbol:"sparkles") { [weak model] in model?.config.visualizer.enabled.toggle() }
        let style = submenu(menu,"Visualizer style",symbol:"rectangle.on.rectangle")
        for choice in VisualizerStyle.allCases {
            let row = add(style,choice.title,symbol:choice.symbol) { [weak model] in model?.config.visualizer.style = choice; model?.config.visualizer.enabled = true }
            row.state = model.config.visualizer.style == choice ? .on : .off
        }
        let position = submenu(menu,"Position",symbol:"viewfinder")
        for choice in VisualizerPlacement.allCases {
            let row = add(position,choice.title) { [weak model] in model?.config.visualizer.placement = choice; model?.config.visualizer.enabled = true }
            row.state = model.config.visualizer.placement == choice ? .on : .off
        }
        add(menu,model.config.visualizer.notchEnabled ? "Hide notch panel" : "Show notch panel",symbol:"rectangle.topthird.inset.filled") { [weak model] in model?.config.visualizer.notchEnabled.toggle() }
        menu.addItem(.separator())
        if !model.permissionGranted { add(menu,"Enable Input Monitoring…",symbol:"hand.raised") { [weak model] in model?.requestInputPermission() } }
        if model.secureInput { let secure = NSMenuItem(title:"Paused during secure input",action:nil,keyEquivalent:""); secure.isEnabled = false; menu.addItem(secure) }
        let settings = add(menu,"Settings…",symbol:"gearshape") { [weak model] in model?.showSettings() }; settings.keyEquivalent = ","
        let quit = add(menu,"Quit Clicky",symbol:"power") { NSApp.terminate(nil) }; quit.keyEquivalent = "q"
    }
    /// Build the real status menu and describe it, so its structure can be
    /// checked without opening a menu on screen.
    func diagnosticSnapshot() -> [[String: Any]] {
        guard let menu = item?.menu else { return [] }
        menuWillOpen(menu); defer { menuDidClose(menu) }
        return describe(menu)
    }
    private func describe(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.map { row in
            var entry: [String: Any] = ["title":row.title,"isHeader":isHeader(row),"state":row.state == .on ? "on" : "off"]
            if let child = row.submenu { entry["items"] = describe(child) }
            return entry
        }
    }
    private func isHeader(_ row: NSMenuItem) -> Bool {
        if #available(macOS 14, *) { return row.isSectionHeader }
        return row.action == nil && row.submenu == nil && row.view == nil && !row.isEnabled && row.attributedTitle != nil
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard item !== lastPreview else { return }; lastPreview = item
        (item?.representedObject as? MenuCommand)?.preview?()
    }
    func menuDidClose(_ menu: NSMenu) { lastPreview = nil }
    @discardableResult private func add(_ menu: NSMenu,_ title: String,symbol: String? = nil,tint: NSColor? = nil,preview: (() -> Void)? = nil,run: @escaping () -> Void) -> NSMenuItem {
        let row = NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"")
        row.target = self; row.representedObject = MenuCommand(preview:preview,run:run)
        if let symbol {
            let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
            row.image = tint.map { image?.withSymbolConfiguration(.init(paletteColors:[$0])) } ?? image
        }
        menu.addItem(row); return row
    }
    /// Grey group label above a run of items. Section headers are macOS 14+;
    /// earlier systems get a disabled row styled the same way.
    private func header(_ menu: NSMenu,_ title: String) {
        if #available(macOS 14, *) { menu.addItem(.sectionHeader(title:title)); return }
        let row = NSMenuItem(title:title,action:nil,keyEquivalent:"")
        row.attributedTitle = NSAttributedString(string:title,attributes:[
            .font:NSFont.systemFont(ofSize:NSFont.smallSystemFontSize,weight:.semibold),
            .foregroundColor:NSColor.secondaryLabelColor])
        row.isEnabled = false; menu.addItem(row)
    }
    private func submenu(_ menu: NSMenu,_ title: String,symbol: String) -> NSMenu {
        let row = NSMenuItem(title:title,action:nil,keyEquivalent:""); row.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
        let child = NSMenu(title:title); child.delegate = self; row.submenu = child; menu.addItem(row); return child
    }
    @objc private func invoke(_ sender: NSMenuItem) { (sender.representedObject as? MenuCommand)?.run() }
    private func settings(_ tab: String) { model.settingsTab = tab; model.showSettings() }
    private func saveFavorite() {
        let alert = NSAlert(); alert.messageText = "Save favorite"; alert.informativeText = "Keep this profile, tuning, and per-key setup."
        alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel")
        let field = NSTextField(string:model.currentProfile?.name ?? "My sound"); field.frame = NSRect(x:0,y:0,width:260,height:24)
        alert.accessoryView = field; NSApp.activate(ignoringOtherApps:true)
        if alert.runModal() == .alertFirstButtonReturn { model.saveFavorite(name:field.stringValue) }
    }
    static func icon(enabled: Bool) -> NSImage {
        let image = NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
            NSColor.labelColor.withAlphaComponent(enabled ? 1 : 0.45).setStroke()
            let outer = NSBezierPath(roundedRect:rect.insetBy(dx:1.8,dy:2.4),xRadius:3,yRadius:3); outer.lineWidth = 1.5; outer.stroke()
            let c = NSBezierPath(); c.appendArc(withCenter:NSPoint(x:9.3,y:9),radius:3.1,startAngle:45,endAngle:315,clockwise:false); c.lineWidth = 1.8; c.lineCapStyle = .round; c.stroke()
            if !enabled { let slash = NSBezierPath(); slash.move(to:NSPoint(x:3,y:2)); slash.line(to:NSPoint(x:15,y:16)); slash.lineWidth = 1.5; slash.stroke() }
            return true
        }; image.isTemplate = true; return image
    }
}

private struct MenuVolumeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing:8) {
            HStack {
                Text("Clicky").font(.system(size:13,weight:.semibold))
                Spacer()
                Text(model.currentProfile?.name ?? "Keyboard sounds").font(.system(size:11)).foregroundStyle(.secondary)
            }
            HStack(spacing:9) {
                Image(systemName:model.config.sound.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size:12)).foregroundStyle(.secondary)
                Slider(value:$model.config.sound.volume,in:0...1).tint(.orange).accessibilityLabel("Typing volume")
                Text("\(Int(model.config.sound.volume * 100))%").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).frame(width:32)
            }
        }.padding(.horizontal,16).padding(.vertical,10)
    }
}
