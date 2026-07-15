// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallumeCore", targets: ["WallumeCore"]),
        .executable(name: "wallume-media", targets: ["WallumeMedia"]),
        .executable(name: "wallume-restore", targets: ["WallumeRestore"]),
    ],
    targets: [
        .target(name: "WallumeCore"),
        .executableTarget(name: "WallumeMedia", dependencies: ["WallumeCore"]),
        .executableTarget(name: "WallumeRestore", dependencies: ["WallumeCore"]),
        .testTarget(
            name: "WallumeCoreTests",
            dependencies: ["WallumeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
