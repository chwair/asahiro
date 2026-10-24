// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Asahiro",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CAsahiro", path: "Sources/CAsahiro"),
        .executableTarget(
            name: "Asahiro",
            dependencies: ["CAsahiro"],
            path: "Sources/Asahiro",
            linkerSettings: [
                .unsafeFlags(["-L", "../core/target/release"]),
                .linkedLibrary("asahiro_core"),
                .linkedLibrary("bz2"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
