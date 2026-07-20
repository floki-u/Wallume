import Foundation
import XCTest
@testable import WallumeAppSupport
@testable import WallumeCore

final class DiagnosticsExportServiceTests: XCTestCase {
    func testExportWritesVersionedRedactedSnapshotFromSafeProviders() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let destination = root.appending(path: "diagnostics.json")
        let privateFixtures = [
            "Summer holiday.mov",
            "file:///Users/example/Movies/Summer%20holiday.mov",
            "/Users/example/Library/Application Support/Wallume",
            "thumbnail-private.png",
            "wallume-backup.mov",
        ]
        let state = LockScreenSyncState(
            phase: .synced,
            selectedAerialID: privateFixtures[1],
            probe: LockScreenProbeReport(
                generation: .sonoma,
                writesPermitted: true,
                manifestExists: true,
                indexExists: true,
                availableSlots: [
                    AerialSlot(
                        id: privateFixtures[1],
                        displayName: privateFixtures[0],
                        videoURL: URL(fileURLWithPath: privateFixtures[2])
                    ),
                    AerialSlot(
                        id: "slot-2",
                        displayName: "Second slot",
                        videoURL: URL(fileURLWithPath: "/tmp/second.mov")
                    ),
                ],
                foreignBackupNames: [privateFixtures[4]]
            ),
            activeTransactionID: UUID(),
            syncedMedia: LockScreenSyncedMediaSummary(
                id: UUID(), displayName: privateFixtures[0]
            ),
            lastError: privateFixtures[2]
        )
        let report = makeReport()
        let reportReader = TestPerformanceReportReader(report: report)
        let service = DiagnosticsExportService(
            settings: { ApplicationSettings(
                launchAtLogin: true,
                openGalleryAtLaunch: false,
                pauseInLowPowerMode: true
            ) },
            lockScreenSummary: { LockScreenDiagnosticsSummary(state: state) },
            recentTransactionSummary: {
                DiagnosticsRecentTransactionSummary(
                    status: .available,
                    completedCount: 3,
                    failedCount: 1
                )
            },
            performanceReportStore: reportReader,
            buildSystemInfo: DiagnosticsBuildSystemInfo(
                productVersion: "1.2.3",
                buildNumber: "456",
                systemVersion: "macOS 15.0",
                architecture: "arm64"
            ),
            files: files
        )

        try await service.export(to: destination)

        let document = try decode(DiagnosticsExportDocument.self, from: files.read(destination))
        XCTAssertEqual(document.schemaVersion, DiagnosticsExportDocument.currentSchemaVersion)
        XCTAssertEqual(document.settings.launchAtLogin, true)
        XCTAssertEqual(document.settings.openGalleryAtLaunch, false)
        XCTAssertEqual(document.settings.pauseInLowPowerMode, true)
        XCTAssertEqual(document.lockScreen.status, .synced)
        XCTAssertEqual(document.lockScreen.availableSlotCount, 2)
        XCTAssertEqual(document.lockScreen.foreignBackupCount, 1)
        XCTAssertEqual(document.recentTransactions.completedCount, 3)
        XCTAssertEqual(document.recentTransactions.failedCount, 1)
        XCTAssertEqual(document.performance.status, .available)
        XCTAssertEqual(document.performance.report, report)
        XCTAssertEqual(reportReader.latestCallCount, 1)
        XCTAssertEqual(document.buildSystem.productVersion, "1.2.3")
        XCTAssertEqual(document.buildSystem.architecture, "arm64")

