# Wallume Media Library And Importer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable media library and a `wallume-media` CLI that imports `.mp4` and `.mov` files into one verified HEVC `hvc1` variant per unique source.

**Architecture:** `WallumeCore` owns media models, allowed paths, atomic JSON indexing, import transaction rules, and injected media adapters. AVFoundation and VideoToolbox adapters inspect, transform, and create artwork; the executable only maps CLI arguments to the reusable core API. Each import stages all owned files under `ImportWork`, installs them into Wallume-owned locations, then atomically registers one `MediaItem` as the commit point.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, CryptoKit, AVFoundation, VideoToolbox, XCTest, macOS 14+, Apple Silicon.

## Global Constraints

- Product name is `Wallume`; Bundle ID is `app.wallume.Wallume`.
- Target Apple Silicon only; deployment target is macOS 14.
- Use pure Swift and Apple frameworks; do not add Python, ffmpeg, or third-party packages.
- The importer accepts only `.mp4` and `.mov` files with a readable video track.
- Each successful media item owns one `.mov` HEVC `hvc1` variant with longest edge at most 3840 and frame rate at most 60.
- Wallume never moves, copies into `Originals`, modifies, or deletes the source file.
- Source SHA-256 is the sole duplicate identity; duplicate imports return the original item without new files.
- Media writes use same-directory staging, verification, and atomic replacement; `library.json` is the sole media-index authority.
- `remove` may delete only regular files inside Wallume-owned media and cache directories, and must reject symlinked or outside paths.
- Tests use temporary directories and injected adapters. A small local AVFoundation fixture may validate the production adapter, but no test may touch live wallpaper data.
- Commit author is `floki-u <117898635+floki-u@users.noreply.github.com>`.

## File Map

```text
Package.swift                                  Add wallume-media executable and Apple media framework links
Sources/WallumeCore/Media/MediaModels.swift    Codable library schema, media metadata, outcomes, errors
Sources/WallumeCore/Media/MediaPaths.swift     Derived owned library, cache, and work paths
Sources/WallumeCore/Media/MediaLibrary.swift   Atomic index loading, SHA-256 lookup, registration, safe deletion
Sources/WallumeCore/Media/MediaImporting.swift Candidate expansion and injected transactional import coordinator
Sources/WallumeCore/Media/AVFoundationMedia.swift Production inspect/transcode/artwork implementations
Sources/WallumeMedia/main.swift                 CLI argument parsing and live dependency wiring
Tests/WallumeCoreTests/MediaLibraryTests.swift  Schema, duplicate lookup, registration, removal, path safety
Tests/WallumeCoreTests/MediaImporterTests.swift Candidate sorting, failure cleanup, partial batches, cancellation
Tests/WallumeCoreTests/AVFoundationMediaTests.swift Real local media inspection/output verification
Tests/WallumeCoreTests/MediaCommandTests.swift  CLI parse/output/exit semantics with injected dependencies
docs/media-library.md                           User-facing CLI and media ownership guidance
```

---

### Task 1: Add the media package surface, models, and owned paths

**Files:**
- Modify: `Package.swift`
- Create: `Sources/WallumeCore/Media/MediaModels.swift`
- Create: `Sources/WallumeCore/Media/MediaPaths.swift`
- Create: `Sources/WallumeMedia/main.swift`
- Create: `Tests/WallumeCoreTests/MediaPathsTests.swift`

**Interfaces:**
- Produces `MediaItem`, `MediaLibraryDocument`, `MediaImportStatus`, and `MediaImportError`.
- Produces `MediaPaths(homeDirectory:cacheDirectory:)` with URLs for the index, variants, thumbnails, covers, and import work.
- Produces the `wallume-media` executable target, with no behavior beyond a temporary usage exit until Task 5.

- [ ] **Step 1: Write failing model and path tests**

