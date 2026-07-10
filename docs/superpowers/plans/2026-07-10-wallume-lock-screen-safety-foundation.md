# Wallume Lock-Screen Safety Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure-Swift, fully tested foundation that can discover a user-selected macOS Aerial slot, plan narrowly scoped `Index.plist` changes, install a replacement through a durable transaction, and safely restore only Wallume-owned changes.

**Architecture:** Start as a Swift Package so the dangerous system-integration logic is independent of the future AppKit UI and can be exhaustively tested against temporary directories and plist fixtures. Production filesystem, hashing, process-refresh, and OS-version behavior sit behind injected protocols; tests never write to the real `com.apple.wallpaper` directories. A standalone `wallume-restore` executable consumes the same recovery API, so recovery remains available even when the app bundle is missing.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, CryptoKit, XCTest, macOS 14 SDK or newer, GitHub Actions.

## Global Constraints

- Product name is `Wallume`; Bundle ID is `app.wallume.Wallume`.
- Target Apple Silicon only; deployment target is macOS 14.
- Support only macOS major versions 14, 15, and 26; every other major version is read-only/unsupported.
- Use pure Swift and Apple frameworks; do not add Python, ffmpeg, third-party packages, or a daemon.
- Never modify `/System`, authentication state, or unlock behavior; never request root.
- `entries.json` is read-only.
- Never choose the first Aerial implicitly; installation requires an explicit Aerial UUID selected by the user.
- Every system write requires preflight, durable journal creation, same-directory temporary files, validation, atomic replacement, verification, and compare-and-restore recovery.
- Tests operate only on fixtures and temporary directories. No automated test may target the developer's live wallpaper directories.
- Commit author for this repository is `floki-u <117898635+floki-u@users.noreply.github.com>`.

## Program Decomposition

This is phase 1 of five independently reviewable plans:

1. **Lock-screen safety foundation (this plan):** package foundation, version routing, Aerial discovery, plist mutation, durable transaction, compare-and-restore, recovery CLI.
2. **Media library and HEVC importer:** AVFoundation validation, VideoToolbox variants, thumbnails, metadata, import queue.
3. **Wallpaper runtime:** AppKit desktop windows, display sessions, shared AVPlayer resources, pause and power behavior, performance benchmarks.
4. **Application shell and UI:** status item, extensible sidebar, gallery, display/lock-screen/performance/settings modules, localization.
5. **Distribution and release:** app packaging, signing/notarization hooks, GitHub Release, Homebrew Cask restore-first uninstall, end-to-end release gates.

Phase 2 begins only after this plan proves that incomplete transactions and uninstall recovery cannot overwrite unrelated current system state.

## File Map

```text
Package.swift                                      SwiftPM products and targets
Sources/WallumeCore/BuildInfo.swift                Stable product identity
Sources/WallumeCore/System/SystemVersion.swift     Supported OS routing
Sources/WallumeCore/System/AerialPaths.swift       All external paths from injected home/UID
Sources/WallumeCore/IO/FileStore.swift              Filesystem protocol and local implementation
Sources/WallumeCore/IO/Digester.swift               SHA-256 protocol and CryptoKit implementation
Sources/WallumeCore/IO/AtomicJSONStore.swift        Durable Codable journal storage
Sources/WallumeCore/LockScreen/AerialDiscovery.swift Read-only manifest and slot discovery
Sources/WallumeCore/LockScreen/PlistMutation.swift  Codable plist paths and before/after records
Sources/WallumeCore/LockScreen/WallpaperIndexPatcher.swift Narrow Idle configuration patching
Sources/WallumeCore/LockScreen/TransactionModels.swift Durable transaction schema
Sources/WallumeCore/LockScreen/LockScreenTransaction.swift Install state machine
Sources/WallumeCore/LockScreen/RecoveryCoordinator.swift Compare-and-restore recovery
Sources/WallumeCore/LockScreen/WallpaperRefresher.swift Targeted process refresh protocol
Sources/WallumeRestore/main.swift                  Standalone status/restore CLI
Tests/WallumeCoreTests/Fixtures/*.plist            Sanitized macOS 14/15/26-like index fixtures
Tests/WallumeCoreTests/Fixtures/entries.json        Sanitized Aerial manifest fixture
Tests/WallumeCoreTests/*.swift                     Unit and integration tests
.github/workflows/ci.yml                           arm64 build and test workflow
```

---

### Task 1: Bootstrap the Swift package and stable identity

**Files:**
- Create: `Package.swift`
- Create: `Sources/WallumeCore/BuildInfo.swift`
- Create: `Sources/WallumeRestore/main.swift`
- Create: `Tests/WallumeCoreTests/BuildInfoTests.swift`

**Interfaces:**
- Produces: `WallumeBuildInfo.productName: String`
- Produces: `WallumeBuildInfo.bundleIdentifier: String`
- Produces: SwiftPM library product `WallumeCore`
- Produces: SwiftPM executable product `wallume-restore`

