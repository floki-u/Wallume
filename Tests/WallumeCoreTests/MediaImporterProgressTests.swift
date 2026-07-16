import Foundation
import XCTest
@testable import WallumeCore

final class MediaImporterProgressTests: XCTestCase {
    func testSingleImportReportsOrderedStagesAndTranscodeProgress() async throws {
        let fixture = try ProgressImporterFixture()
        defer { fixture.remove() }
        let events = LockedImportEvents()

        let result = await fixture.importer.importURL(fixture.source) { events.append($0) }

        XCTAssertEqual(result.status, .imported, result.message ?? "")
        XCTAssertEqual(events.values.compactMap(\.stage), [
            .hashing, .inspecting, .transcoding, .artwork, .committing, .cleanup,
        ])
        XCTAssertTrue(events.values.contains(.stage(.transcoding, progress: 0.5)))
    }

    func testCancelledSingleImportCleansWorkAndOwnedArtifactsBeforeReturning() async throws {
        let fixture = try ProgressImporterFixture()
        defer { fixture.remove() }
        fixture.transcoder.shouldCancel = true

        let result = await fixture.importer.importURL(fixture.source) { _ in }

        XCTAssertEqual(result.status, .cancelled, result.message ?? "")
        XCTAssertTrue(try fixture.workRootIsEmpty())
        XCTAssertTrue(try fixture.library.list().isEmpty)
        XCTAssertFalse(fixture.store.exists(fixture.paths.variant(id: fixture.id)))
    }

    func testTaskCancelledBeforeHashingIsReportedAsCancelled() async throws {
        let fixture = try ProgressImporterFixture(); defer { fixture.remove() }
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.importer.importURL(fixture.source) { _ in }
        }.value
        XCTAssertEqual(result.status, .cancelled)
    }

    func testRealTaskCancellationDuringTranscodeCleansBeforeReturning() async throws {
        let fixture = try ProgressImporterFixture(); defer { fixture.remove() }
        fixture.transcoder.waitForTaskCancellation = true
        let task = Task { await fixture.importer.importURL(fixture.source) { _ in } }
        await fixture.transcoder.waitUntilStarted()
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(try fixture.workRootIsEmpty())
    }

    func testCancellationDuringHashingWinsBeforeDuplicateLookup() async throws {
        let digester = BlockingDigester()
        let fixture = try ProgressImporterFixture(digester: digester); defer { fixture.remove() }
        let task = Task { await fixture.importer.importURL(fixture.source) { _ in } }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { digester.started.wait(); continuation.resume() }
        }
        task.cancel(); digester.release.signal()
        let result = await task.value
        XCTAssertEqual(result.status, .cancelled)
    }
}

private final class LockedImportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [MediaImportEvent]()
    var values: [MediaImportEvent] { lock.withLock { storage } }
    func append(_ event: MediaImportEvent) { lock.withLock { storage.append(event) } }
}

private final class ProgressImporterFixture: @unchecked Sendable {
    let root: URL
    let store = LocalFileStore()
    let paths: MediaPaths
    let library: MediaLibrary
    let source: URL
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let transcoder = ProgressTranscoder()
    let importer: MediaImporter

    init(digester: any Digesting = SHA256Digester()) throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path) : temporary
        root = base.appending(path: "Wallume-MediaImporterProgressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = MediaPaths(homeDirectory: root.appending(path: "home"), cacheDirectory: root.appending(path: "cache"))
        source = root.appending(path: "source.mov")
        try store.writeAtomically(Data("source".utf8), to: source)
        library = MediaLibrary(paths: paths, files: store, jsonStore: AtomicJSONStore(files: store))
        let generatedID = id
        importer = MediaImporter(
            paths: paths,
            files: store,
            library: library,
            digester: digester,
            inspector: ProgressInspector(),
            transcoder: transcoder,
            artwork: ProgressArtwork(),
            idGenerator: { generatedID }
        )
    }

    func workRootIsEmpty() throws -> Bool {
        if !store.exists(paths.importWorkRoot) { return true }
        return try store.contents(paths.importWorkRoot).isEmpty
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class BlockingDigester: Digesting, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func sha256(of url: URL) throws -> String { started.signal(); release.wait(); return "hash" }
    func sha256(data: Data) -> String { "hash" }
}

private struct ProgressInspector: MediaInspecting {
    func inspect(_ url: URL) async throws -> MediaInspection {
        MediaInspection(sourceByteCount: 6, pixelWidth: 16, pixelHeight: 16, frameRate: 30, durationSeconds: 1, codec: "hvc1")
    }
}

private final class ProgressTranscoder: MediaTranscoding, @unchecked Sendable {
    private let lock = NSLock()
    var shouldCancel = false
    var waitForTaskCancellation = false
    private var started = false
    func transcode(
        _ source: URL,
        to destination: URL,
        policy: MediaTranscodePolicy,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        progress?(0.5)
        lock.withLock { started = true }
        if waitForTaskCancellation {
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        if shouldCancel { throw CancellationError() }
        try Data("variant".utf8).write(to: destination)
    }
    func waitUntilStarted() async {
        while !lock.withLock({ started }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private struct ProgressArtwork: ArtworkGenerating {
    func generateArtwork(for variant: URL, thumbnail: URL, cover: URL) async throws {
        try Data("thumbnail".utf8).write(to: thumbnail)
        try Data("cover".utf8).write(to: cover)
    }
}