```swift
func testMediaPathsStayUnderWallumeOwnedRoots() throws {
    let root = try makeTemporaryDirectory()
    let paths = MediaPaths(homeDirectory: root.appending(path: "home"), cacheDirectory: root.appending(path: "cache"))
    XCTAssertEqual(paths.libraryIndex.path, root.appending(path: "home/Library/Application Support/Wallume/Library/library.json").path)
    XCTAssertEqual(paths.variant(id: UUID()).pathExtension, "mov")
    XCTAssertTrue(paths.importWork(id: UUID()).path.hasPrefix(paths.importWorkRoot.path))
}

func testMediaItemRoundTripsWithSchemaTwo() throws {
    let item = MediaItem.fixture()
    let encoded = try JSONEncoder().encode(MediaLibraryDocument(items: [item]))
    XCTAssertEqual(try JSONDecoder().decode(MediaLibraryDocument.self, from: encoded).schemaVersion, 2)
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `swift test --filter MediaPathsTests`

Expected: compilation fails because `MediaPaths` and `MediaItem` do not exist.

- [ ] **Step 3: Add the package target and minimal types**

```swift
public struct MediaLibraryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public var items: [MediaItem]

    public init(items: [MediaItem] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.items = items
    }
}

public struct MediaItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceHash: String
    public let sourceURL: URL
    public let displayName: String
    public let sourceByteCount: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameRate: Double
    public let durationSeconds: Double
    public let codec: String
    public let variantURL: URL
    public let thumbnailURL: URL
    public let coverURL: URL
    public let createdAt: Date
}

public enum MediaImportStatus: String, Codable, Sendable {
    case imported, duplicate, skipped, failed, cancelled
}

public struct MediaPaths: Sendable {
    public let libraryIndex: URL
    public let variantsDirectory: URL
    public let thumbnailsDirectory: URL
    public let coversDirectory: URL
    public let importWorkRoot: URL
    public func variant(id: UUID) -> URL { variantsDirectory.appending(path: "\(id.uuidString).mov") }
}
```

Add an executable product/target named `wallume-media`, dependent on `WallumeCore`, and add `AVFoundation`/`VideoToolbox` only to the core target linker settings needed in Task 4.

- [ ] **Step 4: Run the focused tests and full suite**

Run: `swift test --filter MediaPathsTests && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/WallumeCore/Media/MediaModels.swift Sources/WallumeCore/Media/MediaPaths.swift Sources/WallumeMedia/main.swift Tests/WallumeCoreTests/MediaPathsTests.swift
git commit -m "feat: add media models and paths"
```

### Task 2: Implement the atomic media index and safe owned-file removal

**Files:**
- Create: `Sources/WallumeCore/Media/MediaLibrary.swift`
- Create: `Tests/WallumeCoreTests/MediaLibraryTests.swift`

**Interfaces:**
- Consumes `MediaLibraryDocument`, `MediaItem`, `MediaPaths`, `FileStore`, `Digester`, `AtomicJSONStore`, and `PathSafetyValidator`.
- Produces `MediaLibrary.find(sourceHash:)`, `MediaLibrary.list()`, `MediaLibrary.item(id:)`, `MediaLibrary.register(_:)`, and `MediaLibrary.remove(id:)`.

- [ ] **Step 1: Write failing duplicate, atomic-registration, and removal tests**

```swift
func testRegisterFindsDuplicateBySourceHash() throws {
    let item = MediaItem.fixture(sourceHash: "a".repeating(64))
    try library.register(item)
    XCTAssertEqual(try library.find(sourceHash: item.sourceHash)?.id, item.id)
}

func testRemoveRejectsOutsideVariantWithoutDeletingIt() throws {
    let outside = fixture.root.appending(path: "outside.mov")
    try fixture.store.write(Data("keep".utf8), to: outside)
    try fixture.writeIndex(containing: .fixture(variantPath: outside.path))
    XCTAssertThrowsError(try fixture.library.remove(id: fixture.item.id))
    XCTAssertEqual(try fixture.store.readData(from: outside), Data("keep".utf8))
}
```

- [ ] **Step 2: Run the tests and verify failure**

Run: `swift test --filter MediaLibraryTests`

Expected: compilation fails because `MediaLibrary` does not exist.

- [ ] **Step 3: Implement index operations using the existing durable JSON store**

```swift
public func register(_ item: MediaItem) throws {
    var document = try loadDocument()
    guard document.items.allSatisfy({ $0.sourceHash != item.sourceHash }) else { return }
    document.items.append(item)
    try jsonStore.write(document, to: paths.libraryIndex)
}