- [ ] **Step 1: Create the package manifest and a failing identity test**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallume",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallumeCore", targets: ["WallumeCore"]),
        .executable(name: "wallume-restore", targets: ["WallumeRestore"]),
    ],
    targets: [
        .target(name: "WallumeCore"),
        .executableTarget(name: "WallumeRestore", dependencies: ["WallumeCore"]),
        .testTarget(
            name: "WallumeCoreTests",
            dependencies: ["WallumeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

```swift
// Tests/WallumeCoreTests/BuildInfoTests.swift
import XCTest
@testable import WallumeCore

final class BuildInfoTests: XCTestCase {
    func testStableProductIdentity() {
        XCTAssertEqual(WallumeBuildInfo.productName, "Wallume")
        XCTAssertEqual(WallumeBuildInfo.bundleIdentifier, "app.wallume.Wallume")
    }
}
```

Use this intentional initial executable behavior while the recovery API does not exist:

```swift
// Sources/WallumeRestore/main.swift
import Foundation

FileHandle.standardError.write(Data("wallume-restore is not implemented yet\n".utf8))
exit(64)
```

- [ ] **Step 2: Run the test and verify the missing symbol failure**

Run: `swift test --filter BuildInfoTests`

Expected: compilation fails with `cannot find 'WallumeBuildInfo' in scope`.

- [ ] **Step 3: Add the minimal stable identity**

```swift
// Sources/WallumeCore/BuildInfo.swift
public enum WallumeBuildInfo {
    public static let productName = "Wallume"
    public static let bundleIdentifier = "app.wallume.Wallume"
    public static let backupMarker = ".app.wallume.Wallume.original"
}
```

- [ ] **Step 4: Run the focused test and complete package build**

Run: `swift test --filter BuildInfoTests && swift build --product wallume-restore`

Expected: the test passes and the executable builds successfully.

- [ ] **Step 5: Commit the bootstrap**

```bash
git add Package.swift Sources Tests
git commit -m "build: bootstrap Wallume core package"
```

---

### Task 2: Route supported macOS versions and derive paths without global state

**Files:**
- Create: `Sources/WallumeCore/System/SystemVersion.swift`
- Create: `Sources/WallumeCore/System/AerialPaths.swift`
- Create: `Tests/WallumeCoreTests/SystemVersionTests.swift`
- Create: `Tests/WallumeCoreTests/AerialPathsTests.swift`

**Interfaces:**
- Produces: `MacOSGeneration.init(version:) -> MacOSGeneration`
- Produces: `AerialPaths.init(homeDirectory:userGeneratedID:)`
- Consumes: `WallumeBuildInfo.productName`

- [ ] **Step 1: Write failing routing and path tests**

```swift
// Tests/WallumeCoreTests/SystemVersionTests.swift
import XCTest
@testable import WallumeCore

final class SystemVersionTests: XCTestCase {
    func testSupportedMajorVersionsAreExplicit() {
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 14, minorVersion: 7, patchVersion: 0)), .sonoma)
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 15, minorVersion: 6, patchVersion: 0)), .sequoia)
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 26, minorVersion: 5, patchVersion: 2)), .tahoe)
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 13, minorVersion: 7, patchVersion: 0)), .unsupported(13))
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)), .unsupported(27))
    }
}
```

```swift
// Tests/WallumeCoreTests/AerialPathsTests.swift
import XCTest
@testable import WallumeCore

final class AerialPathsTests: XCTestCase {
    func testDerivesOnlyKnownUserAndCachePaths() {
        let paths = AerialPaths(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            userGeneratedID: "USER-UUID"
        )
        XCTAssertEqual(paths.videosDirectory.path, "/Users/tester/Library/Application Support/com.apple.wallpaper/aerials/videos")
        XCTAssertEqual(paths.manifest.path, "/Users/tester/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")
        XCTAssertEqual(paths.wallpaperIndex.path, "/Users/tester/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        XCTAssertEqual(paths.lockScreenPoster.path, "/Library/Caches/Desktop Pictures/USER-UUID/lockscreen.png")
        XCTAssertEqual(paths.transactionsDirectory.path, "/Users/tester/Library/Application Support/Wallume/LockScreen/transactions")
    }
}
```

- [ ] **Step 2: Run the tests and verify both types are missing**

Run: `swift test --filter SystemVersionTests && swift test --filter AerialPathsTests`

Expected: compilation fails because `MacOSGeneration` and `AerialPaths` do not exist.

- [ ] **Step 3: Implement explicit version routing**

```swift
// Sources/WallumeCore/System/SystemVersion.swift
import Foundation

public enum MacOSGeneration: Equatable, Sendable {
    case sonoma
    case sequoia
    case tahoe
    case unsupported(Int)

    public init(version: OperatingSystemVersion) {
        switch version.majorVersion {
        case 14: self = .sonoma
        case 15: self = .sequoia
        case 26: self = .tahoe
        default: self = .unsupported(version.majorVersion)
        }
    }

    public var permitsWrites: Bool {
        switch self {
        case .sonoma, .sequoia, .tahoe: true
        case .unsupported: false
        }
    }
}
```

- [ ] **Step 4: Implement injected path derivation**

```swift
// Sources/WallumeCore/System/AerialPaths.swift
import Foundation

public struct AerialPaths: Equatable, Sendable {
    public let videosDirectory: URL
    public let manifest: URL
    public let wallpaperIndex: URL
    public let lockScreenPoster: URL
    public let applicationSupport: URL
    public let transactionsDirectory: URL
    public let systemBackupsDirectory: URL

    public init(homeDirectory: URL, userGeneratedID: String) {
        let support = homeDirectory.appending(path: "Library/Application Support")
        let wallpaper = support.appending(path: "com.apple.wallpaper")
        let wallume = support.appending(path: WallumeBuildInfo.productName)
        videosDirectory = wallpaper.appending(path: "aerials/videos")
        manifest = wallpaper.appending(path: "aerials/manifest/entries.json")
        wallpaperIndex = wallpaper.appending(path: "Store/Index.plist")
        lockScreenPoster = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures")
            .appending(path: userGeneratedID)
            .appending(path: "lockscreen.png")
        applicationSupport = wallume
        transactionsDirectory = wallume.appending(path: "LockScreen/transactions")
        systemBackupsDirectory = wallume.appending(path: "SystemBackups")
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter SystemVersionTests && swift test --filter AerialPathsTests`

Expected: both suites pass.

```bash
git add Sources/WallumeCore/System Tests/WallumeCoreTests
git commit -m "feat: add lock-screen environment routing"
```

---

### Task 3: Add durable atomic IO and SHA-256 verification

**Files:**
- Create: `Sources/WallumeCore/IO/FileStore.swift`
- Create: `Sources/WallumeCore/IO/Digester.swift`
- Create: `Sources/WallumeCore/IO/AtomicJSONStore.swift`
- Create: `Tests/WallumeCoreTests/AtomicIOTests.swift`

**Interfaces:**
- Produces: `FileStore` protocol
- Produces: `LocalFileStore`
- Produces: `Digesting.sha256(of:) -> String`
- Produces: `AtomicJSONStore.write(_:to:)` and `read(_:from:)`

- [ ] **Step 1: Write failing atomic-write, copy, failure-cleanup, concurrency, and digest tests**

```swift
// Tests/WallumeCoreTests/AtomicIOTests.swift
import XCTest
@testable import WallumeCore

private struct JournalFixture: Codable, Equatable, Sendable {
    let phase: String
    let count: Int
}

final class AtomicIOTests: XCTestCase {
    func testAtomicJSONRoundTripLeavesNoTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "journal.json")
        let files = LocalFileStore()
        let store = AtomicJSONStore(files: files)

        try store.write(JournalFixture(phase: "prepared", count: 2), to: target)

        XCTAssertEqual(try store.read(JournalFixture.self, from: target), .init(phase: "prepared", count: 2))
        XCTAssertEqual(try files.contents(root).map(\.lastPathComponent), ["journal.json"])
    }

    func testSHA256UsesLowercaseHex() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "value")
        try Data("wallume".utf8).write(to: file)
        XCTAssertEqual(
            try SHA256Digester().sha256(of: file),
            "66c0fb338a923a6b5af567f8489078f61fc52d070a952d6aa602b484a5c31e60"
        )
    }
}
```

Also add focused tests proving that an existing target can be replaced, concurrent writes always install one complete payload, `copy` atomically overwrites with complete contents, replacement failures preserve the old target and clean only the operation's own temporary file, directory-sync errors propagate, and every temporary test root is removed with `defer`.

- [ ] **Step 2: Run and verify missing IO types**

Run: `swift test --filter AtomicIOTests`

Expected: compilation fails because the IO types do not exist.

- [ ] **Step 3: Implement the filesystem boundary and durable same-directory staging**

```swift
// Sources/WallumeCore/IO/FileStore.swift
import Darwin
import Foundation

public protocol FileStore: Sendable {
    func exists(_ url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    func contents(_ directory: URL) throws -> [URL]
    func createDirectory(_ url: URL) throws
    func writeAtomically(_ data: Data, to target: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func replace(_ target: URL, with preparedFile: URL) throws
    func remove(_ url: URL) throws
}

public struct LocalFileStore: FileStore {
    private let replaceItem: @Sendable (URL, URL) throws -> Void
    private let synchronizeDirectory: @Sendable (URL) throws -> Void
    private var manager: FileManager { .default }

    public init() {
        replaceItem = Self.renameItem
        synchronizeDirectory = Self.synchronizeDirectoryEntry
    }
    init(
        replaceItem: @escaping @Sendable (URL, URL) throws -> Void,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.replaceItem = replaceItem
        self.synchronizeDirectory = synchronizeDirectory
    }

    public func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func contents(_ directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    public func createDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func copy(_ source: URL, to destination: URL) throws {
        let sourceHandle = try FileHandle(forReadingFrom: source)
        var sourceIsClosed = false
        defer { if !sourceIsClosed { try? sourceHandle.close() } }
        try installAtomically(to: destination) { destinationHandle in
            while let chunk = try sourceHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try destinationHandle.write(contentsOf: chunk)
            }
            try sourceHandle.close()
            sourceIsClosed = true
        }
    }
    public func remove(_ url: URL) throws {
        if exists(url) { try manager.removeItem(at: url) }
    }
    public func writeAtomically(_ data: Data, to target: URL) throws {
        try installAtomically(to: target) { handle in
            try handle.write(contentsOf: data)
        }
    }
    public func replace(_ target: URL, with preparedFile: URL) throws {
        try replaceItem(preparedFile, target)
        try synchronizeDirectory(target.deletingLastPathComponent())
    }

    private func installAtomically(
        to target: URL,
        writing contents: (FileHandle) throws -> Void
    ) throws {
        try createDirectory(target.deletingLastPathComponent())
        let (temporary, handle) = try makeTemporaryFile(nextTo: target)
        var handleIsClosed = false
        defer {
            if !handleIsClosed { try? handle.close() }
            try? remove(temporary)
        }
        try contents(handle)
        try handle.synchronize()
        try handle.close()
        handleIsClosed = true
        try replace(target, with: temporary)
    }

    private func makeTemporaryFile(nextTo target: URL) throws -> (URL, FileHandle) {
        let directory = target.deletingLastPathComponent()
        var template = Array(
            directory.appending(path: ".\(target.lastPathComponent).wallume.tmp.XXXXXX")
                .path.utf8CString
        )
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress) }
        guard descriptor >= 0 else { throw Self.posixError() }
        let path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return (
            URL(fileURLWithPath: path),
            FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        )
    }

    private static func renameItem(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError() }
    }

    private static func synchronizeDirectoryEntry(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError() }
        if Darwin.fsync(descriptor) != 0 {
            let error = posixError()
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
```

- [ ] **Step 4: Implement SHA-256 and atomic Codable storage**

```swift
// Sources/WallumeCore/IO/Digester.swift
import CryptoKit
import Foundation

public protocol Digesting: Sendable {
    func sha256(of url: URL) throws -> String
}

public struct SHA256Digester: Digesting {
    public init() {}
    public func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

```swift
// Sources/WallumeCore/IO/AtomicJSONStore.swift
import Foundation

public struct AtomicJSONStore: Sendable {
    private let files: any FileStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(files: any FileStore) {
        self.files = files
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try files.writeAtomically(encoder.encode(value), to: url)
    }

    public func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try decoder.decode(type, from: files.read(url))
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter AtomicIOTests`

Expected: both tests pass.

```bash
git add Sources/WallumeCore/IO Tests/WallumeCoreTests/AtomicIOTests.swift
git commit -m "feat: add durable verified file IO"
```

---

### Task 4: Discover only explicit, manifest-backed Aerial slots and block conflicts

**Files:**
- Create: `Sources/WallumeCore/LockScreen/AerialDiscovery.swift`
- Create: `Tests/WallumeCoreTests/Fixtures/entries.json`
- Create: `Tests/WallumeCoreTests/AerialDiscoveryTests.swift`

**Interfaces:**
- Produces: `AerialSlot { id, displayName, videoURL }`
- Produces: `AerialDiscovery.availableSlots(paths:)`
- Produces: `AerialDiscovery.selectSlot(id:paths:)`
- Produces: `AerialDiscoveryError`
- Consumes: `AerialPaths`, `FileStore`, `WallumeBuildInfo.backupMarker`

- [ ] **Step 1: Add a sanitized manifest fixture**

```json
{
  "assets": [
    {"id": "AERIAL-ONE", "accessibilityLabel": "Test Coast"},
    {"id": "AERIAL-TWO", "accessibilityLabel": "Test Valley"}
  ]
}
```

- [ ] **Step 2: Write failing explicit-selection and conflict tests**

```swift
// Tests/WallumeCoreTests/AerialDiscoveryTests.swift
import XCTest
@testable import WallumeCore

final class AerialDiscoveryTests: XCTestCase {
    func testOnlyManifestBackedMovFilesAreOffered() throws {
        let fixture = try AerialFixture.make()
        try fixture.writeVideo(id: "AERIAL-ONE")
        try fixture.writeVideo(id: "UNLISTED")
        let slots = try fixture.discovery.availableSlots(paths: fixture.paths)
        XCTAssertEqual(slots.map(\.id), ["AERIAL-ONE"])
        XCTAssertEqual(slots.first?.displayName, "Test Coast")
    }

    func testSelectionRequiresExactIDAndRejectsForeignBackup() throws {
        let fixture = try AerialFixture.make()
        try fixture.writeVideo(id: "AERIAL-ONE")
        try Data("foreign".utf8).write(
            to: fixture.paths.videosDirectory.appending(path: "AERIAL-ONE.mov.wallpaper-engine-backup")
        )
        XCTAssertThrowsError(try fixture.discovery.selectSlot(id: "AERIAL-ONE", paths: fixture.paths)) {
            XCTAssertEqual($0 as? AerialDiscoveryError, .foreignModificationDetected("AERIAL-ONE"))
        }
        XCTAssertThrowsError(try fixture.discovery.selectSlot(id: "MISSING", paths: fixture.paths)) {
            XCTAssertEqual($0 as? AerialDiscoveryError, .slotNotFound("MISSING"))
        }
    }
}
```

`AerialFixture` is a test helper in the same file. It creates a unique temporary home, copies `entries.json` from `Bundle.module`, constructs `AerialPaths`, and never references the real home directory.

- [ ] **Step 3: Run and verify discovery symbols are missing**

Run: `swift test --filter AerialDiscoveryTests`

Expected: compilation fails because `AerialDiscovery` and `AerialSlot` do not exist.

- [ ] **Step 4: Implement manifest-backed discovery**

```swift
// Sources/WallumeCore/LockScreen/AerialDiscovery.swift
import Foundation

public struct AerialSlot: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let videoURL: URL
}

public enum AerialDiscoveryError: Error, Equatable {
    case malformedManifest
    case slotNotFound(String)
    case foreignModificationDetected(String)
}

public struct AerialDiscovery: Sendable {
    private struct Manifest: Decodable { let assets: [Asset] }
    private struct Asset: Decodable { let id: String; let accessibilityLabel: String? }
    private let files: any FileStore

    public init(files: any FileStore) { self.files = files }

    public func availableSlots(paths: AerialPaths) throws -> [AerialSlot] {
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: files.read(paths.manifest)) }
        catch { throw AerialDiscoveryError.malformedManifest }
        let labels = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0.accessibilityLabel ?? $0.id) })
        return try files.contents(paths.videosDirectory)
            .filter { $0.pathExtension.lowercased() == "mov" }
            .compactMap { url in
                let id = url.deletingPathExtension().lastPathComponent
                return labels[id].map { AerialSlot(id: id, displayName: $0, videoURL: url) }
            }
            .sorted { $0.id < $1.id }
    }

    public func selectSlot(id: String, paths: AerialPaths) throws -> AerialSlot {
        guard let slot = try availableSlots(paths: paths).first(where: { $0.id == id }) else {
            throw AerialDiscoveryError.slotNotFound(id)
        }
        let prefix = slot.videoURL.lastPathComponent + "."
        let siblings = try files.contents(paths.videosDirectory).filter {
            $0.lastPathComponent.hasPrefix(prefix) && !$0.lastPathComponent.contains(WallumeBuildInfo.bundleIdentifier)
        }
        guard siblings.isEmpty else { throw AerialDiscoveryError.foreignModificationDetected(id) }
        return slot
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter AerialDiscoveryTests`

Expected: both tests pass and no path outside the fixture root is read.

```bash
git add Sources/WallumeCore/LockScreen/AerialDiscovery.swift Tests/WallumeCoreTests
git commit -m "feat: add safe Aerial slot discovery"
```

---

### Task 5: Plan and apply narrow Idle plist mutations across known schemas

**Files:**
- Create: `Sources/WallumeCore/LockScreen/PlistMutation.swift`
- Create: `Sources/WallumeCore/LockScreen/WallpaperIndexPatcher.swift`
- Create: `Tests/WallumeCoreTests/Fixtures/index-sonoma.plist`
- Create: `Tests/WallumeCoreTests/Fixtures/index-sequoia.plist`
- Create: `Tests/WallumeCoreTests/Fixtures/index-tahoe.plist`
- Create: `Tests/WallumeCoreTests/WallpaperIndexPatcherTests.swift`

**Interfaces:**
- Produces: `PlistPathComponent.key(_:)` and `.index(_:)`
- Produces: `PlistMutation { path, before, after }`
- Produces: `WallpaperIndexPatcher.plan(indexData:aerialID:) -> [PlistMutation]`
- Produces: `WallpaperIndexPatcher.apply(_:to:) -> Data`
- Produces: `WallpaperIndexPatcher.restore(_:in:) -> RestoreOutcome`

- [ ] **Step 1: Create three sanitized binary plist fixtures**

Each fixture must contain different combinations of `Displays`, `Spaces`, `SystemDefault`, and nullable `AllSpacesAndDisplays`. Every fixture contains at least one `Idle.Content.Choices` entry whose `Provider` is `com.apple.wallpaper.choice.aerials`, with `Configuration` stored as binary plist `Data`. Generate the binary fixtures from reviewed XML source using:

```bash
plutil -convert binary1 Tests/WallumeCoreTests/Fixtures/index-sonoma.plist
plutil -convert binary1 Tests/WallumeCoreTests/Fixtures/index-sequoia.plist
plutil -convert binary1 Tests/WallumeCoreTests/Fixtures/index-tahoe.plist
```

- [ ] **Step 2: Write failing mutation and compare-and-restore tests**

```swift
// Tests/WallumeCoreTests/WallpaperIndexPatcherTests.swift
import XCTest
@testable import WallumeCore

final class WallpaperIndexPatcherTests: XCTestCase {
    func testPlansOnlyAerialIdleConfigurationMutationsForEveryKnownSchema() throws {
        for name in ["index-sonoma", "index-sequoia", "index-tahoe"] {
            let data = try fixtureData(name, extension: "plist")
            let patcher = WallpaperIndexPatcher()
            let mutations = try patcher.plan(indexData: data, aerialID: "AERIAL-ONE")
            XCTAssertFalse(mutations.isEmpty, name)
            XCTAssertTrue(mutations.allSatisfy {
                $0.path.contains(.key("Idle")) && $0.path.last == .key("Configuration")
            })
            let changed = try patcher.apply(mutations, to: data)
            XCTAssertNotEqual(changed, data)
        }
    }

    func testRestoreSkipsAValueChangedAfterWallumeWrite() throws {
        let original = try fixtureData("index-tahoe", extension: "plist")
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: original, aerialID: "AERIAL-ONE")
        let installed = try patcher.apply(mutations, to: original)
        let externallyChanged = try patcher.replacingFirstAfterValue(in: installed, withSelectedID: "OTHER-APP")
        let result = try patcher.restore(mutations, in: externallyChanged)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.data, externallyChanged)
    }
}
```

- [ ] **Step 3: Run and verify patcher types are missing**

Run: `swift test --filter WallpaperIndexPatcherTests`

Expected: compilation fails because `WallpaperIndexPatcher` and `PlistMutation` do not exist.

- [ ] **Step 4: Implement Codable path and mutation records**

```swift
// Sources/WallumeCore/LockScreen/PlistMutation.swift
import Foundation

