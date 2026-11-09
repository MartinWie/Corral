// swift-tools-version:6.2
import PackageDescription
import Foundation

// libghostty is built from vendor/ghostty by scripts/build-ghostty.sh into vendor/ghostty-out.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyLib = "\(packageDir)/vendor/ghostty-out/lib"
// Without the library (fresh clone, CI) the app target is left out so core tests still build.
let hasGhostty = FileManager.default.fileExists(atPath: "\(ghosttyLib)/libghostty.a")

let appTargets: [Target] = [
    .systemLibrary(name: "GhosttyKit", path: "Sources/GhosttyKit"),
    .executableTarget(
        name: "Corral",
        dependencies: ["CorralCore", "CorralKit", "GhosttyKit", .product(name: "Sparkle", package: "Sparkle")],
        linkerSettings: [
            // bundle.sh copies Sparkle.framework into Contents/Frameworks.
            .unsafeFlags(["-L", ghosttyLib, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            .linkedLibrary("ghostty"),
            .linkedLibrary("c++"),
            .linkedFramework("Carbon"),
            .linkedFramework("CoreText"),
            .linkedFramework("CoreGraphics"),
            .linkedFramework("CoreVideo"),
            .linkedFramework("IOSurface"),
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore"),
        ]
    ),
]

let package = Package(
    name: "Corral",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "corral-hook", targets: ["corral-hook"]),
    ] + (hasGhostty ? [.executable(name: "Corral", targets: ["Corral"])] : []),
    // Updates (app target only), so core tests resolve no packages.
    dependencies: hasGhostty ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")] : [],
    targets: [
        .target(name: "CorralCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Plain C: Claude Code runs it synchronously on every hook, so startup must be ~1 ms.
        .executableTarget(name: "corral-hook", cSettings: [.unsafeFlags(["-O2"])]),
        // Session manager + UI, behind TerminalSurface so it builds and tests without libghostty.
        .target(
            name: "CorralKit",
            dependencies: ["CorralCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "CorralCoreTests", dependencies: ["CorralCore"]),
        .testTarget(name: "CorralKitTests", dependencies: ["CorralKit", "CorralCore"]),
    ] + (hasGhostty ? appTargets : []),
    swiftLanguageModes: [.v5]
)