        let json = try XCTUnwrap(String(data: files.read(destination), encoding: .utf8))
        for fixture in privateFixtures {
            XCTAssertFalse(json.contains(fixture), "Export leaked \(fixture)")
        }
        XCTAssertFalse(json.contains("mediaID"))
        XCTAssertFalse(json.contains("displayName"))
        XCTAssertFalse(json.contains("selectedAerialID"))
        XCTAssertFalse(json.contains("activeTransactionID"))
    }

    func testExportKeepsExistingFileOnWriteFailureAndCanRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FailingDiagnosticsFileStore()
        let destination = root.appending(path: "diagnostics.json")
        let old = Data("old export".utf8)
        try files.writeAtomically(old, to: destination)
        let service = makeService(files: files)

        files.failWrites = true
        do {
            try await service.export(to: destination)
            XCTFail("Expected write failure")
        } catch {
            XCTAssertEqual(error as? DiagnosticsExportUserError, .writeFailed)
            XCTAssertFalse(error.localizedDescription.contains("diagnostics write failure"))
        }
        XCTAssertEqual(try files.read(destination), old)

        files.failWrites = false
        try await service.export(to: destination)

        let document = try decode(DiagnosticsExportDocument.self, from: files.read(destination))
        XCTAssertEqual(document.performance.status, .available)
        XCTAssertEqual(document.performance.report, makeReport())
    }

    func testTerminationAdmissionRejectsARealExportThatHasNotReachedAtomicWrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "diagnostics.json")
        let files = LocalFileStore()
        let admission = DiagnosticsExportCommitAdmission()
        let preparation = BlockingDiagnosticsPreparation()
        let service = makeService(
            files: files,
            commitAdmission: admission,
            settings: { preparation.settings() }
        )
        let export = Task { try await service.export(to: destination) }

        await preparation.waitUntilStarted()
        await admission.terminateAndWait()
        preparation.release()

        do {
            try await export.value
            XCTFail("A terminal admission gate must reject an export that has not begun its commit.")
        } catch {
            XCTAssertEqual(error as? DiagnosticsExportUserError, .cancelled)
        }
        XCTAssertFalse(files.exists(destination))
    }

    func testTerminationAwaitsAndCompletesARealAtomicWriteThatWasAlreadyAdmitted() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "diagnostics.json")
        let files = BlockingAtomicDiagnosticsFileStore()
        let admission = DiagnosticsExportCommitAdmission()
        let owner = SettingsDiagnosticsExportTerminationOwner(commitAdmission: admission)
        let service = makeService(files: files, commitAdmission: admission)
        let export = Task {
            try await owner.perform { try await service.export(to: destination) }
        }

        await files.waitUntilWriteStarted()
        let termination = DiagnosticsTerminationCompletion()
        let terminationTask = Task {
            await owner.cancelAndWait()
            await termination.markCompleted()
        }
        let admissionIsTerminal = await waitUntilAdmissionIsTerminal(admission)
        let completedBeforeRelease = await termination.isCompleted
        XCTAssertTrue(admissionIsTerminal)
        XCTAssertFalse(completedBeforeRelease)

        files.releaseWrite()
        try await export.value
        await terminationTask.value

        let completedAfterRelease = await termination.isCompleted
        XCTAssertTrue(completedAfterRelease)
        let document = try decode(DiagnosticsExportDocument.self, from: files.read(destination))
        XCTAssertEqual(document.schemaVersion, DiagnosticsExportDocument.currentSchemaVersion)
        XCTAssertEqual(document.performance.report, makeReport())
    }

    func testExportRepresentsUnavailableSourcesWithoutEncodingProviderErrors() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let destination = root.appending(path: "diagnostics.json")
        let service = DiagnosticsExportService(
            settings: {
                ApplicationSettings(
                    launchAtLogin: false,
                    openGalleryAtLaunch: false,
                    pauseInLowPowerMode: true
                )
            },
            lockScreenSummary: { throw DiagnosticsFixtureError.privateProviderFailure },
            recentTransactionSummary: { throw DiagnosticsFixtureError.privateProviderFailure },
            performanceReportStore: TestPerformanceReportReader(error: .privateProviderFailure),
            buildSystemInfo: DiagnosticsBuildSystemInfo(
                productVersion: "1.0",
                buildNumber: "1",
                systemVersion: "macOS 15",
                architecture: "arm64"
            ),
            files: files
        )

        try await service.export(to: destination)

        let document = try decode(DiagnosticsExportDocument.self, from: files.read(destination))
        XCTAssertEqual(document.lockScreen, .unavailable)
        XCTAssertEqual(document.recentTransactions, .unavailable)
        XCTAssertEqual(document.performance.status, .unavailable)
        XCTAssertNil(document.performance.report)
        let json = try XCTUnwrap(String(data: files.read(destination), encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/example/Secret.mov"))
    }

    func testBuildSystemInfoRedactsUnsafeMetadataValues() throws {
        let fixtures = [
            "Summer holiday.mov",
            "file:///Users/example/Movies/Summer%20holiday.mov",
            "/Users/example/Library/Application Support/Wallume",
            "thumbnail-private.png",
        ]
        let info = DiagnosticsBuildSystemInfo(
            productVersion: fixtures[0],
            buildNumber: fixtures[1],
            systemVersion: fixtures[2],
            architecture: fixtures[3]
        )

        XCTAssertEqual(info.productVersion, "unavailable")
        XCTAssertEqual(info.buildNumber, "unavailable")
        XCTAssertEqual(info.systemVersion, "unavailable")
        XCTAssertEqual(info.architecture, "unavailable")
        let json = try String(decoding: JSONEncoder().encode(info), as: UTF8.self)
        for fixture in fixtures {
            XCTAssertFalse(json.contains(fixture), "Export metadata leaked \(fixture)")
        }
    }
}

