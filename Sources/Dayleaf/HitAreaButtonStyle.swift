import SwiftUI

struct ItemActionButton: View {
    let symbol: String
    let title: String
    var destructive = false
    var compact = false
    var showsTitle = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).frame(width: 18, height: 18)
                if showsTitle { Text(title) }
            }.font(.system(size: UIScale.pt(11)))
        }
        .buttonStyle(HitAreaButtonStyle(compact: compact))
        .foregroundStyle(destructive ? Palette.deadline : Palette.muted)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct HitAreaButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, compact: compact)
    }

    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, compact ? 3 : 6)
                .padding(.vertical, compact ? 2 : 4)
                .frame(minWidth: compact ? 22 : 30, minHeight: compact ? 22 : 30)
                .background((hovered || configuration.isPressed) && enabled ? Palette.soft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}
