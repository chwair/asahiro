import AppKit
import Foundation

enum TaskKind: String {
    case install, update, predownload, verify, launch
    case createBottle = "create_bottle"
    case applyBottle = "apply_bottle"
    case zzmiInstall = "zzmi_install"
    case applyPredownload = "apply_predownload"
    case importMod = "import_mod"

    var title: String {
        switch self {
        case .install: "Installing"
        case .update: "Updating"
        case .predownload: "Pre-downloading"
        case .verify: "Verifying files"
        case .launch: "Launching"
        case .createBottle: "Creating bottle"
        case .applyBottle: "Applying bottle settings"
        case .zzmiInstall: "Installing ZZMI"
        case .applyPredownload: "Updating"
        case .importMod: "Importing mod"
        }
    }

    // only downloads are safe to stop midway, the rest would leave files half written
    var cancellable: Bool {
        switch self {
        case .install, .update, .predownload, .verify, .launch: true
        default: false
        }
    }
}

enum TaskPhase: String {
    case download, verify, install, patch, repair

    var title: String {
        switch self {
        case .download: "Downloading"
        case .verify: "Verifying"
        case .install: "Installing"
        case .patch: "Patching"
        case .repair: "Repairing"
        }
    }
}

struct Activity {
    var kind: TaskKind
    var id: UInt64
    var status: String
    var detail: String = ""
    var fraction: Double?
    var phase: TaskPhase?
    var paused = false

    // the label above the progress, the core phase is more specific than the task kind
    var title: String {
        paused ? "Paused" : (phase?.title ?? kind.title)
    }

    // pausing only makes sense while bytes are moving or being hashed
    var pausable: Bool {
        guard kind != .launch, let phase else { return false }
        return phase == .download || phase == .verify
    }
}

enum PrimaryAction: Equatable {
    case loading, unavailable, install, resume, update, launch, playing, busy
}

@MainActor
final class LauncherModel: ObservableObject {
    static let shared = LauncherModel()

    @Published var config: AppConfig?
    @Published var state: GameState?
    @Published var art: Art?
    @Published var wine: WineInfo?
    @Published var activity: Activity?
    @Published var gameRunning = false
    @Published var alert: String?
    @Published var offline: String?
    @Published var showSettings = false
    @Published var confirmInstall = false
    @Published var zzmi: ZzmiStatus?
    @Published var mods: [ModInfo] = []
    @Published var showMods = false
    @Published var modsLoading = false
    @Published var modsInjected: Bool?
    @Published var confirmApplyPredownload = false
    @Published var checking = false
    @Published var checkResult: String?

    private var lastLog: [String] = []

    // quick launch: started from the game shortcut, the launcher stays hidden unless it is needed
    @Published private(set) var quickMode = false
    weak var window: NSWindow?
    private var loaded = false
    private var quickPending = false

    func load() async {
        do {
            config = try await Core.call(["cmd": "get_config"], as: AppConfig.self, decoder: JSONDecoder())
        } catch {
            alert = error.localizedDescription
        }
        // a quick launch only waits for the state, art and mods catch up once the game is on its way
        if quickPending {
            await refresh()
            loaded = true
            await runQuickLaunch(fresh: true)
            async let artTask: Void = loadArt()
            async let modsTask: Void = loadMods()
            _ = await (artTask, modsTask)
            return
        }
        async let artTask: Void = loadArt()
        async let stateTask: Void = refresh()
        async let modsTask: Void = loadMods()
        _ = await (artTask, stateTask, modsTask)
        loaded = true
        if quickPending { await runQuickLaunch(fresh: false) }
    }

    func loadArt() async {
        do {
            art = try await Core.call(["cmd": "get_art", "language": "en-us"], as: Art.self)
            if let icon = art?.local.shortcutIcon {
                DispatchQueue.global(qos: .utility).async { GameShortcut.updateGameIcon(source: icon) }
            }
        } catch {
            offline = error.localizedDescription
        }
        // the video is cached in the background on first fetch, pick it up once it lands
        var attempts = 0
        while art?.local.video == nil, art?.video != nil, attempts < 30 {
            attempts += 1
            try? await Task.sleep(for: .seconds(8))
            if let refreshed = try? await Core.call(["cmd": "get_art", "language": "en-us"], as: Art.self),
               refreshed.local.video != nil {
                art = refreshed
            }
        }
    }

    func loadMods(refresh: Bool = false) async {
        zzmi = try? await Core.call(["cmd": "zzmi_status", "refresh": refresh], as: ZzmiStatus.self)
        if let list = try? await Core.call(["cmd": "list_mods"], as: [ModInfo].self) {
            mods = list
        }
    }