private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "Wallume-DiagnosticsExportTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeReport() -> PerformanceDiagnosticReport {
    PerformanceDiagnosticReport(
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 30,
        scenario: .twoDisplays,
        summary: PerformanceSummary(samples: [
            PerformanceSample(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                cpuPercent: 12.5,
                residentBytes: 1_024
            ),
        ]),
        runtime: PerformanceRuntimeContext(
            activeDisplayCount: 2,
            activeSessionCount: 2,
            activeResourceCount: 1,
            sharedResourceCount: 1,
            sharedResourceReferenceCount: 2,
            resourceCreationCount: 1,
            pauseReasons: [.user]
        ),
        chip: .appleM4,
        physicalMemoryBytes: 16_000_000_000,
        macOSVersion: .macOS15
    )
}

private func makeService(
    files: any FileStore,
    commitAdmission: DiagnosticsExportCommitAdmission = .init(),
    settings: @escaping @Sendable () -> ApplicationSettings = {
        ApplicationSettings(
            launchAtLogin: false,
            openGalleryAtLaunch: true,
            pauseInLowPowerMode: true
        )
    },
    reportReader: any PerformanceReportReading = TestPerformanceReportReader(report: makeReport())
) -> DiagnosticsExportService {
    DiagnosticsExportService(
        settings: settings,
        lockScreenSummary: {
            LockScreenDiagnosticsSummary(
                status: .unconfigured,
                writesPermitted: nil,
                availableSlotCount: 0,
                foreignBackupCount: 0,
                lastTransactionSucceeded: nil
            )
        },
        recentTransactionSummary: {
            DiagnosticsRecentTransactionSummary(
                status: .available,
                completedCount: 0,
                failedCount: 0
            )
        },
        commitAdmission: commitAdmission,
        performanceReportStore: reportReader,
        buildSystemInfo: DiagnosticsBuildSystemInfo(
            productVersion: "1.0",
            buildNumber: "1",
            systemVersion: "macOS 15",
            architecture: "arm64"
        ),
        files: files
    )
}

private func waitUntilAdmissionIsTerminal(
    _ admission: DiagnosticsExportCommitAdmission
) async -> Bool {
    for _ in 0..<1_000 {
        if !admission.beginCommit() { return true }
        admission.finishCommit()
        await Task.yield()
    }
    return false
}

private enum DiagnosticsFixtureError: Error, LocalizedError {
    case writeFailed
    case privateProviderFailure

    var errorDescription: String? {
        switch self {
        case .writeFailed: "diagnostics write failure"
        case .privateProviderFailure: "/Users/example/Secret.mov"
        }
    }
}

private final class TestPerformanceReportReader: PerformanceReportReading, @unchecked Sendable {
    private let report: PerformanceDiagnosticReport?
    private let error: DiagnosticsFixtureError?
    private(set) var latestCallCount = 0

    init(report: PerformanceDiagnosticReport? = nil, error: DiagnosticsFixtureError? = nil) {
        self.report = report
        self.error = error
    }

    func latest() throws -> PerformanceDiagnosticReport? {
        latestCallCount += 1
        if let error { throw error }
        return report
    }
}

private final class FailingDiagnosticsFileStore: FileStore, @unchecked Sendable {
    private let local = LocalFileStore()
    var failWrites = false

