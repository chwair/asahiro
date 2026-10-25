import AppKit
import SwiftUI

func chooseFolder(startingAt path: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: path)
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url?.path : nil
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case game = "Game"
    case compatibility = "Compatibility"
    case graphics = "Graphics"
    case mods = "Mods"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .game: "gamecontroller.fill"
        case .compatibility: "wineglass.fill"
        case .graphics: "sparkles.tv.fill"
        case .mods: "puzzlepiece.extension.fill"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .game: .orange
        case .compatibility: .purple
        case .graphics: .blue
        case .mods: .pink
        case .advanced: .gray
        case .about: .teal
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: LauncherModel
    let close: () -> Void
    @State private var section: SettingsSection = .game
    @State private var draft: AppConfig?
    @State private var confirmDelete = false
    @State private var shortcutStatus = GameShortcut.status
    @State private var confirmReplaceShortcut = false
    @Namespace private var sidebar

    var body: some View {
        HStack(spacing: 0) {
            sidebarList
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section.rawValue).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button(action: done) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .glassEffect(.regular.interactive(), in: Circle())
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, 20)
                .padding(.bottom, Space.l)

                ScrollView {
                    if let binding = Binding($draft) {
                        VStack(alignment: .leading, spacing: 22) { page(binding) }
                            .padding(.horizontal, Space.xl)
                            .padding(.bottom, Space.xl)
                    }
                }
                .scrollIndicators(.automatic)
                .id(section)
            }
        }
        .frame(width: 800, height: 540)
        .onAppear { draft = model.config }
        // settings apply as you change them, debounced so typing does not hammer the disk
        .task(id: draft) {
            guard let draft, draft != model.config else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { model.saveConfig(draft) }
        }
        .confirmationDialog("Replace the existing Zenless Zone Zero app?", isPresented: $confirmReplaceShortcut) {
            Button("Move It to Trash and Replace", role: .destructive) {
                GameShortcut.replace(iconSource: model.art?.local.shortcutIcon) { error in
                    if let error { model.alert = error.localizedDescription }
                    shortcutStatus = GameShortcut.status
                }
            }
        } message: {
            Text("The current one is \(shortcutForeignKind). It goes to the Trash, so you can put it back from Finder.")
        }
        .confirmationDialog("Delete the bottle \"\(draft?.bottle.name ?? "")\"?", isPresented: $confirmDelete) {
            Button("Delete Bottle", role: .destructive) { model.deleteBottle() }
        } message: {
            Text("This removes the Windows environment and its settings. Game files are kept, and a fresh bottle is created on the next launch.")
        }
    }

    private var shortcutForeignKind: String {
        if case .foreign(let kind) = shortcutStatus { return kind }
        return "another app"
    }

    private var shortcutSubtitle: String {
        switch shortcutStatus {
        case .ours: "Starts the game directly. Asahiro only opens when there's an update."
        case .foreign: "Applications already has a Zenless Zone Zero app (\(shortcutForeignKind)). Replace it to use Asahiro's."
        case .missing: "Adds an app with the game's icon that starts it without opening the launcher."
        }
    }

    private func done() {
        if let draft, draft != model.config { model.saveConfig(draft) }
        close()
    }

    private var sidebarList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { s in
                let on = section == s
                Button {
                    withAnimation(Motion.snap) { section = s }
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(s.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(s.rawValue)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.zzzInk : Color.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 30)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Color.zzzYellow)
                                .matchedGeometryEffect(id: "selection", in: sidebar)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.top, 56)
        .frame(width: 196)
    }

    @ViewBuilder
    private func page(_ c: Binding<AppConfig>) -> some View {
        switch section {
        case .game: gamePage(c)
        case .compatibility: compatibilityPage(c)
        case .graphics: graphicsPage(c)
        case .mods: modsPage(c)
        case .advanced: advancedPage(c)
        case .about: aboutPage()
        }
    }

    @ViewBuilder
    private func gamePage(_ c: Binding<AppConfig>) -> some View {
        SettingsGroup(header: "Installation") {
            SettingsPath(title: "Game folder", path: c.wrappedValue.gameDir,
                         onChange: { if let p = chooseFolder(startingAt: c.wrappedValue.gameDir) { c.wrappedValue.gameDir = p } },
                         onReveal: { model.reveal(c.wrappedValue.gameDir) })
            SettingsValue(title: "Installed version", value: model.state?.version ?? "Not installed")
            SettingsValue(title: "Latest version", value: model.state?.latest ?? "—")
            SettingsButton(title: "Verify game files", subtitle: "Checks every file against the official manifest and repairs broken ones.",
                           label: "Verify") {
                done()
                model.start(.verify)
            }
            .disabled(model.activity != nil || model.state?.installed != true)
        }
        SettingsGroup(header: "Voice packs", footer: "Downloaded with new installs. Installed packs are updated along with the game.") {
            ForEach(VoicePack.allCases) { pack in
                SettingsToggle(title: pack.label, subtitle: model.state?.voicePacks.contains(pack.rawValue) == true ? "Installed" : nil,
                               isOn: Binding(
                                   get: { c.wrappedValue.voicePacks.contains(pack.rawValue) },
                                   set: { on in
                                       var packs = c.wrappedValue.voicePacks.filter { $0 != pack.rawValue }
                                       if on { packs.append(pack.rawValue) }
                                       c.wrappedValue.voicePacks = packs
                                   }
                               ))
            }
        }
        SettingsGroup(header: "Display") {
            SettingsToggle(title: "Custom resolution", isOn: c.customResolution)
            if c.wrappedValue.customResolution {
                SettingsRow(title: "Size") {
                    HStack(spacing: Space.xs) {
                        TextField("", value: c.resolutionWidth, format: .number.grouping(.never)).frame(width: 60)
                        Text("×").foregroundStyle(.secondary)
                        TextField("", value: c.resolutionHeight, format: .number.grouping(.never)).frame(width: 60)
                    }
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
                SettingsToggle(title: "Fullscreen", isOn: c.fullscreen)
            }
        }
        SettingsGroup(header: "Launcher", footer: "The game app lives in your Applications folder, so it shows up in Launchpad and Spotlight and can stay in the Dock.") {
            SettingsToggle(title: "Hide launcher while playing", isOn: c.hideLauncherWhilePlaying)
            SettingsRow(title: "Zenless Zone Zero app", subtitle: shortcutSubtitle) {
                HStack(spacing: Space.xs) {
                    switch shortcutStatus {
                    case .ours:
                        Button("Show in Finder") { model.reveal(GameShortcut.url.path) }
                        Button("Remove") {
                            GameShortcut.remove { shortcutStatus = GameShortcut.status }
                        }
                    case .foreign:
                        Button("Show in Finder") { model.reveal(GameShortcut.url.path) }
                        Button("Replace…") { confirmReplaceShortcut = true }
                    case .missing:
                        Button("Create") {
                            do {
                                try GameShortcut.create(iconSource: model.art?.local.shortcutIcon)
                            } catch {
                                model.alert = error.localizedDescription
                            }
                            shortcutStatus = GameShortcut.status
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func compatibilityPage(_ c: Binding<AppConfig>) -> some View {
        let crossover = model.wine?.crossoverFound == true
        SettingsGroup(header: "Wine runner") {
            SettingsChoice(title: "CrossOver 11.0-1",
                           subtitle: "Open-source CrossOver wine build with DXMT, and D3DMetal when CrossOver is installed. Gets the game past the anti-cheat.",
                           badge: "Recommended", value: "bundled", selection: c.runner)
            SettingsChoice(title: "CrossOver app" + (model.wine?.crossoverVersion.map { " \($0)" } ?? ""),
                           subtitle: crossover ? "The wine inside your CrossOver install. The game currently crashes on it."
                                               : "CrossOver is not installed.",
                           value: "crossover", selection: c.runner, disabled: !crossover)
        }
        SettingsGroup(header: "Bottle", footer: "Changes apply the next time the game starts.") {
            SettingsField(title: "Name", subtitle: "Pointing at a different name uses or creates that bottle.",
                          text: c.bottle.name, width: 180)
            SettingsMenu(title: "Windows version", selection: c.bottle.windowsVersion,
                         options: [("win10", "Windows 10"), ("win11", "Windows 11")])
            SettingsToggle(title: "MSync", subtitle: "Faster thread synchronisation. Recommended.", isOn: c.bottle.msync)
            SettingsToggle(title: "Retina mode", subtitle: "Renders at native resolution. Sharper but slower.", isOn: c.bottle.retina)
            SettingsToggle(title: "Left ⌘ acts as Control", isOn: c.bottle.leftCmdIsCtrl)
            SettingsToggle(title: "Left ⌥ acts as Alt", subtitle: "Needed for Alt hotkeys in the game and in mods.",
                           isOn: c.bottle.leftOptionIsAlt)
            SettingsToggle(title: "Right ⌥ acts as Alt", isOn: c.bottle.rightOptionIsAlt)
        }
        SettingsGroup(header: "Workarounds") {
            SettingsToggle(title: "Steam compatibility shim",
                           subtitle: "Starts the game through Proton's steam.exe so the anti-cheat skips its kernel driver. Required.",
                           isOn: c.steamPatch)
            SettingsToggle(title: "Launch fix",
                           subtitle: "Blocks one HoYoverse host for 25 seconds while starting. Asks for your password.",
                           isOn: c.launchFix)
        }
        SettingsGroup(header: "Maintenance") {
            SettingsRow(title: "Windows tools") {
                HStack(spacing: Space.xs) {
                    Button("Wine Config") { model.openTool("winecfg") }
                    Button("Registry") { model.openTool("regedit") }
                    Button("Task Manager") { model.openTool("taskmgr") }
                }
                .controlSize(.small)
                .disabled(model.wine?.bottleExists != true)
            }
            if let path = model.wine?.bottlePath {
                SettingsPath(title: "Bottle folder", path: path, onReveal: { model.reveal(path) })
                    .disabled(model.wine?.bottleExists != true)
            }
            SettingsButton(title: "Repair bottle", subtitle: "Creates the bottle if missing and re-applies every setting.", label: "Repair") {
                if let draft, draft != model.config { model.saveConfig(draft) }
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.start(.createBottle) }
            }
            .disabled(model.activity != nil)
            SettingsButton(title: "Delete bottle", label: "Delete…", role: .destructive) { confirmDelete = true }
                .disabled(model.wine?.bottleExists != true || model.gameRunning)
        }
    }

    @ViewBuilder
    private func graphicsPage(_ c: Binding<AppConfig>) -> some View {
        let bundled = c.wrappedValue.runner == "bundled"
        let crossover = model.wine?.crossoverFound == true
        SettingsGroup(header: "Translation layer",
                      footer: !crossover ? "D3DMetal and DXVK need CrossOver installed."
                                         : bundled ? "DXVK needs the CrossOver app runner." : nil) {
            ForEach(GraphicsBackend.allCases) { backend in
                SettingsChoice(title: backend.label, subtitle: backend.blurb,
                               badge: backend == (crossover ? GraphicsBackend.d3dmetal : GraphicsBackend.dxmt) ? "Recommended" : nil,
                               value: backend.rawValue, selection: c.bottle.graphicsBackend,
                               disabled: (bundled && backend.needsCrossOverRunner) || (!crossover && backend.needsCrossOverInstall))
            }
        }
        let d3dmetal = c.wrappedValue.bottle.graphicsBackend == GraphicsBackend.d3dmetal.rawValue
        SettingsGroup(header: "Features") {
            SettingsToggle(title: "Metal performance HUD", isOn: c.bottle.metalHud)
            SettingsToggle(title: "MetalFX upscaling", subtitle: "D3DMetal only.", isOn: c.bottle.metalfx)
                .disabled(!d3dmetal)
            SettingsToggle(title: "DirectX 12", subtitle: "D3DMetal only. Precompiles shaders, so far less stutter.", isOn: c.useD3d12)
                .disabled(!d3dmetal)
            SettingsToggle(title: "DLSS and NVAPI extensions", isOn: c.bottle.dlss)
        }
        let paced = c.wrappedValue.bottle.graphicsBackend == GraphicsBackend.dxmt.rawValue || (d3dmetal && bundled)
        SettingsGroup(header: "Frame pacing",
                      footer: "Holds every frame on screen for the same time, which smooths out an uneven frame time graph. Keep V-Sync on in the game and set its frame rate to match or higher.") {
            SettingsMenu(title: "Frame cap", subtitle: paced ? nil : "DXMT, or D3DMetal on the bundled runner.",
                         selection: c.frameCap,
                         options: [(0, "Off"), (30, "30 fps"), (40, "40 fps"), (45, "45 fps"), (60, "60 fps"), (90, "90 fps"), (120, "120 fps")])
                .disabled(!paced)
        }
    }

    @ViewBuilder
    private func modsPage(_ c: Binding<AppConfig>) -> some View {
        let z = model.zzmi
        SettingsGroup(footer: "Mods are against HoYoverse's terms of service. Use them at your own risk.") {
            SettingsToggle(title: "Enable mods", subtitle: "Loads ZZMI into the game at launch.", isOn: c.modsEnabled)
        }
        SettingsGroup(header: "ZZMI") {
            SettingsValue(title: "ZZMI package", value: z?.zzmiVersion ?? "Not installed")
            SettingsValue(title: "XXMI libraries", value: z?.libsVersion ?? "Not installed")
            SettingsButton(title: zzmiActionTitle(z), subtitle: zzmiActionSubtitle(z), label: z?.installed == true ? (z?.updateAvailable == true ? "Update" : "Reinstall") : "Install") {
                model.start(.zzmiInstall)
            }
            .disabled(model.activity != nil || model.gameRunning)
            SettingsToggle(title: "Update automatically", subtitle: "Checks GitHub every few hours and updates before launching.",
                           isOn: c.modsAutoUpdate)
        }
        SettingsGroup(header: "Mods", footer: "Mods only show with Character Quality set to High and High-Precision Character Animation turned off in the game's graphics settings.") {
            SettingsRow(title: "Installed mods", subtitle: z.map { "\($0.modCount) in the Mods folder" }) {
                Button("Manage…") {
                    done()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.showMods = true }
                }
                .controlSize(.small)
            }
            if let path = z?.modsPath {
                SettingsPath(title: "Mods folder", path: path, onReveal: { model.reveal(path) })
            }
            SettingsToggle(title: "Shader hunting", subtitle: "For mod authors. Numpad 0 toggles it in game.", isOn: c.modsHunting)
        }
    }

    private func zzmiActionTitle(_ z: ZzmiStatus?) -> String {
        guard let z, z.installed else { return "Install ZZMI" }
        return z.updateAvailable ? "Update available" : "Up to date"
    }

    private func zzmiActionSubtitle(_ z: ZzmiStatus?) -> String {
        guard let z else { return "Downloads from the official GitHub releases and checks their signatures." }
        if !z.installed { return "Downloads from the official GitHub releases and checks their signatures." }
        if z.updateAvailable { return "ZZMI \(z.latestZzmi ?? "?") and XXMI \(z.latestLibs ?? "?") are available." }
        return "Signatures are verified on every install."
    }

    @ViewBuilder
    private func advancedPage(_ c: Binding<AppConfig>) -> some View {
        SettingsGroup(header: "Launch") {
            SettingsField(title: "Game arguments", text: c.launchArgs, prompt: "-popupwindow", monospaced: true)
            SettingsField(title: "DLL overrides", text: c.bottle.dllOverrides, prompt: "dxgi=n,b", monospaced: true)
        }
        SettingsGroup(header: "Environment variables", footer: "Exported for every launch and written to the bottle's cxbottle.conf.") {
            EnvEditor(env: c.bottle.env)
        }
        SettingsGroup(header: "CrossOver") {
            SettingsField(title: "Application", text: c.crossoverPath, width: 260)
        }
    }

    @ViewBuilder
    private func aboutPage() -> some View {
        SettingsGroup(header: "Environment") {
            statusRow("Runner", ok: model.wine?.runnerInstalled == true,
                      value: (model.wine?.runnerName ?? "—") + (model.wine?.runnerInstalled == true ? "" : ", downloads on first launch"))
            statusRow("CrossOver", ok: model.wine?.crossoverFound == true, value: model.wine?.crossoverVersion ?? "Not installed")
            statusRow("Rosetta 2", ok: model.wine?.rosetta == true, value: model.wine?.rosetta == true ? "Installed" : "Missing")
            statusRow("Bottle", ok: model.wine?.bottleExists == true,
                      value: model.wine?.bottleExists == true ? "Ready" : "Created on first launch")
        }
        SettingsGroup(header: "Asahiro", footer: "Update logic follows YAAGL. Not affiliated with HoYoverse or CodeWeavers.") {
            SettingsValue(title: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            SettingsPath(title: "Logs", path: model.logsFolder, onReveal: { model.reveal(model.logsFolder) })
        }
    }

    private func statusRow(_ title: String, ok: Bool, value: String) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: Space.s) {
                Text(value).font(.system(size: 13)).foregroundStyle(.secondary)
                StatusDot(ok: ok)
            }
        }
    }
}

private struct EnvEditor: View {
    @Binding var env: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        ForEach(env.keys.sorted(), id: \.self) { key in
            SettingsRow(title: key) {
                HStack(spacing: Space.xs) {
                    TextField("", text: Binding(get: { env[key] ?? "" }, set: { env[key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12).monospaced())
                        .frame(width: 200)
                    Button {
                        env.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .controlSize(.small)
            }
        }
        SettingsRow(title: "Add variable") {
            HStack(spacing: Space.xs) {
                TextField("", text: $newKey, prompt: Text("NAME")).frame(width: 120)
                TextField("", text: $newValue, prompt: Text("value")).frame(width: 120)
                Button("Add") {
                    let k = newKey.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    env[k] = newValue
                    newKey = ""
                    newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12).monospaced())
            .controlSize(.small)
        }
    }
}

struct InstallSheet: View {
    @EnvironmentObject var model: LauncherModel
    let close: () -> Void
    @State private var draft: AppConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(model.state?.partialDownload == true ? "Resume installation" : "Install Zenless Zone Zero")
                    .font(.system(size: 20, weight: .semibold))
                if let s = model.state {
                    Text("Version \(s.latest). Downloads resume where they left off if interrupted.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let c = Binding($draft) {
                SettingsGroup(header: "Location") {
                    SettingsPath(title: "Game folder", path: c.wrappedValue.gameDir,
                                 onChange: { if let p = chooseFolder(startingAt: c.wrappedValue.gameDir) { c.wrappedValue.gameDir = p } },
                                 onReveal: { model.reveal(c.wrappedValue.gameDir) })
                }
                SettingsGroup(header: "Voice packs") {
                    ForEach(VoicePack.allCases) { pack in
                        SettingsToggle(title: pack.label, isOn: Binding(
                            get: { c.wrappedValue.voicePacks.contains(pack.rawValue) },
                            set: { on in
                                var packs = c.wrappedValue.voicePacks.filter { $0 != pack.rawValue }
                                if on { packs.append(pack.rawValue) }
                                c.wrappedValue.voicePacks = packs
                            }
                        ))
                    }
                }
            }
            if let s = model.state {
                SettingsGroup(header: "Space", footer: "Sizes refresh after the folder or voice packs change.") {
                    SettingsValue(title: "Download", value: formatBytes(s.downloadSize))
                    SettingsValue(title: "Needed on disk", value: formatBytes(s.installSize))
                    SettingsValue(title: "Free", value: formatBytes(s.freeSpace))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Install") {
                    if let draft, draft != model.config { model.saveConfig(draft) }
                    close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.start(.install) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.zzzYellow)
                .foregroundStyle(Color.zzzInk)
            }
            .controlSize(.large)
        }
        .padding(Space.xl)
        .frame(width: 480)
        .onAppear { draft = model.config }
        .task(id: draft) {
            guard let draft, draft != model.config else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { model.saveConfig(draft) }
        }
    }
}
