import SwiftUI

// floating glass sheet shown inside the launcher window instead of a system sheet
struct GlassOverlay<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(shown ? 0.32 : 0))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                .scaleEffect(shown ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(Motion.snap) { shown = true } }
        .onExitCommand(perform: dismiss)
    }

    private func dismiss() {
        withAnimation(Motion.quick) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onDismiss)
    }
}

// the dismiss button panels inside the launcher put in their top right corner, esc does the same
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

struct GlassMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var shortcut: String?
    var enabled = true
    var dividerAfter = false
    let action: () -> Void
}

// menu content that morphs out of the button that opened it
struct GlassMenuList: View {
    let items: [GlassMenuItem]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                GlassMenuRow(item: item) {
                    dismiss()
                    item.action()
                }
                if item.dividerAfter {
                    Divider().opacity(0.5).padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                }
            }
        }
        .padding(5)
        .frame(width: 220)
    }
}

private struct GlassMenuRow: View {
    let item: GlassMenuItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                Text(item.title).font(.system(size: 13))
                Spacer()
                if let shortcut = item.shortcut {
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(hovering && item.enabled ? Color.zzzInk : Color.primary)
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.zzzYellow.opacity(hovering && item.enabled ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .opacity(item.enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}