public enum PlistPathComponent: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)
}

public struct PlistMutation: Codable, Equatable, Sendable {
    public let path: [PlistPathComponent]
    public let before: Data
    public let after: Data

    public init(path: [PlistPathComponent], before: Data, after: Data) {
        self.path = path
        self.before = before
        self.after = after
    }
}

public struct RestoreOutcome: Equatable, Sendable {
    public let data: Data
    public let restoredPaths: [[PlistPathComponent]]
    public let conflicts: [[PlistPathComponent]]
}
```

- [ ] **Step 5: Implement recursive Idle discovery and semantic apply/restore**

`WallpaperIndexPatcher` must:

1. Parse binary or XML plist using `PropertyListSerialization`.
2. Recursively traverse dictionaries and arrays while carrying `[PlistPathComponent]`.
3. Select only dictionary entries where `Provider == "com.apple.wallpaper.choice.aerials"` and the entry is below an `Idle` key.
4. Encode the existing `Configuration` value as a standalone binary plist fragment for `before`.
5. Encode `{"selectedID": aerialID, "showAsScreenSaver": true}` as the `after` fragment.
6. Apply a mutation only when the current fragment equals `before`.
7. Restore a mutation only when the current fragment equals `after`; otherwise return its path in `conflicts` without changing it.
8. Serialize the complete updated root as binary plist.

Use these exact public signatures:

```swift
// Sources/WallumeCore/LockScreen/WallpaperIndexPatcher.swift
import Foundation

