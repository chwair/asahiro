import Foundation

struct BottleConfig: Codable, Equatable {
    var name: String
    var windowsVersion: String
    var graphicsBackend: String
    var msync: Bool
    var metalHud: Bool
    var metalfx: Bool
    var dlss: Bool
    var retina: Bool
    var leftCmdIsCtrl: Bool
    var leftOptionIsAlt: Bool
    var rightOptionIsAlt: Bool
    var env: [String: String]
    var dllOverrides: String

    enum CodingKeys: String, CodingKey {
        case name, msync, metalfx, dlss, retina, env
        case windowsVersion = "windows_version"
        case graphicsBackend = "graphics_backend"
        case metalHud = "metal_hud"
        case leftCmdIsCtrl = "left_cmd_is_ctrl"
        case leftOptionIsAlt = "left_option_is_alt"
        case rightOptionIsAlt = "right_option_is_alt"
        case dllOverrides = "dll_overrides"
    }
}

// mirrors core/src/config.rs, explicit keys keep env dictionary keys untouched
struct AppConfig: Codable, Equatable {
    var gameDir: String
    var crossoverPath: String
    var runner: String
    var voicePacks: [String]
    var bottle: BottleConfig
    var customResolution: Bool
    var resolutionWidth: Int
    var resolutionHeight: Int
    var fullscreen: Bool
    var useD3d12: Bool
    var launchArgs: String
    var hideLauncherWhilePlaying: Bool
    var launchFix: Bool
    var steamPatch: Bool
    var modsEnabled: Bool
    var modsAutoUpdate: Bool
    var modsHunting: Bool

    enum CodingKeys: String, CodingKey {
        case bottle, fullscreen
        case gameDir = "game_dir"
        case crossoverPath = "crossover_path"
        case runner
        case voicePacks = "voice_packs"
        case customResolution = "custom_resolution"
        case resolutionWidth = "resolution_width"
        case resolutionHeight = "resolution_height"
        case useD3d12 = "use_d3d12"
        case launchArgs = "launch_args"
        case hideLauncherWhilePlaying = "hide_launcher_while_playing"
        case launchFix = "launch_fix"
        case steamPatch = "steam_patch"
        case modsEnabled = "mods_enabled"
        case modsAutoUpdate = "mods_auto_update"
        case modsHunting = "mods_hunting"
    }

    var asJSONObject: [String: Any] {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

struct GameState: Decodable {
    var gameDir: String
    var installed: Bool
    var version: String?
    var latest: String
    var updateAvailable: Bool
    var canUpdate: Bool
    var predownload: String?
    var predownloadReady: Bool
    var voicePacks: [String]
    var downloadSize: Int64
    var installSize: Int64
    var freeSpace: Int64
    var partialDownload: Bool
}

struct ArtFiles: Decodable {
    var background: String?
    var video: String?
    var theme: String?
    var logo: String?
    var icon: String?
    var iconHover: String?
    var shortcutIcon: String?
}

struct Art: Decodable {
    var background: String
    var video: String?
    var theme: String?
    var logo: String
    var icon: String?
    var iconHover: String?
    var iconLink: String?
    var title: String
    var local: ArtFiles
}

struct WineInfo: Decodable {
    var crossoverFound: Bool
    var crossoverVersion: String?
    var runner: String
    var runnerName: String
    var runnerInstalled: Bool
    var rosetta: Bool
    var bottleExists: Bool
    var bottlePath: String
    var gameRunning: Bool
}

struct ZzmiStatus: Decodable {
    var installed: Bool
    var enabled: Bool
    var libsVersion: String?
    var zzmiVersion: String?
    var latestLibs: String?
    var latestZzmi: String?
    var zzmiPublished: String?
    var updateAvailable: Bool
    var modsPath: String
    var modCount: Int
}

struct ModInfo: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var path: String
    var size: Int64
    var iniCount: Int
    var preview: String?
    var character: String?
    var conflicts: [String]
    var modified: Int64

    // non-optional keys so the table can sort on them
    var characterKey: String { character ?? "\u{10FFFF}" }
    var enabledKey: Int { enabled ? 0 : 1 }
    var conflictKey: Int { conflicts.isEmpty ? 1 : 0 }
    var addedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
}

enum VoicePack: String, CaseIterable, Identifiable {
    case english = "en-us", japanese = "ja-jp", chinese = "zh-cn", korean = "ko-kr"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        case .korean: "Korean"
        }
    }
}

enum GraphicsBackend: String, CaseIterable, Identifiable {
    case dxmt, d3dmetal, dxvk, wined3d
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        }
    }
    var blurb: String {
        switch self {
        case .dxmt: "Metal-native D3D11. Works without CrossOver and is used for launches with mods."
        case .d3dmetal: "Apple's Game Porting Toolkit layer, taken from your CrossOver install. Best performance for ZZZ. Launches with mods use DXMT."
        case .dxvk: "D3D to Vulkan through MoltenVK. Compatibility fallback."
        case .wined3d: "OpenGL based. Slow, for troubleshooting only."
        }
    }

    // the bundled runner ships dxmt and borrows d3dmetal from an installed crossover, dxvk needs the crossover runner
    var needsCrossOverRunner: Bool { self == .dxvk }
    var needsCrossOverInstall: Bool { self == .d3dmetal || self == .dxvk }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}
