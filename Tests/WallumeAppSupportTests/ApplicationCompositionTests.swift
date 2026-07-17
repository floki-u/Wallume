import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class ApplicationCompositionTests: XCTestCase {
    func testTerminationPolicyOnlyPromptsForActiveQueue() {
        XCTAssertEqual(TerminationPolicy.decision(queueActive: false), .terminateNow)
        XCTAssertEqual(TerminationPolicy.decision(queueActive: true), .requestConfirmation)
    }

    func testImmediatePostEnqueueTerminationDecisionUsesAuthoritativeQueue() async {
        let importer = CompositionImporter()
        let queue = ImportQueue(importer: importer, scanner: CompositionScanner())
        await queue.enqueue([URL(fileURLWithPath: "/a.mov")])
        let decision = await TerminationPolicy.decision(queue: queue)
        XCTAssertEqual(decision, .requestConfirmation)
        await queue.cancelAllAndWait()
    }

    @MainActor
    func testLockScreenCompositionBuildsOneServiceAndStoreFromInjectedClient() async throws {
        let fixture = try LockScreenCompositionFixture()
        defer { fixture.cleanup() }
        var clientConstructionCount = 0

        let composition = LockScreenApplicationComposition(
            configurationURL: fixture.configurationURL,
            files: fixture.files,
            makeSystemClient: {
                clientConstructionCount += 1
                return CompositionLockScreenClient()
            }
        )

        await composition.service.start()
        await composition.service.waitForIdle()
        let state = await composition.service.snapshot()
        await waitForStore(composition.store, phase: .readyToConfigure)

        XCTAssertEqual(clientConstructionCount, 1)
        XCTAssertEqual(state.phase, .readyToConfigure)
        XCTAssertEqual(composition.store.state.phase, .readyToConfigure)
    }

    @MainActor
    func testLockScreenClientConstructionFailureBecomesVisibleRepairState() async throws {
        let fixture = try LockScreenCompositionFixture()
        defer { fixture.cleanup() }

        let composition = LockScreenApplicationComposition(
            configurationURL: fixture.configurationURL,
            files: fixture.files,
            makeSystemClient: { throw CompositionError.expected }
        )

        await composition.service.start()
        await composition.service.waitForIdle()
        let state = await composition.service.snapshot()
        await waitForStore(composition.store, phase: .needsRepair)

        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(composition.store.state.phase, .needsRepair)
        XCTAssertNotNil(composition.store.state.lastError)
    }

    @MainActor
    private func waitForStore(
        _ store: LockScreenFeatureStore,
        phase: LockScreenSyncPhase
    ) async {
        for _ in 0..<100 where store.state.phase != phase { await Task.yield() }
    }
}

private final class LockScreenCompositionFixture {
    let root: URL
    let configurationURL: URL
    let files = LocalFileStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        configurationURL = root.appending(path: "lock-screen-sync.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct CompositionLockScreenClient: LockScreenSystemClient {
    func probe() throws -> LockScreenProbeReport {
        LockScreenProbeReport(
            generation: .sonoma,
            writesPermitted: true,
            manifestExists: true,
            indexExists: true,
            availableSlots: [],
            foreignBackupNames: []
        )
    }

    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest {
        throw CompositionError.unexpectedWrite
    }

    func inspectRecovery() throws -> [RecoveryCandidate] { [] }

    func restore(transactionID: UUID) throws -> RecoveryReport {
        throw CompositionError.unexpectedWrite
    }
}

private enum CompositionError: Error {
    case expected
    case unexpectedWrite
}

private struct CompositionScanner: ImportScanning {
    func scan(_ urls: [URL]) -> ImportScanResult { .init(candidates: urls, warnings: []) }
}
private struct CompositionImporter: SingleMediaImporting {
    func importURL(_ source: URL, onEvent: @escaping @Sendable (MediaImportEvent) -> Void) async -> MediaImportResult {
        while !Task.isCancelled { await Task.yield() }
        return .init(source: source, status: .cancelled)
    }
}
