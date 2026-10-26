import AppKit
import SwiftUI

struct LauncherView: View {
    @EnvironmentObject var model: LauncherModel
    @State private var menuOpen = false

    var body: some View {
        ZStack(alignment: .bottom) {
            BackgroundStack(art: model.art, paused: model.gameRunning)
            Scrims()
            Logos()

            if menuOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Motion.snap) { menuOpen = false } }
            }

            HStack(alignment: .bottom, spacing: Space.l) {
                LeftCorner()
                Spacer(minLength: 0)
                LaunchBar(menuOpen: $menuOpen)
            }
            .padding(.horizontal, Space.edge)
            .padding(.bottom, Space.edge)

            if let offline = model.offline, model.state == nil {
                OfflineBanner(message: offline)
            }

            if model.showSettings {
                GlassOverlay(onDismiss: { model.showSettings = false }) {
                    SettingsView(close: { model.showSettings = false })
                }
                .zIndex(10)
            }
            if model.showMods {
                GlassOverlay(onDismiss: { model.showMods = false }) {
                    ModsView(close: { model.showMods = false })
                }
                .zIndex(10)
            }
            if model.confirmInstall {
                GlassOverlay(onDismiss: { model.confirmInstall = false }) {
                    InstallSheet(close: { model.confirmInstall = false })
                }
                .zIndex(10)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onChange(of: model.showSettings) { _, open in if open { menuOpen = false } }
        .onChange(of: model.showMods) { _, open in if open { menuOpen = false } }
        .alert("Apply \(model.state?.predownload ?? "") now?", isPresented: $model.confirmApplyPredownload) {
            Button("Apply Update") { model.start(.applyPredownload) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This patches the game with the files you pre-downloaded. Do it once the new version is live, otherwise the game won't connect until release.")
        }
        .alert("Asahiro", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

// a left panel in the same colour the official art uses, plus a floor for the bottom controls
private struct Scrims: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .zzzPanel.opacity(0.94), location: 0),
                    .init(color: .zzzPanel.opacity(0.7), location: 0.22),
                    .init(color: .zzzPanel.opacity(0), location: 0.5),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .init(x: 0.5, y: 0.62), endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// game logo pinned top left, the update artwork large in the left third
private struct Logos: View {
    @EnvironmentObject var model: LauncherModel
    @State private var parts: ThemeParts?
    @State private var partsFor: String?

    var body: some View {
        GeometryReader { geo in
            let markHeight = min(max(geo.size.height * 0.075, 40), 64)
            let updateWidth = min(max(geo.size.width * 0.42, 420), 720)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let logo = parts?.gameLogo {
                        Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        FileImage(path: model.art?.local.logo).aspectRatio(contentMode: .fit)
                    }
                }
                .frame(height: markHeight, alignment: .leading)
                .padding(.top, 52)

                Spacer(minLength: Space.xl)

                if let update = parts?.updateBlock {
                    Image(nsImage: update)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: updateWidth, alignment: .leading)
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                }

                Spacer(minLength: Space.xl)
                Spacer(minLength: 150)
            }
            .padding(.leading, Space.edge)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: model.art?.local.theme) {
            guard let theme = model.art?.local.theme, theme != partsFor else { return }
            let loaded = await Task.detached(priority: .userInitiated) { ThemeParts.load(themePath: theme) }.value
            withAnimation(Motion.quick) {
                parts = loaded
                partsFor = theme
            }
        }
    }
}

private struct OfflineBanner: View {
    let message: String
    var body: some View {
        VStack {
            Label("Can't reach the update server: \(message)", systemImage: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, Space.m)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 16)
            Spacer()
        }
    }
}

private struct LeftCorner: View {
    @EnvironmentObject var model: LauncherModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let icon = model.art?.local.icon {
                Button {
                    if let link = model.art?.iconLink, let url = URL(string: link) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    FileImage(path: hovering ? (model.art?.local.iconHover ?? icon) : icon)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 34)
                }
                .buttonStyle(PressStyle())
                .onHover { hovering = $0 }
                .help("Open the version notes")
            }
            VersionPill()
        }
    }
}

// installed version plus an explicit update check, replaces the old toolbar button
private struct VersionPill: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        HStack(spacing: 0) {
            Text(versionText)
                .font(.display(13, italic: false))
                .kerning(0.4)
                .padding(.leading, Space.m)
                .padding(.trailing, Space.s)

            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 16)

            Button(action: model.checkForUpdates) {
                HStack(spacing: 6) {
                    // separate views so the spin ends with the check instead of finishing its turn on the result mark
                    Group {
                        if model.checking {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                .symbolEffect(.rotate.byLayer, options: .repeat(.continuous).speed(2.5))
                        } else {
                            Image(systemName: symbol)
                        }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .frame(width: 14)
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .contentTransition(.interpolate)
                        .id(label)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                }
                .foregroundStyle(model.checkResult == nil ? Color.primary.opacity(0.85) : Color.zzzYellow)
                .padding(.leading, Space.s)
                .padding(.trailing, Space.m)
                .frame(height: 30)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .disabled(model.checking)
        }
        .frame(height: 30)
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(Motion.snap, value: model.checking)
        .animation(Motion.snap, value: model.checkResult)
    }

    private var label: String {
        model.checking ? "Checking" : (model.checkResult ?? "Check for updates")
    }

    // the arrow spins while checking, then turns into a mark that says how it went
    private var symbol: String {
        guard model.checkResult != nil else { return "arrow.trianglehead.2.clockwise" }
        if model.offline != nil { return "wifi.slash" }
        if model.state?.updateAvailable == true { return "arrow.down.circle.fill" }
        if model.state?.predownload != nil { return "arrow.down.circle" }
        return "checkmark.circle.fill"
    }

    private var versionText: String {
        guard let s = model.state else { return "—" }
        return s.version.map { "v\($0)" } ?? "Not installed"
    }
}

