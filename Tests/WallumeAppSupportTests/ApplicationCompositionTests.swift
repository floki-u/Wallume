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
    func testPerformanceCompositionCreatesOneServiceAndStoreAndForwardsRuntimeEvents() async {
        let composition = PerformanceApplicationComposition(
            service: PerformanceDiagnosticsService(
                sampler: CompositionPerformanceSampler(),
                clock: CompositionPerformanceClock(),
                reportStore: CompositionPerformanceReportStore(),
                machineInformation: .init(chip: .intel, physicalMemoryBytes: 8, macOSVersion: .macOS14)
            )
        )
        let runtime = populatedRuntimeSnapshot()

        await composition.service.update(runtime: runtime)
        let snapshot = await composition.service.snapshot

        XCTAssertEqual(snapshot.runtime, PerformanceRuntimeContext(snapshot: runtime))
        XCTAssertFalse(snapshot.isRealtimeActive)
    }

    func testTerminationSequenceStopsDiagnosticsBeforeRuntimeWithoutChangingExistingLockScreenFirstOrder() async {
        let events = CompositionTerminationEvents()
        let commands = ApplicationTerminationCommands(
            stopLockScreen: { await events.append("lock-screen") },
            stopDiagnostics: { await events.append("diagnostics") },
            stopRuntime: { await events.append("runtime") }
        )

        await commands.stopServices()

        let values = await events.values()
        XCTAssertEqual(values, ["lock-screen", "diagnostics", "runtime"])
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

private struct CompositionPerformanceSampler: PerformanceMetricSampling {
    func sample(at date: Date) async throws -> PerformanceSample {
        .init(timestamp: date, cpuPercent: 0, residentBytes: 0)
    }
}

private struct CompositionPerformanceClock: PerformanceClock {
    func now() async -> Date { .distantPast }
    func sleep(until deadline: Date) async throws {}
}

private struct CompositionPerformanceReportStore: PerformanceReportSaving {
    func save(_ report: PerformanceDiagnosticReport) throws {}
}

private actor CompositionTerminationEvents {
    private var valuesStorage: [String] = []
    func append(_ value: String) { valuesStorage.append(value) }
    func values() -> [String] { valuesStorage }
}

private func populatedRuntimeSnapshot() -> WallpaperRuntimeSnapshot {
    let mediaID = UUID()
    let resourceID = UUID()
    return WallpaperRuntimeSnapshot(
        runtime: RuntimeSnapshot(
            sessions: [RuntimeDisplaySession(displayID: DisplayID("display-1"), mediaID: mediaID, resourceID: resourceID)],
            resourceReferenceCounts: [resourceID: 1],
            pauseReasons: [.user],
            failures: [],
            resourceCreationCount: 2
        ),
        surfaceFailures: []
    )
}
private struct CompositionImporter: SingleMediaImporting {
    func importURL(_ source: URL, onEvent: @escaping @Sendable (MediaImportEvent) -> Void) async -> MediaImportResult {
        while !Task.isCancelled { await Task.yield() }
        return .init(source: source, status: .cancelled)
    }
}