public enum WallpaperIndexError: Error, Equatable {
    case invalidPropertyList
    case noAerialIdleChoice
    case staleValue([PlistPathComponent])
    case invalidPath([PlistPathComponent])
}

public struct WallpaperIndexPatcher: Sendable {
    public init() {}
    public func plan(indexData: Data, aerialID: String) throws -> [PlistMutation]
    public func apply(_ mutations: [PlistMutation], to indexData: Data) throws -> Data
    public func restore(_ mutations: [PlistMutation], in indexData: Data) throws -> RestoreOutcome
}
```

- [ ] **Step 6: Run fixtures through the patcher and commit**

Run: `swift test --filter WallpaperIndexPatcherTests`

Expected: all three known schema fixtures produce mutations; the external-change test reports one conflict and preserves the external value.

```bash
git add Sources/WallumeCore/LockScreen Tests/WallumeCoreTests
git commit -m "feat: add reversible wallpaper index patches"
```

---

### Task 6: Implement the durable install transaction with injected failure points

**Files:**
- Create: `Sources/WallumeCore/LockScreen/TransactionModels.swift`
- Create: `Sources/WallumeCore/LockScreen/WallpaperRefresher.swift`
- Create: `Sources/WallumeCore/LockScreen/LockScreenTransaction.swift`
- Create: `Tests/WallumeCoreTests/LockScreenTransactionTests.swift`

**Interfaces:**
- Produces: `LockScreenTransactionRequest`
- Produces: `LockScreenTransactionManifest`
- Produces: `LockScreenTransaction.install(_:) -> LockScreenTransactionManifest`
- Produces: `FaultInjecting.hit(_:)`
- Consumes: discovery, patcher, file store, digester, atomic JSON store, version routing

- [ ] **Step 1: Write a failing successful-install test**

```swift
// Tests/WallumeCoreTests/LockScreenTransactionTests.swift
import XCTest
@testable import WallumeCore

