import Foundation
import XCTest
@testable import WallumeAppSupport
@testable import WallumeCore

final class PerformanceDiagnosticsServiceTests: XCTestCase {
    func testSummaryKeepsLastSixtySamplesAndAggregatesCurrentAverageAndPeakMetrics() {
        let samples = (1...61).map { index in
            PerformanceSample(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                cpuPercent: Double(index),
                residentBytes: UInt64(index * 100)
            )
        }

        let summary = PerformanceSummary(samples: samples)

        XCTAssertEqual(summary.samples.count, 60)
        XCTAssertEqual(summary.samples.first?.timestamp, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(summary.currentCPUPercent, 61)
        XCTAssertEqual(summary.averageCPUPercent, 31.5)
        XCTAssertEqual(summary.peakCPUPercent, 61)
        XCTAssertEqual(summary.currentResidentBytes, 6_100)
        XCTAssertEqual(summary.averageResidentBytes, 3_150)
        XCTAssertEqual(summary.peakResidentBytes, 6_100)
    }

    func testRuntimeContextDerivesDeterministicCountersWithoutMediaIdentifiers() {
        let snapshot = WallpaperRuntimeSnapshot(
            runtime: RuntimeSnapshot(
                sessions: [
                    RuntimeDisplaySession(
                        displayID: DisplayID("display-b"),
                        mediaID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        resourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
                    ),
                    RuntimeDisplaySession(
                        displayID: DisplayID("display-a"),
                        mediaID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        resourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
                    ),
                ],
                resourceReferenceCounts: [
                    UUID(uuidString: "00000000-0000-0000-0000-000000000101")!: 2,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000102")!: 1,
                ],
                pauseReasons: [.thermalPressure, .user],
                failures: [],
                resourceCreationCount: 3
            ),
            surfaceFailures: []
        )

        let context = PerformanceRuntimeContext(snapshot: snapshot)

        XCTAssertEqual(context.activeDisplayCount, 2)
        XCTAssertEqual(context.activeSessionCount, 2)
        XCTAssertEqual(context.activeResourceCount, 2)
        XCTAssertEqual(context.sharedResourceCount, 1)
        XCTAssertEqual(context.sharedResourceReferenceCount, 2)
        XCTAssertEqual(context.resourceCreationCount, 3)
        XCTAssertEqual(context.pauseReasons, [.thermalPressure, .user])
    }

    func testReportStoreAtomicallyPersistsVersionedRedactedReport() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let store = PerformanceReportStore(
            homeDirectory: root.appending(path: "home"),
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        let report = PerformanceDiagnosticReport(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            scenario: "two-displays",
            summary: PerformanceSummary(samples: [
                PerformanceSample(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    cpuPercent: 12.5,
                    residentBytes: 1_024
                ),
                PerformanceSample(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                    cpuPercent: 25,
                    residentBytes: 2_048
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
            chip: "Apple M4",
            physicalMemoryBytes: 16_000_000_000,
            macOSVersion: "macOS 15.0"
        )

        XCTAssertNil(try store.latest())
        try store.save(report)

        XCTAssertEqual(try store.latest(), report)
        XCTAssertTrue(files.exists(store.url))
        XCTAssertTrue(store.url.path.hasPrefix(root.path))
        XCTAssertTrue(store.url.path.hasSuffix("Library/Application Support/Wallume/Diagnostics/report.json"))

        let json = try XCTUnwrap(String(data: files.read(store.url), encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))
        XCTAssertFalse(json.contains("Summer holiday.mov"))
        XCTAssertFalse(json.contains(root.path))
        XCTAssertFalse(json.contains("mediaName"))
        XCTAssertFalse(json.contains("videoURL"))
        XCTAssertFalse(json.contains("homeDirectory"))
    }

    func testReportDecodingRejectsUnexpectedPrivacyFieldsAndAbsolutePaths() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let store = PerformanceReportStore(
            homeDirectory: root.appending(path: "home"),
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        try files.createDirectory(store.url.deletingLastPathComponent())
        let unsafeDocument = """
        {
          "schemaVersion": 1,
          "startedAt": "2023-11-14T22:13:20Z",
          "duration": 30,
          "sampleCount": 1,
          "scenario": "single-display",
          "averageCPUPercent": 10,
          "peakCPUPercent": 10,
          "averageResidentBytes": 1024,
          "peakResidentBytes": 1024,
          "activeDisplayCount": 1,
          "activeSessionCount": 1,
          "activeResourceCount": 1,
          "sharedResourceCount": 0,
          "sharedResourceReferenceCount": 0,
          "resourceCreationCount": 1,
          "pauseReasons": [],
          "chip": "Apple M4",
          "physicalMemoryBytes": 16000000000,
          "macOSVersion": "macOS 15.0",
          "mediaName": "Summer holiday.mov",
          "videoURL": "/Users/person/Movies/Summer holiday.mov"
        }
        """
        try files.writeAtomically(Data(unsafeDocument.utf8), to: store.url)

        XCTAssertThrowsError(try store.latest())
    }

    func testReportStoreRejectsMediaNamesAndAbsolutePathsInAllowedStringFields() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let store = PerformanceReportStore(
            homeDirectory: root.appending(path: "home"),
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        let unsafeReport = PerformanceDiagnosticReport(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            scenario: "/Users/person/Movies/Summer holiday.mov",
            summary: PerformanceSummary(samples: []),
            runtime: PerformanceRuntimeContext(
                activeDisplayCount: 0,
                activeSessionCount: 0,
                activeResourceCount: 0,
                sharedResourceCount: 0,
                sharedResourceReferenceCount: 0,
                resourceCreationCount: 0,
                pauseReasons: []
            ),
            chip: "Apple M4",
            physicalMemoryBytes: 16_000_000_000,
            macOSVersion: "macOS 15.0"
        )

        XCTAssertThrowsError(try store.save(unsafeReport))
        XCTAssertNil(try store.latest())
    }

    func testReportStoreRejectsSourceURLsInAllowedStringFields() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let store = PerformanceReportStore(
            homeDirectory: root.appending(path: "home"),
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        let unsafeReport = PerformanceDiagnosticReport(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 30,
            scenario: "https://example.test/private.mp4?token=secret",
            summary: PerformanceSummary(samples: []),
            runtime: PerformanceRuntimeContext(
                activeDisplayCount: 0,
                activeSessionCount: 0,
                activeResourceCount: 0,
                sharedResourceCount: 0,
                sharedResourceReferenceCount: 0,
                resourceCreationCount: 0,
                pauseReasons: []
            ),
            chip: "Apple M4",
            physicalMemoryBytes: 16_000_000_000,
            macOSVersion: "macOS 15.0"
        )

        XCTAssertThrowsError(try store.save(unsafeReport))
        XCTAssertNil(try store.latest())
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let temporary = FileManager.default.temporaryDirectory
    let base = temporary.path.hasPrefix("/var/")
        ? URL(fileURLWithPath: "/private" + temporary.path)
        : temporary
    let root = base
        .appending(path: "Wallume-PerformanceDiagnosticsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