public func remove(id: UUID) throws {
    var document = try loadDocument()
    guard let item = document.items.first(where: { $0.id == id }) else { throw MediaImportError.notFound(id) }
    try removeOwnedArtifacts(for: item)
    document.items.removeAll { $0.id == id }
    try jsonStore.write(document, to: paths.libraryIndex)
}
```

Validate each artifact path is a regular file if present, lies under its expected owned root, and has no symlinked parent before unlinking. Treat missing owned artifacts as already removed.

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter MediaLibraryTests && swift test && git diff --check`

Expected: all commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore/Media/MediaLibrary.swift Tests/WallumeCoreTests/MediaLibraryTests.swift
git commit -m "feat: add atomic media library"
```

### Task 3: Add candidate expansion and injected import transaction semantics

**Files:**
- Create: `Sources/WallumeCore/Media/MediaImporting.swift`
- Create: `Tests/WallumeCoreTests/MediaImporterTests.swift`

**Interfaces:**
- Produces `MediaInspecting`, `MediaTranscoding`, `ArtworkGenerating`, `MediaImporter`, `MediaImportResult`, and `MediaImportReport`.
- `MediaImporter.importURLs(_:)` returns one ordered result per supported candidate and never stops a batch after an individual failure.

- [ ] **Step 1: Write failing transaction tests using injected fakes**

```swift
func testDuplicateReturnsExistingItemWithoutCallingTranscoder() async throws {
    let existing = try fixture.registerExisting(hash: fixture.sourceHash)
    let result = try await fixture.importer.importURLs([fixture.source])
    XCTAssertEqual(result.results, [.duplicate(existing.id)])
    XCTAssertEqual(fixture.transcoder.calls, 0)
}