final class LockScreenTransactionTests: XCTestCase {
    func testInstallCommitsOnlyAfterVideoIndexAndPosterVerify() throws {
        let fixture = try TransactionFixture.make()
        let result = try fixture.transaction.install(.init(
            systemVersion: .init(majorVersion: 26, minorVersion: 5, patchVersion: 2),
            aerialID: "AERIAL-ONE",
            optimizedVideo: fixture.optimizedVideo,
            poster: fixture.poster
        ))
        XCTAssertEqual(result.phase, .committed)
        XCTAssertEqual(try fixture.digest.sha256(of: fixture.slotVideo), result.video.installedHash)
        XCTAssertEqual(try fixture.digest.sha256(of: fixture.posterTarget), result.poster.installedHash)
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
        XCTAssertTrue(fixture.files.exists(result.primaryBackup))
        XCTAssertTrue(fixture.files.exists(result.recoveryBackup))
    }
}
```

- [ ] **Step 2: Write a failing crash-before-commit test**

```swift
func testFailureAfterVideoReplacementLeavesRecoverableWritingJournal() throws {
    let fixture = try TransactionFixture.make(failingAt: .afterVideoReplacement)
    XCTAssertThrowsError(try fixture.transaction.install(fixture.request))
    let manifest = try fixture.journals.read(
        LockScreenTransactionManifest.self,
        from: fixture.onlyJournalURL()
    )
    XCTAssertEqual(manifest.phase, .writing)
    XCTAssertTrue(fixture.files.exists(manifest.primaryBackup))
    XCTAssertTrue(fixture.files.exists(manifest.recoveryBackup))
}
```

- [ ] **Step 3: Define the durable transaction schema**

```swift
// Sources/WallumeCore/LockScreen/TransactionModels.swift
import Foundation

