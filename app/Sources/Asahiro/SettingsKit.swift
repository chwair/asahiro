import SwiftUI

// building blocks for settings pages, laid out like system settings: a sentence case header,
// one rounded group of rows with hairline separators, an optional footer note

struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let header {
                Text(header)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Space.xs)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(SeparatedRows()) { content }
            }
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.group, style: .continuous).strokeBorder(.white.opacity(0.06)))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
            }
        }
    }
}

// puts a hairline between consecutive rows without every row having to know its position
private struct SeparatedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Divider().opacity(0.6).padding(.leading, Space.m)
            }
        }
    }
}

// title, optional subtitle and a trailing control, the base every other row builds on
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.l)
            trailing
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, subtitle == nil ? 9 : 8)
        .frame(minHeight: 38)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(.zzzYellow)
        }
    }
}

struct SettingsValue: View {
    let title: String
    let value: String

    var body: some View {
        SettingsRow(title: title) {
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct SettingsMenu<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

struct SettingsField: View {
    let title: String
    var subtitle: String?
    @Binding var text: String
    var prompt = ""
    var width: CGFloat = 220
    var monospaced = false

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            TextField("", text: $text, prompt: Text(prompt))
                .font(monospaced ? .system(size: 12).monospaced() : .system(size: 12))
                .settingsField()
                .frame(width: width)
        }
    }
}

// the rounded border style is a bezeled appkit field that turns opaque when the page is rebuilt
// over glass, so fields draw their own translucent box instead
private struct SettingsFieldBox: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(focused ? Color.zzzYellow.opacity(0.8) : .white.opacity(0.1))
            )
            .animation(Motion.quick, value: focused)
    }
}

extension View {
    func settingsField() -> some View { modifier(SettingsFieldBox()) }
}

struct SettingsButton: View {
    let title: String
    var subtitle: String?
    let label: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Button(label, role: role, action: action)
                .controlSize(.small)
        }
    }
}

// a folder location with a reveal and a change button
struct SettingsPath: View {
    let title: String
    let path: String
    var onChange: (() -> Void)?
    let onReveal: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: (path as NSString).abbreviatingWithTildeInPath) {
            HStack(spacing: Space.xs) {
                Button("Show in Finder", action: onReveal)
                if let onChange {
                    Button("Change…", action: onChange)
                }
            }
            .controlSize(.small)
        }
    }
}

// single choice out of a few options with an explanation each, like the radio lists in system settings
struct SettingsChoice<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    var badge: String?
    let value: Value
    @Binding var selection: Value
    var disabled = false

    var body: some View {
        let on = selection == value
        Button {
            withAnimation(Motion.quick) { selection = value }
        } label: {
            SettingsRow(title: title, subtitle: subtitle) {
                HStack(spacing: Space.s) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.zzzInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.zzzYellow, in: Capsule())
                    }
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(on ? Color.zzzYellow : Color.secondary.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
    }
}