func testFailedArtworkLeavesNoIndexOrOwnedArtifacts() async throws {
    fixture.artwork.error = .synthetic
    let report = try await fixture.importer.importURLs([fixture.source])
    XCTAssertEqual(report.results.first?.status, .failed)
    XCTAssertTrue(try fixture.library.list().isEmpty)
    XCTAssertTrue(try fixture.workDirectoryIsEmpty())
}
```

- [ ] **Step 2: Run and verify the tests fail**

Run: `swift test --filter MediaImporterTests`

Expected: compilation fails because the import protocols and coordinator do not exist.

- [ ] **Step 3: Implement a serial actor coordinator with an explicit commit point**

```swift
public actor MediaImporter {
    public func importURLs(_ urls: [URL]) async throws -> MediaImportReport {
        let candidates = try expandAndSort(urls)
        var results: [MediaImportResult] = []
        for candidate in candidates { results.append(await importOne(candidate)) }
        return MediaImportReport(results: results)
    }
}
```

For each new source: hash, check `MediaLibrary.find`, inspect, write all artifacts in a task work directory, verify them, atomically install them, register the item, and remove all task-owned artifacts if registration does not commit. Convert adapter cancellation into `.cancelled`; convert other per-file errors into `.failed`; do not convert batch-wide programmer or index-corruption errors into a false success.

- [ ] **Step 4: Add tests for stable recursive order, cancellation, and partial success**

```swift
func testDirectoryImportKeepsStableOrderAndContinuesAfterFailure() async throws {
    let report = try await fixture.importer.importURLs([fixture.directory])
    XCTAssertEqual(report.results.map(\.source.lastPathComponent), ["a.mov", "b.mp4", "c.mov"])
    XCTAssertEqual(report.results.map(\.status), [.imported, .failed, .imported])
}
```

- [ ] **Step 5: Run focused and full tests, then commit**

Run: `swift test --filter MediaImporterTests && swift test && git diff --check`

```bash
git add Sources/WallumeCore/Media/MediaImporting.swift Tests/WallumeCoreTests/MediaImporterTests.swift
git commit -m "feat: add transactional media importer"
```

### Task 4: Implement and verify AVFoundation media adapters

**Files:**
- Create: `Sources/WallumeCore/Media/AVFoundationMedia.swift`
- Create: `Tests/WallumeCoreTests/AVFoundationMediaTests.swift`

**Interfaces:**
- Produces `AVFoundationMediaInspector`, `AVFoundationMediaTranscoder`, and `AVFoundationArtworkGenerator` conforming to Task 3 protocols.
- Produces a readable HEVC `hvc1` `.mov`, capped at 3840 pixels and 60 fps, plus JPEG thumbnail and cover files.

- [ ] **Step 1: Write failing local-media verification tests**

```swift
func testTranscodedOutputIsReadableHVC1MovWithinLimits() async throws {
    let output = fixture.root.appending(path: "output.mov")
    try await fixture.transcoder.transcode(fixture.input, to: output, policy: .singleVariant)
    let metadata = try await fixture.inspector.inspect(output)
    XCTAssertEqual(metadata.container, .mov)
    XCTAssertEqual(metadata.codec, .hvc1)
    XCTAssertLessThanOrEqual(max(metadata.pixelSize.width, metadata.pixelSize.height), 3840)
    XCTAssertLessThanOrEqual(metadata.frameRate, 60)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter AVFoundationMediaTests`

Expected: compilation fails because the production adapter does not exist.

- [ ] **Step 3: Implement inspection, export, and artwork generation**

Use `AVURLAsset` to load tracks and `AVAssetReader`/`AVAssetWriter` or an explicitly configured export session to produce HEVC video with `kCMVideoCodecType_HEVC` and an `hvc1`-compatible `.mov` file. Compute the capped output size with aspect ratio preserved, cap the frame cadence at 60, and propagate cancellation by cancelling the export/reader-writer operation and deleting its partial output. Generate JPEG images from `AVAssetImageGenerator` only after the output reopens successfully.

- [ ] **Step 4: Add failure and cancellation tests**

```swift
func testInspectorRejectsAudioOnlyAsset() async throws {
    await XCTAssertThrowsErrorAsync(try await fixture.inspector.inspect(fixture.audioOnlyInput))
}
```

Ensure generated output and images are validated by reopening them before the importer can commit.

- [ ] **Step 5: Run all media tests and commit**

Run: `swift test --filter AVFoundationMediaTests && swift test && swift build -c release`

```bash
git add Sources/WallumeCore/Media/AVFoundationMedia.swift Tests/WallumeCoreTests/AVFoundationMediaTests.swift
git commit -m "feat: add AVFoundation media adapters"
```

### Task 5: Add the `wallume-media` CLI and command tests

**Files:**
- Modify: `Sources/WallumeMedia/main.swift`
- Create: `Sources/WallumeCore/Media/MediaCommand.swift`
- Create: `Tests/WallumeCoreTests/MediaCommandTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces `MediaCommand.run(arguments:environment:output:) -> Int`.
- Supports `import`, `list`, `show <media-id>`, and `remove <media-id>`.
- Exit 0 means every requested operation succeeded or was a duplicate; exit 1 means at least one import result failed/cancelled; exit 64 means invalid syntax; exit 2 means an operational error for a read/remove command.

- [ ] **Step 1: Write failing parsing and output tests**

```swift
func testImportPrintsOrderedPerFileResultsAndReturnsOneForPartialFailure() async throws {
    let code = await fixture.command.run(arguments: ["import", "folder"], output: fixture.output)
    XCTAssertEqual(code, 1)
    XCTAssertEqual(fixture.output.lines, ["imported a.mov <id>", "failed b.mov unreadable"])
}

func testListAndShowAreReadOnly() async throws {
    XCTAssertEqual(await fixture.command.run(arguments: ["list"], output: fixture.output), 0)
    XCTAssertEqual(fixture.library.writeCount, 0)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter MediaCommandTests`

Expected: compilation fails because `MediaCommand` does not exist.

- [ ] **Step 3: Implement dependency-injected command parsing**

Keep Foundation process wiring in `main.swift`: derive home and cache directories from process environment, construct production adapters, write stdout/stderr, and call `exit(code)`. Keep command grammar and output formatting in `MediaCommand` so tests do not invoke the live filesystem or AVFoundation encoder.

- [ ] **Step 4: Add remove safety and malformed UUID tests**

```swift
func testRemoveRejectsMalformedUUIDWithoutCallingLibrary() async throws {
    XCTAssertEqual(await fixture.command.run(arguments: ["remove", "not-a-uuid"], output: fixture.output), 64)
    XCTAssertEqual(fixture.library.removeCalls, 0)
}
```

- [ ] **Step 5: Build, test, and commit**

Run: `swift test --filter MediaCommandTests && swift test && swift build -c release --product wallume-media && git diff --check`

```bash
git add Package.swift Sources/WallumeCore/Media/MediaCommand.swift Sources/WallumeMedia/main.swift Tests/WallumeCoreTests/MediaCommandTests.swift
git commit -m "feat: add media management CLI"
```

### Task 6: Document the media contract and complete phase-two acceptance

**Files:**
- Create: `docs/media-library.md`
- Modify: `docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Documents all CLI commands, owned directories, duplicate behavior, source-file guarantee, and manual real-media verification.
- CI verifies Apple Silicon architecture, all tests, release build of both executables, and whitespace.

- [ ] **Step 1: Write a documentation assertion list before editing prose**

```text
Commands: import, list, show, remove
Source ownership: source is never modified or deleted
Duplicate identity: complete source SHA-256
Owned data: one variant plus thumbnail and cover under Wallume roots
Failure rule: no half-registered item survives
```

- [ ] **Step 2: Write `docs/media-library.md` from the assertion list**

Include command examples, exit-code meanings, all Wallume-owned paths, a statement that `remove` never affects a source file, and the manual acceptance commands for checking codec, dimensions, and source hash before/after import.

- [ ] **Step 3: Extend CI and the project progress record**

Add `swift build -c release --product wallume-media` alongside the existing restore-tool build. Record phase-two completion only after all acceptance commands below are run successfully; preserve phase-one verification history.

- [ ] **Step 4: Run the full acceptance suite**

Run: `swift test && swift build -c release --product wallume-media && swift build -c release --product wallume-restore && git diff --check`

Expected: all commands exit 0 and `swift test` reports zero failures.

- [ ] **Step 5: Perform the manual real-media acceptance check**

Run `wallume-media import` against one disposable `.mp4` and one disposable `.mov`. Record source SHA-256 and metadata before import, then confirm both sources are unchanged, every successful variant opens through AVFoundation as HEVC `hvc1`, its longest edge is at most 3840, its frame rate is at most 60, and `wallume-media remove <id>` removes only Wallume-owned files.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml docs/media-library.md docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md
git commit -m "docs: complete media importer acceptance"
```

## Plan Self-Review

- Spec coverage: Tasks 1-2 deliver schema, owned paths, SHA-256 lookup, atomic indexing, and safe removal. Task 3 covers serial candidate expansion, duplicates, partial batches, cancellation, staging, and commit/cleanup. Task 4 covers real AVFoundation/VideoToolbox output and artwork. Task 5 delivers all approved CLI commands and exit codes. Task 6 covers CI, documentation, and manual acceptance.
- Placeholder scan: no tasks contain undecided scope or deferred implementation requirements.
- Type consistency: `MediaItem`, `MediaPaths`, `MediaLibrary`, and the three media adapter protocols are introduced before later tasks consume them; `wallume-media` only depends on the public core interfaces.