public enum TransactionPhase: String, Codable, Sendable { case prepared, writing, committed, restored, conflicted }

public struct FileReplacementRecord: Codable, Equatable, Sendable {
    public let target: URL
    public let originalHash: String?
    public let installedHash: String
    public let originalBackup: URL?
}

public struct LockScreenTransactionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public var phase: TransactionPhase
    public let createdAt: Date
    public let osMajorVersion: Int
    public let aerialID: String
    public let video: FileReplacementRecord
    public let poster: FileReplacementRecord
    public let indexURL: URL
    public let indexMutations: [PlistMutation]
    public let primaryBackup: URL
    public let recoveryBackup: URL
}

public struct LockScreenTransactionRequest: Sendable {
    public let systemVersion: OperatingSystemVersion
    public let aerialID: String
    public let optimizedVideo: URL
    public let poster: URL
    public init(systemVersion: OperatingSystemVersion, aerialID: String, optimizedVideo: URL, poster: URL) {
        self.systemVersion = systemVersion
        self.aerialID = aerialID
        self.optimizedVideo = optimizedVideo
        self.poster = poster
    }
}
```

- [ ] **Step 4: Add injected refresh and failure boundaries**

```swift
// Sources/WallumeCore/LockScreen/WallpaperRefresher.swift
public protocol WallpaperRefreshing: Sendable { func refresh() throws }

public enum TransactionFaultPoint: Sendable {
    case afterPreparedJournal
    case afterVideoReplacement
    case afterIndexReplacement
    case afterPosterReplacement
    case beforeCommit
}

public protocol FaultInjecting: Sendable { func hit(_ point: TransactionFaultPoint) throws }
public struct NoFaults: FaultInjecting { public init() {}; public func hit(_ point: TransactionFaultPoint) throws {} }
```

- [ ] **Step 5: Implement the transaction state machine**

`LockScreenTransaction.install(_:)` performs these exact transitions:

1. Reject `MacOSGeneration.unsupported` before any directory creation.
2. Discover the exact requested slot and reject foreign modifications.
3. Verify input files exist and compute their hashes.
4. Read `Index.plist` and plan mutations before changing any file.
5. Create primary and recovery video backups; verify both hashes equal the original slot hash. If `lockscreen.png` exists, create a separate poster backup and verify its hash before any replacement.
6. Write the manifest as `.prepared` and call `faults.hit(.afterPreparedJournal)`.
7. Update the same manifest to `.writing` before the first replacement.
8. Replace the slot from a same-directory prepared copy; verify installed hash; hit `.afterVideoReplacement`.
9. Apply and atomically replace `Index.plist`; re-read it; hit `.afterIndexReplacement`.
10. Replace the poster from a same-directory prepared copy; verify installed hash; hit `.afterPosterReplacement`.
11. Refresh the two wallpaper processes through `WallpaperRefreshing`; hit `.beforeCommit`.
12. Mark and durably write `.committed` only after every verification succeeds.

Use an initializer that exposes every dependency and no singleton:

```swift
public struct LockScreenTransaction: Sendable {
    public init(
        paths: AerialPaths,
        files: any FileStore,
        digester: any Digesting,
        journals: AtomicJSONStore,
        discovery: AerialDiscovery,
        patcher: WallpaperIndexPatcher,
        refresher: any WallpaperRefreshing,
        faults: any FaultInjecting = NoFaults(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    )
    public func install(_ request: LockScreenTransactionRequest) throws -> LockScreenTransactionManifest
}
```

- [ ] **Step 6: Run the transaction tests and commit**

Run: `swift test --filter LockScreenTransactionTests`

Expected: successful install commits after one refresh; injected failure leaves a readable `.writing` journal and both verified backups.

```bash
git add Sources/WallumeCore/LockScreen Tests/WallumeCoreTests/LockScreenTransactionTests.swift
git commit -m "feat: add durable lock-screen install transaction"
```

---

### Task 7: Add compare-and-restore recovery and orphan handling

**Files:**
- Create: `Sources/WallumeCore/LockScreen/RecoveryCoordinator.swift`
- Create: `Tests/WallumeCoreTests/RecoveryCoordinatorTests.swift`

**Interfaces:**
- Produces: `RecoveryCoordinator.inspect() -> [RecoveryCandidate]`
- Produces: `RecoveryCoordinator.restore(id:) -> RecoveryReport`
- Produces: `RecoveryReport { restored, conflicts, retainedBackups }`
- Consumes: transaction manifest, file store, digester, patcher, refresher

- [ ] **Step 1: Write a failing clean recovery test**

```swift
// Tests/WallumeCoreTests/RecoveryCoordinatorTests.swift
import XCTest
@testable import WallumeCore

final class RecoveryCoordinatorTests: XCTestCase {
    func testRestoresEveryOwnedValueWhenCurrentHashesStillMatchInstalledHashes() throws {
        let fixture = try RecoveryFixture.installed()
        let report = try fixture.recovery.restore(id: fixture.manifest.id)
        XCTAssertEqual(report.conflicts, [])
        XCTAssertTrue(report.restored.contains(fixture.manifest.video.target))
        XCTAssertTrue(report.restored.contains(fixture.manifest.poster.target))
        XCTAssertEqual(try fixture.digest.sha256(of: fixture.manifest.video.target), fixture.manifest.video.originalHash)
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
    }
}
```

- [ ] **Step 2: Write failing conflict preservation tests**

```swift
func testDoesNotOverwriteSystemRedownloadOrExternalIndexChange() throws {
    let fixture = try RecoveryFixture.installed()
    try fixture.files.writeAtomically(Data("system-redownload".utf8), to: fixture.manifest.video.target)
    try fixture.externallyChangeIndex()
    let report = try fixture.recovery.restore(id: fixture.manifest.id)
    XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
    XCTAssertEqual(String(data: try fixture.files.read(fixture.manifest.video.target), encoding: .utf8), "system-redownload")
    XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    XCTAssertTrue(report.retainedBackups.contains(fixture.manifest.recoveryBackup))
}
```

- [ ] **Step 3: Run and verify recovery symbols are missing**

Run: `swift test --filter RecoveryCoordinatorTests`

Expected: compilation fails because `RecoveryCoordinator` does not exist.

- [ ] **Step 4: Implement recovery with ownership comparisons**

```swift
// Sources/WallumeCore/LockScreen/RecoveryCoordinator.swift
import Foundation

public struct RecoveryCandidate: Equatable, Sendable {
    public let id: UUID
    public let phase: TransactionPhase
    public let aerialID: String
    public let createdAt: Date
}

public struct RecoveryReport: Equatable, Sendable {
    public let restored: [URL]
    public let conflicts: [URL]
    public let retainedBackups: [URL]
}

public struct RecoveryCoordinator: Sendable {
    public init(
        paths: AerialPaths,
        files: any FileStore,
        digester: any Digesting,
        journals: AtomicJSONStore,
        patcher: WallpaperIndexPatcher,
        refresher: any WallpaperRefreshing
    )
    public func inspect() throws -> [RecoveryCandidate]
    public func restore(id: UUID) throws -> RecoveryReport
}
```

The implementation must enforce these rules independently for the video, poster, and each plist mutation:

- Restore a file only when its current hash equals `installedHash`.
- When the current hash differs, record a conflict and do not touch the target.
- When `originalHash` and `originalBackup` exist, restore from that verified backup.
- When both are absent, the target did not exist before Wallume; remove it only when its current hash equals `installedHash`.
- Restore a plist mutation only when the current fragment equals its `after` fragment.
- Keep all backups when any conflict exists.
- Delete video and poster backups only after every owned value restored and the restored hashes match the manifest's original hashes.
- Mark the manifest `.restored` on clean recovery and `.conflicted` on any conflict.
- Refresh only if at least one target was actually restored.

- [ ] **Step 5: Run recovery and complete-suite tests**

Run: `swift test --filter RecoveryCoordinatorTests && swift test`

Expected: recovery tests and every earlier suite pass.

- [ ] **Step 6: Commit recovery**

```bash
git add Sources/WallumeCore/LockScreen/RecoveryCoordinator.swift Tests/WallumeCoreTests/RecoveryCoordinatorTests.swift
git commit -m "feat: add compare-and-restore recovery"
```

---

### Task 8: Ship the standalone read-only/status and explicit restore CLI

**Files:**
- Modify: `Sources/WallumeRestore/main.swift`
- Create: `Tests/WallumeCoreTests/RestoreCommandTests.swift`
- Create: `Sources/WallumeCore/LockScreen/RestoreCommand.swift`

**Interfaces:**
- Produces: `RestoreCommand.run(arguments:environment:) -> Int32`
- CLI commands: `status`, `restore <transaction-uuid>`, `restore-all`
- Consumes: `RecoveryCoordinator`

- [ ] **Step 1: Write failing command parsing tests**

```swift
// Tests/WallumeCoreTests/RestoreCommandTests.swift
import XCTest
@testable import WallumeCore

final class RestoreCommandTests: XCTestCase {
    func testNoArgumentsPrintsUsageWithoutWriting() {
        let output = BufferedOutput()
        let command = RestoreCommand(recovery: .fixtureEmpty, output: output)
        XCTAssertEqual(command.run(arguments: []), 64)
        XCTAssertEqual(output.stderr, "usage: wallume-restore status | restore <transaction-uuid> | restore-all\n")
    }