// one connected bar: status panel, the big action, and the gear that morphs into the menu
private struct LaunchBar: View {
    @EnvironmentObject var model: LauncherModel
    @Binding var menuOpen: Bool
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: Space.s) {
            VStack(alignment: .trailing, spacing: Space.s) {
                if menuOpen {
                    GlassMenuList(items: menuItems) { withAnimation(Motion.snap) { menuOpen = false } }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .glassEffectID("menu", in: glass)
                }
                HStack(spacing: Space.s) {
                    HStack(spacing: 0) {
                        StatusPanel()
                        PrimaryButton()
                    }
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)

                    Button {
                        withAnimation(Motion.snap) { menuOpen.toggle() }
                    } label: {
                        Image(systemName: menuOpen ? "xmark" : "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .frame(width: 60, height: 60)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .glassEffect(.regular.interactive(), in: ChamferShape(cut: 10))
                    .glassEffectID("gear", in: glass)
                    .help("Settings and tools")
                }
            }
        }
        .animation(Motion.snap, value: model.activity?.id)
    }

    private var menuItems: [GlassMenuItem] {
        let busy = model.activity != nil || model.gameRunning
        return [
            GlassMenuItem(title: "Settings", symbol: "gearshape", shortcut: "⌘,") { model.showSettings = true },
            GlassMenuItem(title: "Mods", symbol: "puzzlepiece.extension", shortcut: "⇧⌘M", dividerAfter: true) { model.showMods = true },
            GlassMenuItem(title: "Apply \(model.state?.predownload ?? "") now", symbol: "arrow.up.circle",
                          enabled: !busy && model.state?.predownloadReady == true) { model.confirmApplyPredownload = true },
            GlassMenuItem(title: "Verify game files", symbol: "checkmark.shield",
                          enabled: !busy && model.state?.installed == true) { model.start(.verify) },
            GlassMenuItem(title: "Open logs", symbol: "doc.text.magnifyingglass") { model.reveal(model.logsFolder) },
        ]
    }
}

// left half of the launch bar, says what the button will do or what is happening right now
private struct StatusPanel: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // two lines only: a label row with a quiet value on the right, then one main line
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: Space.s) {
                        Text(content.label)
                            .font(.display(11, italic: false))
                            .kerning(1.2)
                            .foregroundStyle(Color.zzzYellow)
                        Spacer(minLength: 0)
                        if let meta = content.meta {
                            Text(meta)
                                .font(.display(11, italic: false))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(content.title)
                        .font(.displayMedium(15).monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                accessory
            }
            .padding(.leading, Space.l + 4)
            .padding(.trailing, Space.m)
            .frame(maxHeight: .infinity)
            .help(model.activity?.status ?? "")

            if let activity = model.activity, activity.kind != .launch || !model.gameRunning {
                StripeProgress(fraction: activity.fraction)
                    .frame(height: 3)
                    .transition(.opacity)
            }
        }
        .frame(width: 300, height: 60)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: ChamferShape(cut: 12, leading: true, trailing: false))
        // progress numbers tick several times a second, only the label change gets a transition
        .animation(Motion.quick, value: content.label)
    }

    @ViewBuilder
    private var accessory: some View {
        if let activity = model.activity, activity.kind.cancellable, !(activity.kind == .launch && model.gameRunning) {
            MiniButton(symbol: "xmark", help: activity.kind == .launch ? "Stop the game" : "Stop, downloads resume later") {
                model.cancel()
            }
        } else if let pre = model.state?.predownload, model.activity == nil, !model.gameRunning {
            if model.state?.predownloadReady == true {
                MiniButton(symbol: "arrow.up", help: "Apply \(pre) now") { model.confirmApplyPredownload = true }
            } else {
                MiniButton(symbol: "arrow.down", help: "Pre-download \(pre)") { model.start(.predownload) }
            }
        }
    }

    private var content: (label: String, meta: String?, title: String) {
        if let a = model.activity {
            if a.kind == .launch && model.gameRunning {
                return ("IN GAME", modsMeta, "Zenless Zone Zero")
            }
            // the percentage already sits on the big button
            return (a.title.uppercased(), nil, progressLine(a))
        }
        if model.gameRunning { return ("IN GAME", modsMeta, "Zenless Zone Zero") }
        guard let s = model.state else {
            return (model.offline == nil ? "CONNECTING" : "OFFLINE", nil, "Zenless Zone Zero")
        }
        if !s.installed {
            return (s.partialDownload ? "PAUSED" : "NOT INSTALLED", formatBytes(s.downloadSize), "Version \(s.latest)")
        }
        if s.updateAvailable {
            return ("UPDATE READY", nil, "\(s.version ?? "?") → \(s.latest)")
        }
        if model.config?.modsEnabled == true {
            return ("READY", "MODS ON", "Version \(s.version ?? s.latest)")
        }
        if let pre = s.predownload {
            return ("READY", s.predownloadReady ? "\(pre) PRE-DOWNLOADED" : "\(pre) AVAILABLE", "Version \(s.version ?? s.latest)")
        }
        return ("READY", nil, "Version \(s.version ?? s.latest)")
    }

    private var modsMeta: String? {
        switch model.modsInjected {
        case true?: "MODS LOADED"
        case false?: "MODS FAILED"
        case nil: nil
        }
    }

    // core details read "Verifying  3.0 GB / 75.8 GB", the label already says what is happening so keep the numbers
    private func progressLine(_ a: Activity) -> String {
        if let range = a.detail.range(of: "  ") {
            let numbers = a.detail[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !numbers.isEmpty { return numbers }
        }
        return a.status
    }
}

