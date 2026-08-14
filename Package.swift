// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallumeCore", targets: ["WallumeCore"]),
        .library(name: "WallumeAppSupport", targets: ["WallumeAppSupport"]),
        .executable(name: "WallumeApp", targets: ["WallumeApp"]),
        .executable(name: "wallume-media", targets: ["WallumeMedia"]),
        .executable(name: "wallume-restore", targets: ["WallumeRestore"]),
        .executable(name: "wallume-runtime", targets: ["WallumeRuntime"]),
        .executable(name: "wallume-provider-cleanup", targets: ["WallumeProviderCleanup"]),
        .library(name: "WallumeScreenSaver", type: .dynamic, targets: ["WallumeScreenSaver"]),
    ],
    targets: [
        .target(
            name: "WallumeCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .executableTarget(name: "WallumeMedia", dependencies: ["WallumeCore"]),
        .executableTarget(name: "WallumeRestore", dependencies: ["WallumeCore"]),
        .executableTarget(name: "WallumeRuntime", dependencies: ["WallumeCore"]),
        .executableTarget(name: "WallumeProviderCleanup", dependencies: ["WallumeAppSupport"]),
        .target(
            name: "WallumeScreenSaver",
            linkerSettings: [
                .linkedFramework("ScreenSaver"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .target(name: "WallumeAppSupport", dependencies: ["WallumeCore"]),
        .executableTarget(name: "WallumeApp", dependencies: ["WallumeCore", "WallumeAppSupport"]),
        .testTarget(
            name: "WallumeCoreTests",
            dependencies: ["WallumeCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WallumeAppSupportTests",
            dependencies: ["WallumeAppSupport", "WallumeCore"]
        ),
    ]
)
