import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // the game shortcut starts asahiro with this flag so the window never shows up
        if CommandLine.arguments.contains("--quick-launch") {
            LauncherModel.shared.beginQuickLaunch()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { GameShortcut.migrateIfNeeded() }
        if LauncherModel.shared.quickMode {
            LauncherModel.shared.startBouncing()
            return
        }
        // swiftpm executables start as background processes unless told otherwise
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Updater.shared.checkOnLaunch()
    }

    // a staged update replaces the bundle once this process is gone
    func applicationWillTerminate(_ notification: Notification) {
        Updater.shared.installStaged(relaunch: false)
    }

    // asahiro://launch, sent by the game shortcut when asahiro is already running
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == "asahiro" else { return }
        if url.host == "launch" {
            LauncherModel.shared.requestQuickLaunch()
        }
    }

    // clicking the bouncing icon during a quick launch brings the launcher up instead of a new window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard LauncherModel.shared.quickMode else { return true }
        LauncherModel.shared.showLauncher()
        return false
    }

    // a quick launch runs with its window hidden on purpose, quitting is handled when the game exits
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !LauncherModel.shared.quickMode
    }
}

@main
struct AsahiroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = LauncherModel.shared

    var body: some Scene {
        WindowGroup("Asahiro") {
            LauncherView()
                .environmentObject(model)
                .background(WindowReader { window in
                    model.window = window
                    if model.quickMode { window.orderOut(nil) }
                })
                .frame(minWidth: 960, idealWidth: 1280, minHeight: 540, idealHeight: 720)
                .task { await model.load() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Mods…") { model.showMods = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

// hands the hosting NSWindow to the model so quick launch can keep it hidden
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