private struct MiniButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }
}

// yellow fill with slowly moving hazard stripes, the whole track pulses when indeterminate
private struct StripeProgress: View {
    let fraction: Double?
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = fraction.map { max(4, geo.size.width * $0) } ?? geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.08))
                ZStack {
                    Rectangle().fill(Color.zzzYellow)
                    Stripes(spacing: 8, phase: phase).fill(Color.zzzInk.opacity(0.28))
                }
                .frame(width: width)
                .opacity(fraction == nil ? 0.6 : 1)
                .animation(.linear(duration: 0.18), value: fraction)
            }
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { phase = 8 }
        }
    }
}

private struct PrimaryButton: View {
    @EnvironmentObject var model: LauncherModel
    @State private var hovering = false

    var body: some View {
        let c = content
        Button(action: model.performPrimary) {
            HStack(spacing: Space.s) {
                if let symbol = c.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .black))
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    ProgressView().controlSize(.small).tint(.zzzInk)
                }
                Text(c.title)
                    .font(.display(21))
                    .kerning(0.6)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent ?? 0)))
                    .animation(Motion.snap, value: percent)
            }
            .foregroundStyle(Color.zzzInk)
            .frame(width: 220, height: 60)
            .background {
                ZStack {
                    Color.zzzYellow
                    // a faint stripe band on the right edge, like the in-game buttons
                    HStack {
                        Spacer()
                        Stripes(spacing: 7).fill(Color.zzzInk.opacity(0.08)).frame(width: 46)
                    }
                    LinearGradient(colors: [.white.opacity(hovering && c.enabled ? 0.22 : 0.12), .clear],
                                   startPoint: .top, endPoint: .center)
                }
                .clipShape(ChamferShape(cut: 12, leading: false, trailing: true))
                .opacity(c.enabled ? 1 : 0.7)
            }
            .contentShape(ChamferShape(cut: 12, leading: false, trailing: true))
        }
        .buttonStyle(PressStyle())
        .disabled(!c.enabled)
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        // return should never be the thing that kills a running game
        .keyboardShortcut(model.primary == .playing ? nil : .defaultAction)
        .animation(Motion.quick, value: model.primary)
        .animation(Motion.quick, value: model.activity?.paused)
        .help(pauseHelp)
    }

    private var percent: Int? {
        guard let a = model.activity, a.kind != .launch, let f = a.fraction else { return nil }
        return Int((f * 100).rounded())
    }

    private var pauseHelp: String {
        if model.primary == .playing { return "Stop the game" }
        guard let a = model.activity else { return "" }
        if a.paused { return "Resume" }
        return a.pausable ? "Pause" : ""
    }

    private var content: (title: String, symbol: String?, enabled: Bool) {
        switch model.primary {
        case .loading: ("LOADING", nil, false)
        case .unavailable: ("OFFLINE", "wifi.slash", false)
        case .install: ("INSTALL", "arrow.down.to.line", true)
        case .resume: ("RESUME", "arrow.clockwise", true)
        case .update: ("UPDATE", "arrow.triangle.2.circlepath", true)
        case .launch: ("START", "play.fill", true)
        case .playing: hovering ? ("STOP", "stop.fill", true) : ("PLAYING", "gamecontroller.fill", true)
        case .busy:
            if let a = model.activity, let percent {
                if a.paused {
                    ("\(percent)%", "play.fill", true)
                } else {
                    ("\(percent)%", a.pausable ? "pause.fill" : "hourglass", a.pausable)
                }
            } else {
                (model.activity?.kind == .launch ? "STARTING" : "WORKING", nil, false)
            }
        }
    }
}
