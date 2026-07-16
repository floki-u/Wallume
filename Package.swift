// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallumeCore", targets: ["WallumeCore"]),
        .executable(name: "wallume-media", targets: ["WallumeMedia"]),
        .executable(name: "wallume-restore", targets: ["WallumeRestore"]),
        .executable(name: "wallume-runtime", targets: ["WallumeRuntime"]),
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
        .testTarget(
            name: "WallumeCoreTests",
            dependencies: ["WallumeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
