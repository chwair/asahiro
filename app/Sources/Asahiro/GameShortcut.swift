import AppKit
import CoreServices

// a small "Zenless Zone Zero" app in ~/Applications that starts the game through asahiro's quick launch,
// so it can live in the dock and launchpad like a native game
enum GameShortcut {
    static let bundleID = "com.chair.asahiro.zzz-shortcut"
    // shortcuts made before the identifier change still count as ours and get migrated
    private static let legacyBundleIDs = ["dev.asahiro.zzz-shortcut"]

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Zenless Zone Zero.app")
    }

    enum Status: Equatable {
        case missing
        case ours
        // some other app already uses the name, steam creates one for example
        case foreign(String)
    }

    static var status: Status {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let info = NSDictionary(contentsOf: plist)
        if let id = info?["CFBundleIdentifier"] as? String, id == bundleID || legacyBundleIDs.contains(id) { return .ours }
        let exe = (info?["CFBundleExecutable"] as? String).map { url.appendingPathComponent("Contents/MacOS/\($0)") }
        let script = exe.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return .foreign(script.contains("steam://") ? "a Steam shortcut" : "another app")
    }

    // when asahiro is not running it is started with --quick-launch so its window never appears,
    // otherwise the running instance gets the asahiro://launch url
    private static let script = """
    #!/bin/sh
    if /usr/bin/pgrep -qx Asahiro; then
        exec /usr/bin/open -g "asahiro://launch"
    fi
    exec /usr/bin/open -g -b com.chair.asahiro --args --quick-launch

    """

    static func create(iconSource: String?) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("asahiro-shortcut-\(UUID().uuidString).app")
        let contents = staging.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleName": "Zenless Zone Zero",
            "CFBundleDisplayName": "Zenless Zone Zero",
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "zzz",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "26.0",
            "LSApplicationCategoryType": "public.app-category.games",
            // the stub exits right away, keep it from flashing in the dock
            "LSUIElement": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let exe = contents.appendingPathComponent("MacOS/zzz")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        if let iconSource, let image = NSImage(contentsOfFile: iconSource) {
            try writeIcon(image, to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        }

        run("/usr/bin/codesign", ["--force", "--sign", "-", staging.path])

        // only our own previous shortcut is overwritten in place
        if status == .ours { try fm.removeItem(at: url) }
        if fm.fileExists(atPath: url.path) { throw CoreError(message: "another Zenless Zone Zero app is already in Applications") }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: url)
        LSRegisterURL(url as CFURL, true)
    }

    // an old shortcut opens the launcher by its previous identifier, so its script and identifier are
    // rewritten in place, keeping the icon it was made with
    static func migrateIfNeeded() {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSMutableDictionary(contentsOf: plist),
              let id = info["CFBundleIdentifier"] as? String, legacyBundleIDs.contains(id),
              let name = info["CFBundleExecutable"] as? String else { return }
        info["CFBundleIdentifier"] = bundleID
        do {
            try info.write(to: plist)
            try script.write(to: url.appendingPathComponent("Contents/MacOS/\(name)"), atomically: true, encoding: .utf8)
        } catch {
            return
        }
        run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        LSRegisterURL(url as CFURL, true)
    }

    // only ever removes our own shortcut, a foreign one is replaced through create(replacing:) after asking
    static func remove(completion: @escaping () -> Void) {
        guard status == .ours else { return completion() }
        NSWorkspace.shared.recycle([url]) { _, _ in DispatchQueue.main.async(execute: completion) }
    }

    // moves whatever app has the name to the trash first, then installs ours
    static func replace(iconSource: String?, completion: @escaping (Error?) -> Void) {
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                if let error { return completion(error) }
                do {
                    try create(iconSource: iconSource)
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    // the game's own bundle, which wine runs from, shows the same icon in the dock. core copies it in at launch
    static var gameIconURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Asahiro/game-icon.icns")
    }

    // only renders again when the launcher hands out different art
    static func updateGameIcon(source: String) {
        let marker = gameIconURL.appendingPathExtension("source")
        if FileManager.default.fileExists(atPath: gameIconURL.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == source { return }
        guard let image = NSImage(contentsOfFile: source) else { return }
        do {
            try writeIcon(image, to: gameIconURL)
            try source.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            return
        }
    }

    // the windows shortcut art is a full bleed square, macos icons sit inset in a rounded square
    private static func writeIcon(_ image: NSImage, to icns: URL) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory.appendingPathComponent("asahiro-\(UUID().uuidString).iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                let ctx = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current = ctx
                ctx?.imageInterpolation = .high
                let s = CGFloat(px)
                let inset = s * 100 / 1024
                let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
                let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
                // a soft drop shadow like the system icons
                NSGraphicsContext.current?.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowBlurRadius = s * 0.02
                shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
                shadow.set()
                NSColor.black.setFill()
                shape.fill()
                NSGraphicsContext.current?.restoreGraphicsState()
                shape.addClip()
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name))
            }
        }
        if run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path]) != 0 {
            throw CoreError(message: "could not build the shortcut icon")
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
