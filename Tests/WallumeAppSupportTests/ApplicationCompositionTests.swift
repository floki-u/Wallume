import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class ApplicationCompositionTests: XCTestCase {
    func testLockScreenDiagnosticsSnapshotClearsCurrentErrorOnLaterHealthyState() {
        let snapshot = LockScreenDiagnosticsSnapshot()

        snapshot.update(LockScreenSyncState(phase: .needsRepair, lastError: "repair required"))
        XCTAssertEqual(snapshot.currentError, .present)

        snapshot.update(LockScreenSyncState(phase: .readyToConfigure))

        XCTAssertEqual(snapshot.value.status, .readyToConfigure)
        XCTAssertEqual(snapshot.currentError, .none)
    }

    func testTerminationPolicyOnlyPromptsForActiveQueue() {
        XCTAssertEqual(TerminationPolicy.decision(queueActive: false), .terminateNow)
        XCTAssertEqual(TerminationPolicy.decision(queueActive: true), .requestConfirmation)
    }

    @MainActor
    func testLowPowerToggleImmediatelyPropagatesTheRuntimePolicy() {
        let suiteName = "ApplicationCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var observedValues: [Bool] = []
        let store = SettingsStore(
            defaults: defaults,
            loginItem: CompositionLoginItem(),
            onPauseInLowPowerModeChanged: { observedValues.append($0) }
        )

        store.setPauseInLowPowerMode(false)

        XCTAssertEqual(observedValues, [false])
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

    @MainActor
    func testTerminationSequenceStopsDiagnosticsBeforeRuntimeWithoutChangingExistingLockScreenFirstOrder() async {
        let events = CompositionTerminationEvents()
        let commands = ApplicationTerminationCommands(
            cancelSettingsExport: {},
            stopLockScreen: { await events.append("lock-screen") },
            stopDiagnostics: { await events.append("diagnostics") },
            stopRuntime: { await events.append("runtime") }
        )

        await commands.stopServices()

        let values = await events.values()
        XCTAssertEqual(values, ["lock-screen", "diagnostics", "runtime"])
    }

    @MainActor
    func testTerminationCancelsAndWaitsForSettingsExportWhilePreservingPreferencesAndServiceOrder() async {
        let suiteName = "ApplicationCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, loginItem: CompositionLoginItem())
        settings.setOpenGalleryAtLaunch(true)
        settings.setPauseInLowPowerMode(false)

        let owner = SettingsDiagnosticsExportTerminationOwner()
        let export = CompositionSettingsExport()
        let exportTask = Task {
            try? await owner.perform { try await export.run() }
        }
        await export.waitUntilStarted()

        let events = CompositionTerminationEvents()
        let commands = ApplicationTerminationCommands(
            cancelSettingsExport: {
                await owner.cancelAndWait()
                await events.append("settings-export")
            },
            stopLockScreen: { await events.append("lock-screen") },
            stopDiagnostics: { await events.append("diagnostics") },
            stopRuntime: { await events.append("runtime") }
        )

        await commands.stopServices()
        await exportTask.value

        let exportWasCancelled = await export.wasCancelled()
        let shutdownEvents = await events.values()
        XCTAssertTrue(exportWasCancelled)
        XCTAssertEqual(settings.settings.openGalleryAtLaunch, true)
        XCTAssertEqual(settings.settings.pauseInLowPowerMode, false)
        XCTAssertTrue(defaults.bool(forKey: "openGalleryAtLaunch"))
        XCTAssertEqual(defaults.object(forKey: "pauseInLowPowerMode") as? Bool, false)
        XCTAssertEqual(shutdownEvents, ["settings-export", "lock-screen", "diagnostics", "runtime"])
    }

    @MainActor
    func testTerminationRejectsAnExportThatArrivesAfterCancellingAnInFlightExport() async {
        let owner = SettingsDiagnosticsExportTerminationOwner()
        let inFlightExport = CompositionSettingsExport()
        let inFlightTask = Task {
            try? await owner.perform { try await inFlightExport.run() }
        }
        await inFlightExport.waitUntilStarted()

        await owner.cancelAndWait()
        await inFlightTask.value

        let rejectedExport = CompositionExportAttempt()
        do {
            try await owner.perform { await rejectedExport.run() }
            XCTFail("An export must not begin after termination starts.")
        } catch is CancellationError {
            // Expected: termination permanently owns the export lifecycle.
        } catch {
            XCTFail("Expected cancellation, got \(error).")
        }

        let initialExportWasCancelled = await inFlightExport.wasCancelled()
        let rejectedExportStarted = await rejectedExport.didStart()
        XCTAssertTrue(initialExportWasCancelled)
        XCTAssertFalse(rejectedExportStarted)
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

private struct CompositionLoginItem: LoginItemControlling {
    func isEnabled() throws -> Bool { false }
    func register() throws {}
    func unregister() throws {}
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

private actor CompositionSettingsExport {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancelled = false

    func run() async throws {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancellationContinuation = continuation
            }
            throw CancellationError()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func wasCancelled() -> Bool { cancelled }

    private func cancel() {
        cancelled = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}

private actor CompositionExportAttempt {
    private var started = false

    func run() { started = true }
    func didStart() -> Bool { started }
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
