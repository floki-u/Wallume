import Foundation
import XCTest
@testable import WallumeCore

final class MediaImporterTests: XCTestCase {
    func testDuplicateReturnsExistingItemWithoutCallingTranscoder() async throws {
        let fixture = try MediaImporterFixture()
        defer { fixture.remove() }
        let existing = try fixture.registerExisting(hash: fixture.sourceHash)

        let report = try await fixture.importer.importURLs([fixture.source])

        XCTAssertEqual(report.results.count, 1)
        XCTAssertEqual(report.results.first?.status, .duplicate)
        XCTAssertEqual(report.results.first?.item?.id, existing.id)
        XCTAssertEqual(fixture.transcoder.calls, 0)
    }

    func testFailedArtworkLeavesNoIndexOrOwnedArtifacts() async throws {
        let fixture = try MediaImporterFixture()
        defer { fixture.remove() }
        fixture.artwork.error = SyntheticMediaError()

        let report = try await fixture.importer.importURLs([fixture.source])

        XCTAssertEqual(report.results.first?.status, .failed)
        XCTAssertTrue(try fixture.library.list().isEmpty)
        XCTAssertTrue(try fixture.workDirectoryIsEmpty())
        XCTAssertFalse(fixture.store.exists(fixture.paths.variant(id: fixture.nextID)))
        XCTAssertFalse(fixture.store.exists(fixture.paths.thumbnail(id: fixture.nextID)))
        XCTAssertFalse(fixture.store.exists(fixture.paths.cover(id: fixture.nextID)))
    }

    func testDirectoryImportKeepsStableOrderAndContinuesAfterFailure() async throws {
        let fixture = try MediaImporterFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appending(path: "incoming")
        try fixture.store.createDirectory(directory)
        let ignored = directory.appending(path: "ignored.txt")
        let nested = directory.appending(path: "nested")
        try fixture.store.createDirectory(nested)
        let a = directory.appending(path: "a.mov")
        let b = directory.appending(path: "b.mp4")
        let c = nested.appending(path: "c.mov")
        try fixture.store.writeAtomically(Data("a".utf8), to: a)
        try fixture.store.writeAtomically(Data("b".utf8), to: b)
        try fixture.store.writeAtomically(Data("c".utf8), to: c)
        try fixture.store.writeAtomically(Data("ignored".utf8), to: ignored)
        fixture.inspector.failures.insert(b)

        let report = try await fixture.importer.importURLs([directory])

        XCTAssertEqual(report.results.map(\.source.lastPathComponent), ["a.mov", "b.mp4", "c.mov"])
        XCTAssertEqual(report.results.map(\.status), [.imported, .failed, .imported])
        XCTAssertEqual(try fixture.library.list().map(\.sourceURL.lastPathComponent), ["a.mov", "c.mov"])
    }

    func testCancellationIsReportedAndBatchContinues() async throws {
        let fixture = try MediaImporterFixture()
        defer { fixture.remove() }
        let cancelled = fixture.root.appending(path: "cancelled.mov")
        let imported = fixture.root.appending(path: "imported.mov")
        try fixture.store.writeAtomically(Data("cancelled".utf8), to: cancelled)
        try fixture.store.writeAtomically(Data("imported".utf8), to: imported)
        fixture.transcoder.cancelledSources.insert(cancelled)

        let report = try await fixture.importer.importURLs([cancelled, imported])

        XCTAssertEqual(report.results.map(\.status), [.cancelled, .imported])
        XCTAssertEqual(try fixture.library.list().map(\.sourceURL.lastPathComponent), ["imported.mov"])
    }

    func testImportedItemStoresVariantMediaMetadata() async throws {
        let fixture = try MediaImporterFixture()
        defer { fixture.remove() }
        fixture.inspector.sourceCodec = "avc1"
        fixture.inspector.variantCodec = "hvc1"
        fixture.inspector.variantWidth = 1280
        fixture.inspector.variantHeight = 720

        let report = try await fixture.importer.importURLs([fixture.source])

        let item = try XCTUnwrap(report.results.first?.item)
        XCTAssertEqual(item.codec, "hvc1")
        XCTAssertEqual(item.pixelWidth, 1280)
        XCTAssertEqual(item.pixelHeight, 720)
        XCTAssertEqual(item.sourceByteCount, Int64(Data("source".utf8).count))
    }
}