    func testStatusListsOrphanedWritingTransaction() throws {
        let fixture = try RecoveryFixture.writing()
        let output = BufferedOutput()
        let command = RestoreCommand(recovery: fixture.recovery, output: output)
        XCTAssertEqual(command.run(arguments: ["status"]), 0)
        XCTAssertTrue(output.stdout.contains(fixture.manifest.id.uuidString))
        XCTAssertTrue(output.stdout.contains("writing"))
    }
}
```

- [ ] **Step 2: Run and verify the command type is missing**

Run: `swift test --filter RestoreCommandTests`

Expected: compilation fails because `RestoreCommand` does not exist.

- [ ] **Step 3: Implement dependency-injected command parsing**

```swift
// Sources/WallumeCore/LockScreen/RestoreCommand.swift
import Foundation

public protocol RestoreOutput: AnyObject {
    func writeStdout(_ text: String)
    func writeStderr(_ text: String)
}

public struct RestoreCommand {
    private let recovery: RecoveryCoordinator
    private weak var output: (any RestoreOutput)?

    public init(recovery: RecoveryCoordinator, output: any RestoreOutput) {
        self.recovery = recovery
        self.output = output
    }

    public func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            output?.writeStderr("usage: wallume-restore status | restore <transaction-uuid> | restore-all\n")
            return 64
        }
        do {
            switch command {
            case "status":
                for candidate in try recovery.inspect() {
                    output?.writeStdout("\(candidate.id.uuidString) \(candidate.phase.rawValue) \(candidate.aerialID)\n")
                }
                return 0
            case "restore" where arguments.count == 2:
                guard let id = UUID(uuidString: arguments[1]) else { return 64 }
                return try recovery.restore(id: id).conflicts.isEmpty ? 0 : 2
            case "restore-all":
                var hadConflict = false
                for candidate in try recovery.inspect() {
                    hadConflict = try !recovery.restore(id: candidate.id).conflicts.isEmpty || hadConflict
                }
                return hadConflict ? 2 : 0
            default:
                output?.writeStderr("usage: wallume-restore status | restore <transaction-uuid> | restore-all\n")
                return 64
            }
        } catch {
            output?.writeStderr("wallume-restore: \(error)\n")
            return 1
        }
    }
}
```

- [ ] **Step 4: Wire the executable to the live home directory without adding write-on-launch behavior**

`main.swift` must obtain the current home directory, obtain `GeneratedUID` through a small Foundation `Process` call to `/usr/bin/dscl`, construct `AerialPaths`, and create production dependencies. It must not inspect or write anything until `RestoreCommand` receives an explicit command. `status` is read-only; `restore` and `restore-all` are explicit write commands.

Use `ProcessOutput` implementing `RestoreOutput` with `FileHandle.standardOutput` and `.standardError`. Exit with the exact value returned by `RestoreCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))`.

- [ ] **Step 5: Test, build, and manually verify help against an isolated HOME**

Run:

```bash
swift test --filter RestoreCommandTests
swift build -c release --product wallume-restore
HOME="$(mktemp -d)" .build/release/wallume-restore status
```

Expected: tests pass, release build succeeds, and isolated status exits successfully with no output and no created files.

- [ ] **Step 6: Commit the standalone recovery tool**

```bash
git add Sources/WallumeCore/LockScreen/RestoreCommand.swift Sources/WallumeRestore/main.swift Tests/WallumeCoreTests/RestoreCommandTests.swift
git commit -m "feat: add standalone lock-screen recovery tool"
```

---

### Task 9: Add read-only live probe, CI, and phase-1 safety documentation

**Files:**
- Create: `Sources/WallumeCore/LockScreen/LockScreenProbe.swift`
- Create: `Tests/WallumeCoreTests/LockScreenProbeTests.swift`
- Create: `.github/workflows/ci.yml`
- Create: `docs/lock-screen-safety.md`
- Modify: `Sources/WallumeRestore/main.swift`

**Interfaces:**
- Produces: `LockScreenProbe.inspect(paths:version:) -> LockScreenProbeReport`
- Extends CLI with read-only `probe`
- Consumes: discovery, version routing, `FileStore`

- [ ] **Step 1: Write a failing probe test for unknown systems and foreign backups**

```swift
// Tests/WallumeCoreTests/LockScreenProbeTests.swift
import XCTest
@testable import WallumeCore

