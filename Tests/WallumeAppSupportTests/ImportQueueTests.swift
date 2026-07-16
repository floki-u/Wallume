import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class ImportQueueTests: XCTestCase {
    func testQueueIsSerialAndContinuesAfterFailure() async throws {
        let importer = QueueImporter(results: [.failed, .imported])
        let queue = ImportQueue(importer: importer, scanner: PassthroughScanner())
        await queue.enqueue([URL(fileURLWithPath: "/a.mov"), URL(fileURLWithPath: "/b.mov")])

        let snapshot = await waitUntilIdle(queue)

        XCTAssertEqual(importer.maximumConcurrentCalls, 1)
        XCTAssertEqual(snapshot.summary.failed, 1)
        XCTAssertEqual(snapshot.summary.imported, 1)
    }

    func testCancelCurrentContinuesButCancelAllCancelsWaiting() async throws {
        let importer = QueueImporter(results: [.imported, .imported, .imported], blocks: true)
        let queue = ImportQueue(importer: importer, scanner: PassthroughScanner())
        await queue.enqueue([URL(fileURLWithPath: "/a.mov"), URL(fileURLWithPath: "/b.mov")])
        await importer.waitUntilStarted(1)
        await queue.cancelCurrent()
        await importer.releaseNext()
        await importer.waitUntilStarted(2)
        await queue.cancelAll()
        await importer.releaseAll()

        let first = await waitUntilIdle(queue)
        XCTAssertEqual(first.summary.cancelled, 2)

        let secondImporter = QueueImporter(results: [.imported, .imported, .imported], blocks: true)
        let secondQueue = ImportQueue(importer: secondImporter, scanner: PassthroughScanner())
        await secondQueue.enqueue([URL(fileURLWithPath: "/a.mov"), URL(fileURLWithPath: "/b.mov"), URL(fileURLWithPath: "/c.mov")])
        await secondImporter.waitUntilStarted(1)
        await secondQueue.cancelAll()
        await secondImporter.releaseAll()
        let second = await waitUntilIdle(secondQueue)
        XCTAssertEqual(second.summary.cancelled, 3)
    }

    func testRetryAllFailuresAppendsAttemptsInOriginalOrder() async throws {
        let importer = QueueImporter(results: [.failed, .failed, .imported, .imported])
        let queue = ImportQueue(importer: importer, scanner: PassthroughScanner())
        await queue.enqueue([URL(fileURLWithPath: "/b.mov"), URL(fileURLWithPath: "/a.mov")])
        _ = await waitUntilIdle(queue)

        await queue.retryAllFailures()
        let snapshot = await waitUntilIdle(queue)

        XCTAssertEqual(importer.sources.map(\.lastPathComponent), ["b.mov", "a.mov", "b.mov", "a.mov"])
        XCTAssertEqual(snapshot.items.map(\.attempts.count), [2, 2])
        XCTAssertEqual(snapshot.summary.imported, 2)
    }

    private func waitUntilIdle(_ queue: ImportQueue) async -> ImportQueueSnapshot {
        for _ in 0..<500 {
            let snapshot = await queue.snapshot()
            if !snapshot.isActive { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await queue.snapshot()
    }
}

private struct PassthroughScanner: ImportScanning {
    func scan(_ urls: [URL]) -> ImportScanResult { .init(candidates: urls, warnings: []) }
}

private final class QueueImporter: SingleMediaImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [MediaImportStatus]
    private var current = 0
    private var maximum = 0
    private var observedSources = [URL]()
    private let blocks: Bool
    private var continuations = [CheckedContinuation<Void, Never>]()

    init(results: [MediaImportStatus], blocks: Bool = false) { self.results = results; self.blocks = blocks }
    var maximumConcurrentCalls: Int { lock.withLock { maximum } }
    var sources: [URL] { lock.withLock { observedSources } }

    func importURL(_ source: URL, onEvent: @escaping @Sendable (MediaImportEvent) -> Void) async -> MediaImportResult {
        let status = lock.withLock { () -> MediaImportStatus in
            current += 1; maximum = max(maximum, current); observedSources.append(source)
            return results.removeFirst()
        }
        if blocks { await withCheckedContinuation { continuation in lock.withLock { continuations.append(continuation) } } }
        let cancelled = Task.isCancelled
        lock.withLock { current -= 1 }
        return .init(source: source, status: cancelled ? .cancelled : status, message: status == .failed ? "synthetic" : nil)
    }

    func waitUntilStarted(_ count: Int) async {
        while lock.withLock({ observedSources.count }) < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func releaseNext() async { lock.withLock { continuations.isEmpty ? nil : continuations.removeFirst() }?.resume() }
    func releaseAll() async { lock.withLock { let value = continuations; continuations.removeAll(); return value }.forEach { $0.resume() } }
}