    func exists(_ url: URL) -> Bool { local.exists(url) }
    func read(_ url: URL) throws -> Data { try local.read(url) }
    func contents(_ directory: URL) throws -> [URL] { try local.contents(directory) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(url) }
    func createPrivateDirectory(_ url: URL) throws { try local.createPrivateDirectory(url) }
    func identity(of url: URL) throws -> FileIdentity { try local.identity(of: url) }
    func hasNoSymlinkComponents(_ url: URL) throws -> Bool { try local.hasNoSymlinkComponents(url) }
    func removeDurably(_ url: URL, ifIdentityMatches identity: FileIdentity) throws -> Bool {
        try local.removeDurably(url, ifIdentityMatches: identity)
    }
    func writeAtomically(_ data: Data, to target: URL) throws {
        guard !failWrites else { throw DiagnosticsFixtureError.writeFailed }
        try local.writeAtomically(data, to: target)
    }
    func writeExclusively(_ data: Data, to target: URL) throws {
        try local.writeExclusively(data, to: target)
    }
    func copy(_ source: URL, to destination: URL) throws { try local.copy(source, to: destination) }
    func copyExclusively(_ source: URL, to destination: URL) throws {
        try local.copyExclusively(source, to: destination)
    }
    func replace(_ target: URL, with preparedFile: URL) throws {
        try local.replace(target, with: preparedFile)
    }
    func exchange(_ target: URL, with preparedFile: URL) throws {
        try local.exchange(target, with: preparedFile)
    }
    func installExclusively(_ target: URL, from preparedFile: URL) throws {
        try local.installExclusively(target, from: preparedFile)
    }
    func remove(_ url: URL) throws { try local.remove(url) }
}

private final class BlockingDiagnosticsPreparation: @unchecked Sendable {
    private let started = AsyncStartSignal()
    private let releaseBarrier = DispatchSemaphore(value: 0)

    func settings() -> ApplicationSettings {
        started.signal()
        releaseBarrier.wait()
        return ApplicationSettings(
            launchAtLogin: false,
            openGalleryAtLaunch: true,
            pauseInLowPowerMode: true
        )
    }

    func waitUntilStarted() async { await started.wait() }

    func release() { releaseBarrier.signal() }
}

private actor DiagnosticsTerminationCompletion {
    private(set) var isCompleted = false

    func markCompleted() { isCompleted = true }
}

private final class BlockingAtomicDiagnosticsFileStore: FileStore, @unchecked Sendable {
    private let local = LocalFileStore()
    private let writeStarted = AsyncStartSignal()
    private let releaseBarrier = DispatchSemaphore(value: 0)

    func waitUntilWriteStarted() async { await writeStarted.wait() }

    func releaseWrite() { releaseBarrier.signal() }

    func exists(_ url: URL) -> Bool { local.exists(url) }
    func read(_ url: URL) throws -> Data { try local.read(url) }
    func contents(_ directory: URL) throws -> [URL] { try local.contents(directory) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(url) }
    func createPrivateDirectory(_ url: URL) throws { try local.createPrivateDirectory(url) }
    func identity(of url: URL) throws -> FileIdentity { try local.identity(of: url) }
    func hasNoSymlinkComponents(_ url: URL) throws -> Bool { try local.hasNoSymlinkComponents(url) }
    func removeDurably(_ url: URL, ifIdentityMatches identity: FileIdentity) throws -> Bool {
        try local.removeDurably(url, ifIdentityMatches: identity)
    }
    func writeAtomically(_ data: Data, to target: URL) throws {
        writeStarted.signal()
        releaseBarrier.wait()
        try local.writeAtomically(data, to: target)
    }
    func writeExclusively(_ data: Data, to target: URL) throws {
        try local.writeExclusively(data, to: target)
    }
    func copy(_ source: URL, to destination: URL) throws { try local.copy(source, to: destination) }
    func copyExclusively(_ source: URL, to destination: URL) throws {
        try local.copyExclusively(source, to: destination)
    }
    func replace(_ target: URL, with preparedFile: URL) throws {
        try local.replace(target, with: preparedFile)
    }
    func exchange(_ target: URL, with preparedFile: URL) throws {
        try local.exchange(target, with: preparedFile)
    }
    func installExclusively(_ target: URL, from preparedFile: URL) throws {
        try local.installExclusively(target, from: preparedFile)
    }
    func remove(_ url: URL) throws { try local.remove(url) }
}

private final class AsyncStartSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var didSignal = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        didSignal = true
        continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didSignal {
                lock.unlock()
                continuation.resume()
            } else {
                precondition(waiter == nil, "Only one test waiter is supported.")
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