private final class MediaImporterFixture {
    let root: URL
    let store = LocalFileStore()
    let paths: MediaPaths
    let library: MediaLibrary
    let digest = SHA256Digester()
    let inspector = FakeMediaInspector()
    let transcoder = FakeMediaTranscoder()
    let artwork = FakeArtworkGenerator()
    let nextID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let source: URL
    let sourceHash: String
    let importer: MediaImporter

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path) : temporary
        root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = MediaPaths(
            homeDirectory: root.appending(path: "home"),
            cacheDirectory: root.appending(path: "cache")
        )
        source = root.appending(path: "source.mov")
        try store.writeAtomically(Data("source".utf8), to: source)
        sourceHash = try digest.sha256(of: source)
        library = MediaLibrary(
            paths: paths,
            files: store,
            jsonStore: AtomicJSONStore(files: store),
            digester: digest
        )
        let generatedID = nextID
        importer = MediaImporter(
            paths: paths,
            files: store,
            library: library,
            digester: digest,
            inspector: inspector,
            transcoder: transcoder,
            artwork: artwork,
            idGenerator: { generatedID },
            date: { Date(timeIntervalSince1970: 0) }
        )
    }

    func registerExisting(hash: String) throws -> MediaItem {
        let item = MediaItem(
            id: UUID(),
            sourceHash: hash,
            sourceURL: source,
            displayName: "Existing",
            sourceByteCount: 6,
            pixelWidth: 1920,
            pixelHeight: 1080,
            frameRate: 30,
            durationSeconds: 1,
            codec: "hvc1",
            variantURL: paths.variant(id: UUID()),
            thumbnailURL: paths.thumbnail(id: UUID()),
            coverURL: paths.cover(id: UUID()),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try library.register(item)
        return item
    }

    func workDirectoryIsEmpty() throws -> Bool {
        guard store.exists(paths.importWorkRoot) else { return true }
        return try store.contents(paths.importWorkRoot).isEmpty
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FakeMediaInspector: MediaInspecting, @unchecked Sendable {
    var failures = Set<URL>()
    var sourceCodec = "hvc1"
    var variantCodec = "hvc1"
    var variantWidth = 1920
    var variantHeight = 1080

    func inspect(_ url: URL) async throws -> MediaInspection {
        if failures.contains(url) { throw SyntheticMediaError() }
        let isVariant = url.lastPathComponent == "variant.mov"
        let count = Int64((try? Data(contentsOf: url).count) ?? 0)
        return MediaInspection(
            sourceByteCount: count,
            pixelWidth: isVariant ? variantWidth : 1920,
            pixelHeight: isVariant ? variantHeight : 1080,
            frameRate: 30,
            durationSeconds: 1,
            codec: isVariant ? variantCodec : sourceCodec
        )
    }
}

private final class FakeMediaTranscoder: MediaTranscoding, @unchecked Sendable {
    var calls = 0
    var cancelledSources = Set<URL>()

    func transcode(
        _ source: URL,
        to destination: URL,
        policy: MediaTranscodePolicy,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        calls += 1
        if cancelledSources.map(\.standardizedFileURL).contains(source.standardizedFileURL) {
            throw CancellationError()
        }
        progress?(1)
        try Data("variant-\(source.lastPathComponent)".utf8).write(to: destination)
    }
}

private final class FakeArtworkGenerator: ArtworkGenerating, @unchecked Sendable {
    var error: Error?

    func generateArtwork(for variant: URL, thumbnail: URL, cover: URL) async throws {
        if let error { throw error }
        try Data("thumbnail".utf8).write(to: thumbnail)
        try Data("cover".utf8).write(to: cover)
    }
}

private struct SyntheticMediaError: Error {}