final class LockScreenProbeTests: XCTestCase {
    func testUnknownVersionReportsReadOnlyAndNeverCreatesDirectories() throws {
        let fixture = try AerialFixture.make()
        let report = try LockScreenProbe(files: fixture.files).inspect(
            paths: fixture.paths,
            version: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertFalse(report.writesPermitted)
        XCTAssertEqual(report.generation, .unsupported(27))
        XCTAssertFalse(fixture.files.exists(fixture.paths.transactionsDirectory))
    }
}
```

- [ ] **Step 2: Implement a report-only probe**

```swift
// Sources/WallumeCore/LockScreen/LockScreenProbe.swift
import Foundation

public struct LockScreenProbeReport: Equatable, Sendable {
    public let generation: MacOSGeneration
    public let writesPermitted: Bool
    public let manifestExists: Bool
    public let indexExists: Bool
    public let availableSlots: [AerialSlot]
    public let foreignBackupNames: [String]
}

public struct LockScreenProbe: Sendable {
    private let files: any FileStore
    public init(files: any FileStore) { self.files = files }
    public func inspect(paths: AerialPaths, version: OperatingSystemVersion) throws -> LockScreenProbeReport
}
```

The implementation only calls `exists`, `read`, and `contents`. Add the `probe` CLI command and print generation, write permission, paths found, slot IDs, and foreign backup filenames. Never print video contents or unrelated paths.

- [ ] **Step 3: Run the complete suite and live read-only probe**

Run:

```bash
swift test
swift build -c release --product wallume-restore
.build/release/wallume-restore probe
git diff --check
```

Expected:

- all tests pass;
- the probe reports the current system generation and discovered slots;
- the probe does not change mtimes or create Wallume directories;
- `git diff --check` prints nothing.

Before and after the probe, record hashes for the live `Index.plist` and discovered `.mov` slots and assert they are identical. Do not run `restore` or install against the live system during this task.

- [ ] **Step 4: Add arm64 GitHub Actions**

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  swift:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select arm64 architecture
        run: test "$(uname -m)" = arm64
      - name: Build
        run: swift build -c release
      - name: Test
        run: swift test
      - name: Whitespace check
        run: git diff --check
```

The workflow fails if the runner is not native `arm64`; do not silently run x86_64 under Rosetta. GitHub's hosted-runner reference identifies `macos-15` as an arm64 M1 label.

- [ ] **Step 5: Document ownership and recovery invariants**

`docs/lock-screen-safety.md` must include:

- the four observed system paths;
- the fact that paths are private and version-gated;
- files Wallume may read and files Wallume may write;
- the explicit-slot requirement;
- transaction phases and crash behavior;
- hash-based compare-and-restore rules;
- why manual app deletion has no callback;
- `wallume-restore status`, `probe`, `restore`, and `restore-all` examples;
- the rule that backups survive until a verified clean restoration;
- a warning that live installation testing is outside automated tests and requires a dedicated downloaded Aerial slot.

- [ ] **Step 6: Run phase-1 acceptance and commit**

Run:

```bash
swift test
swift build -c release
git diff --check
git status --short
```

Expected: all tests/builds pass; only the probe, CI, and documentation files are uncommitted.

```bash
git add Sources Tests .github/workflows/ci.yml docs/lock-screen-safety.md
git commit -m "test: complete lock-screen safety foundation"
```

## Phase-1 Acceptance Checklist

- [ ] `swift test` passes without reading or writing live wallpaper data.
- [ ] Unknown macOS majors cannot create directories or perform writes.
- [ ] Slot selection requires an explicit manifest-backed Aerial UUID.
- [ ] Foreign backup markers prevent installation.
- [ ] Every install creates and verifies both backups before replacement.
- [ ] A failure at every injected fault point leaves a readable journal and recoverable backups.
- [ ] Restore changes only values whose current hashes/fragments still equal Wallume-installed values.
- [ ] External/system changes produce conflicts and are never overwritten.
- [ ] Backups are retained whenever a conflict exists.
- [ ] `wallume-restore` builds independently of the future application target.
- [ ] The live `probe` is demonstrably read-only by before/after hashes.
- [ ] CI builds and tests natively on Apple Silicon.
