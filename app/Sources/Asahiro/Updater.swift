import AppKit
import Foundation

// checks the latest github release, stages its dmg in the caches folder and swaps the app bundle
// once asahiro quits, so an update never interrupts anything
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = URL(string: "https://github.com/chwair/asahiro")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/chwair/asahiro/releases/latest")!
    private static let autoKey = "autoUpdate"
    private static let lastCheckKey = "lastUpdateCheck"

    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.autoKey) }
    }

    private var staged: URL?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private init() {
        automatic = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
    }

    // only a real bundle in a writable folder can replace itself, not swift run or a translocated copy
    var canInstall: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app"), !path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    func checkOnLaunch() {
        guard automatic, canInstall else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        Task { await check() }
    }

    func check() async {
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        do {
            var request = URLRequest(url: Self.latestAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // github answers 404 until a release has been published
            if status == 404 {
                state = .upToDate
                return
            }
            guard status == 200 else {
                state = .failed("GitHub returned status \(status).")
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.isNewer(version, than: Self.currentVersion) else {
                state = .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                state = .failed("The \(version) release has no disk image.")
                return
            }
            guard canInstall else {
                state = .failed("Move Asahiro to Applications to update it.")
                return
            }
            state = .downloading(version)
            staged = try await stage(asset.browserDownloadUrl)
            state = .ready(version)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // downloads the dmg and copies the app out of it, so quitting only has to move a folder
    private func stage(_ url: URL) async throws -> URL {
        let (dmg, _) = try await URLSession.shared.download(from: url)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.chair.asahiro/update", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mount = dir.appendingPathComponent("mount")
        let app = dir.appendingPathComponent("Asahiro.app")
        try await Task.detached {
            try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path])
            defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            try Self.run("/usr/bin/ditto", [mount.appendingPathComponent("Asahiro.app").path, app.path])
        }.value
        try? FileManager.default.removeItem(at: dmg)
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw CoreError(message: "The downloaded update is not Asahiro.")
        }
        return app
    }

    // swaps the bundle after this process exits, called on quit or from the relaunch button
    func installStaged(relaunch: Bool) {
        guard let staged, canInstall else { return }
        self.staged = nil
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        ditto "$2" "$3.updating" || exit 1
        rm -rf "$3" && mv "$3.updating" "$3"
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        rm -rf "$(dirname "$2")"
        if [ "$4" = 1 ]; then open "$3"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)",
                       staged.path, Bundle.main.bundlePath, relaunch ? "1" : "0"]
        try? p.run()
    }

    func relaunch() {
        installStaged(relaunch: true)
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw CoreError(message: "\((tool as NSString).lastPathComponent) failed while unpacking the update.")
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
}