    // rescans the mods folder, a rescan already running covers the request
    func reloadMods() {
        guard !modsLoading else { return }
        modsLoading = true
        Task {
            await loadMods()
            modsLoading = false
        }
    }

    func setMods(_ ids: Set<String>, enabled: Bool) {
        guard !ids.isEmpty else { return }
        for i in mods.indices where ids.contains(mods[i].id) { mods[i].enabled = enabled }
        Task {
            do {
                try await Core.run(["cmd": "set_mods_enabled", "ids": Array(ids), "enabled": enabled])
            } catch {
                alert = error.localizedDescription
            }
            await loadMods()
        }
    }

    // moves to the trash rather than deleting, so a misclick can be undone from finder
    func trashMods(_ ids: Set<String>) {
        let urls = mods.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.alert = error.localizedDescription }
                await self?.loadMods()
            }
        }
    }

    func revealMods(_ ids: Set<String>) {
        let urls = mods.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // imports run one after another as normal tasks so progress shows in the launch bar
    func importMods(_ urls: [URL]) {
        guard let first = urls.first else { return }
        pendingImports = Array(urls.dropFirst())
        start(.importMod, extra: ["path": first.path])
    }

    private var pendingImports: [URL] = []

    func refresh(force: Bool = false) async {
        wine = try? await Core.call(["cmd": "wine_info"], as: WineInfo.self)
        gameRunning = wine?.gameRunning ?? false
        do {
            state = try await Core.call(["cmd": "get_state", "refresh": force], as: GameState.self)
            offline = nil
        } catch {
            offline = error.localizedDescription
        }
    }

    // called before the window exists when asahiro was started by the shortcut
    func beginQuickLaunch() {
        quickMode = true
        quickPending = true
    }

    // the shortcut was used while asahiro is already running
    func requestQuickLaunch() {
        if let window, window.isVisible, !quickMode {
            if primary == .launch { start(.launch) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        quickMode = true
        hideLauncher()
        startBouncing()
        quickPending = true
        if loaded { Task { await runQuickLaunch(fresh: false) } }
    }

    // a process that just started has fetched the state already, a running one may hold an old manifest
    private func runQuickLaunch(fresh: Bool) async {
        quickPending = false
        if !fresh { await refresh(force: true) }
        if gameRunning {
            stopBouncing()
            NSApp.terminate(nil)
            return
        }
        // anything other than a plain start (update, install, offline) needs the user
        if primary == .launch {
            start(.launch)
        } else {
            showLauncher()
        }
    }

    func hideLauncher() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func showLauncher() {
        stopBouncing()
        quickMode = false
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var attentionRequest: Int?
    private var bounceWatch: Task<Void, Never>?

    // the shortcut stub exits at once, so while wine boots asahiro takes its place in the dock with the
    // game's icon and bounces until the game's own icon shows up
    func startBouncing() {
        guard attentionRequest == nil else { return }
        if let icon = NSImage(contentsOf: GameShortcut.gameIconURL) { NSApp.applicationIconImage = icon }
        NSApp.setActivationPolicy(.regular)
        attentionRequest = NSApp.requestUserAttention(.criticalRequest)
        bounceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let up = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == GameShortcut.gameBundleID && $0.activationPolicy == .regular
                }
                if up { self?.stopBouncing() }
            }
        }
    }

    func stopBouncing() {
        bounceWatch?.cancel()
        bounceWatch = nil
        guard let request = attentionRequest else { return }
        attentionRequest = nil
        NSApp.cancelUserAttentionRequest(request)
        NSApp.applicationIconImage = nil
        if quickMode { NSApp.setActivationPolicy(.accessory) }
    }

    // explicit check from the version pill, keeps the spinner up for a moment so it reads as work
    func checkForUpdates() {
        guard !checking else { return }
        checking = true
        checkResult = nil
        Task {
            let started = Date()
            await refresh(force: true)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.6 { try? await Task.sleep(for: .seconds(0.6 - elapsed)) }
            checking = false
            if offline != nil {
                checkResult = "Offline"
            } else if let s = state, s.updateAvailable {
                checkResult = "Update \(s.latest)"
            } else if let pre = state?.predownload {
                checkResult = "\(pre) pre-download"
            } else {
                checkResult = "Up to date"
            }
            try? await Task.sleep(for: .seconds(4))
            checkResult = nil
        }
    }

    var primary: PrimaryAction {
        // the launch task stays open for as long as the game runs
        if gameRunning, activity == nil || activity?.kind == .launch { return .playing }
        if activity != nil { return .busy }
        guard let state else { return offline == nil ? .loading : .unavailable }
        if !state.installed { return state.partialDownload ? .resume : .install }
        if state.updateAvailable { return .update }
        return .launch
    }

    func performPrimary() {
        switch primary {
        case .install, .resume: confirmInstall = true
        case .update: start(.update)
        case .launch: start(.launch)
        case .playing: stopGame()
        case .busy: togglePause()
        default: break
        }
    }

    // the game may also have been started by an earlier asahiro, then there is no task to cancel
    func stopGame() {
        if activity?.kind == .launch {
            cancel()
            return
        }
        Task {
            try? await Core.run(["cmd": "stop_game"])
            await refresh()
        }
    }

    // the core keeps the partial file and the open task, resuming continues where it stopped
    func togglePause() {
        guard let activity, activity.pausable || activity.paused else { return }
        let paused = !activity.paused
        Core.pause(activity.id, paused)
        self.activity?.paused = paused
    }

    func saveConfig(_ new: AppConfig) {
        config = new
        Task {
            do {
                try await Core.run(["cmd": "set_config", "config": new.asJSONObject])
                await refresh()
                await loadMods()
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func start(_ kind: TaskKind, extra: [String: Any] = [:]) {
        guard activity == nil else { return }
        if kind == .launch, config?.runner == "crossover", wine?.crossoverFound == false {
            alert = "CrossOver was not found. Install CrossOver or switch to the bundled runner in Settings → Bottle."
            return
        }
        lastLog = []
        var request: [String: Any] = ["cmd": kind.rawValue]
        request.merge(extra) { _, new in new }
        let id = Core.spawn(request) { [weak self] event in
            Task { @MainActor in self?.handle(event, kind: kind) }
        }
        activity = Activity(kind: kind, id: id, status: kind.title)
    }

    func cancel() {
        guard let activity, activity.kind.cancellable else { return }
        if activity.kind == .launch {
            Task { try? await Core.run(["cmd": "stop_game"]) }
        }
        Core.cancel(activity.id)
        self.activity?.paused = false
        self.activity?.status = "Stopping…"
    }

    private func handle(_ event: TaskEvent, kind: TaskKind) {
        switch event.type {
        case "status":
            activity?.status = event.text ?? ""
        case "phase":
            activity?.phase = event.phase.flatMap(TaskPhase.init(rawValue:))
        case "progress":
            activity?.fraction = event.fraction
            activity?.detail = event.detail ?? ""
        case "log":
            if let t = event.text { lastLog.append(t) }
        case "mods_injected":
            modsInjected = event.ok == true
        case "game_started":
            gameRunning = true
            stopBouncing()
            if config?.hideLauncherWhilePlaying == true, !quickMode {
                NSApp.hide(nil)
            }
        case "finished":
            activity = nil
            if kind == .launch { stopBouncing() }
            if kind == .launch, quickMode {
                gameRunning = false
                // a quick launch leaves no trace once the game closes, a failure brings the launcher up
                if event.ok == true || event.cancelled == true {
                    NSApp.terminate(nil)
                    return
                }
                showLauncher()
            } else if kind == .launch {
                gameRunning = false
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if event.ok != true, event.cancelled != true {
                alert = event.error ?? "\(kind.title) failed"
            }
            if kind == .importMod || kind == .zzmiInstall {
                Task { await loadMods() }
                if kind == .importMod, !pendingImports.isEmpty {
                    let next = pendingImports.removeFirst()
                    DispatchQueue.main.async { self.start(.importMod, extra: ["path": next.path]) }
                }
            }
            if kind == .launch { modsInjected = nil }
            if kind == .install, event.ok == true, addShortcutAfterInstall {
                addShortcutAfterInstall = false
                createShortcut()
            }
            Task { await refresh(force: kind == .update || kind == .install || kind == .applyPredownload) }
        default:
            break
        }
    }

    // set from the install sheet, the shortcut is made once the game is actually there
    var addShortcutAfterInstall = false

    func createShortcut() {
        guard GameShortcut.status == .missing else { return }
        do {
            try GameShortcut.create(iconSource: art?.local.shortcutIcon)
        } catch {
            alert = error.localizedDescription
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTool(_ tool: String) {
        Task {
            do {
                try await Core.run(["cmd": "open_tool", "tool": tool])
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func deleteBottle() {
        Task {
            do {
                try await Core.run(["cmd": "delete_bottle"])
                await refresh()
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    var logsFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Asahiro/logs").path
    }
}
