import AppKit
import SwiftUI

// the top of the about page, laid out like the about pane in system settings: the icon centred
// over the name and version, with the project link underneath
struct AboutHero: View {
    var body: some View {
        VStack(spacing: Space.s) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .padding(.bottom, Space.xs)
            Text("Asahiro")
                .font(.system(size: 22, weight: .bold))
            Text(Updater.currentVersion == "dev" ? "Development build" : "Version \(Updater.currentVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Link(destination: Updater.repo) {
                Label("View on GitHub", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(Updater.repo.absoluteString)
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        SettingsGroup(header: "Updates") {
            SettingsRow(title: title, subtitle: subtitle) {
                switch updater.state {
                case .checking, .downloading:
                    ProgressView().controlSize(.small)
                case .ready:
                    Button("Relaunch") { updater.relaunch() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.zzzYellow)
                        .foregroundStyle(Color.zzzInk)
                case .failed:
                    Button("Try Again") { Task { await updater.check() } }.controlSize(.small)
                default:
                    Button("Check Now") { Task { await updater.check() } }.controlSize(.small)
                }
            }
            SettingsToggle(title: "Update automatically", subtitle: "Downloads new versions in the background and installs them when you quit.",
                           isOn: $updater.automatic)
        }
    }

    private var title: String {
        switch updater.state {
        case .idle: "Asahiro \(Updater.currentVersion)"
        case .checking: "Checking for updates…"
        case .upToDate: "Asahiro is up to date"
        case .downloading(let v): "Downloading Asahiro \(v)…"
        case .ready(let v): "Asahiro \(v) is ready"
        case .failed: "Couldn't update"
        }
    }

    private var subtitle: String? {
        switch updater.state {
        case .ready: "Installs when you quit, or relaunch now."
        case .failed(let message): message
        default: nil
        }
    }
}
