import SwiftUI
import ClickyCore

extension VisualizerTheme {
    var keyColor: Color {
        switch self { case .graphite, .glassDark: return Color(white: 0.21); case .porcelain, .glassClear: return Color(white: 0.94); case .amber: return Color(red: 0.29, green: 0.19, blue: 0.1) }
    }
    var keyText: Color {
        switch self { case .porcelain, .glassClear: return Color(white: 0.28); default: return Color(white: 0.86) }
    }
    var baseColor: Color {
        switch self { case .graphite: return Color(white: 0.105); case .glassDark: return Color.black.opacity(0.56); case .porcelain: return Color(white: 0.84); case .glassClear: return Color.white.opacity(0.55); case .amber: return Color(red: 0.15, green: 0.09, blue: 0.04) }
    }
    var glowColor: Color {
        switch self { case .graphite: return Color(white: 0.65); case .porcelain: return .white; case .amber: return .clickyAmber; case .glassDark: return .indigo; case .glassClear: return .cyan }
    }
}

struct KeyboardView: View {
    var pressedKeys: Set<String>
    var selectedKey: String? = nil
    var customizedKeys: Set<String> = []
    var theme: VisualizerTheme = .graphite
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let padding = geometry.size.width * 0.018
            let unit = (geometry.size.width - padding * 2) / KeyboardLayout.totalWidth
            let row = (geometry.size.height - padding * 2) / Double(KeyboardLayout.rows)
            let gap = max(2, unit * 0.09)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: max(8, geometry.size.width * 0.025)).fill(theme.baseColor)
                    .overlay(RoundedRectangle(cornerRadius: max(8, geometry.size.width * 0.025)).stroke(.white.opacity(0.16), lineWidth: 1))
                ForEach(KeyboardLayout.keys) { key in
                    let down = pressedKeys.contains(key.id)
                    let selected = key.id == selectedKey
                    keyCap(key, down: down, selected: selected, fontSize: max(7, min(12, unit * 0.27)))
                        .frame(width: key.width * unit - gap, height: row - gap)
                        .offset(x: padding + key.x * unit + gap / 2, y: padding + key.y * row + gap / 2 + (down ? 1 : 0))
                        .onTapGesture { onSelect?(key.id) }
                        .accessibilityLabel(key.label + (selected ? ", selected" : "") + (customizedKeys.contains(key.id) ? ", customized" : ""))
                }
            }
        }
    }

    private func keyCap(_ key: KeyDescriptor, down: Bool, selected: Bool, fontSize: Double) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(down || selected ? Color.clickyAmber : theme.keyColor)
                .shadow(color: .black.opacity(down ? 0.08 : 0.32), radius: 0.5, y: down ? 0 : 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(down || selected ? Color.white.opacity(0.55) : .white.opacity(0.09)))
            Text(key.label)
                .font(.system(size: fontSize, weight: down || selected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(down || selected ? .white : theme.keyText)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if customizedKeys.contains(key.id) {
                Circle().fill(down || selected ? Color.white : .clickyAmber).frame(width: 3, height: 3).padding(4)
            }
        }.contentShape(RoundedRectangle(cornerRadius: 4))
    }
}
