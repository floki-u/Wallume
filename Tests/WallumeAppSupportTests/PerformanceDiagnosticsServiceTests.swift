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

    func testSummaryCalculatesAverageResidentBytesWithoutOverflow() {
        let summary = PerformanceSummary(samples: [
            PerformanceSample(timestamp: .distantPast, cpuPercent: 0, residentBytes: .max),
            PerformanceSample(timestamp: .distantFuture, cpuPercent: 0, residentBytes: .max - 1),
        ])

        XCTAssertEqual(summary.averageResidentBytes, .max - 1)
    }

    func testReportEncodingUsesOnlyDeclaredSafeValues() throws {
        let report = PerformanceDiagnosticReport(
            startedAt: .distantPast,
            duration: 30,
            scenario: .singleDisplay,
            summary: PerformanceSummary(samples: []),
            runtime: PerformanceRuntimeContext(
                activeDisplayCount: 0, activeSessionCount: 0, activeResourceCount: 0,
                sharedResourceCount: 0, sharedResourceReferenceCount: 0,
                resourceCreationCount: 0, pauseReasons: []
            ),
            chip: .appleM1,
            physicalMemoryBytes: 8_000_000_000,
            macOSVersion: .macOS14
        )

        let json = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)

        XCTAssertTrue(json.contains("\"scenario\":\"single-display\""))
        XCTAssertTrue(json.contains("\"chip\":\"Apple M1\""))
        XCTAssertTrue(json.contains("\"macOSVersion\":\"macOS 14\""))
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
            scenario: .twoDisplays,
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
            chip: .appleM4,
            physicalMemoryBytes: 16_000_000_000,
            macOSVersion: .macOS15
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
          "macOSVersion": "macOS 15",
          "mediaName": "Summer holiday.mov",
          "videoURL": "/Users/person/Movies/Summer holiday.mov"
        }
        """
        try files.writeAtomically(Data(unsafeDocument.utf8), to: store.url)

        XCTAssertThrowsError(try store.latest())
    }

    func testReportDecodingRejectsSourceURLsAndMediaNamesInDeclaredFields() throws {
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
        {"schemaVersion":1,"startedAt":"2023-11-14T22:13:20Z","duration":30,"sampleCount":1,"scenario":"source=https://example.test/private.mp4?token=secret","averageCPUPercent":10,"peakCPUPercent":10,"averageResidentBytes":1024,"peakResidentBytes":1024,"activeDisplayCount":1,"activeSessionCount":1,"activeResourceCount":1,"sharedResourceCount":0,"sharedResourceReferenceCount":0,"resourceCreationCount":1,"pauseReasons":[],"chip":"Summer holiday.mov","physicalMemoryBytes":16000000000,"macOSVersion":"backup-2026"}
        """
        try files.writeAtomically(Data(unsafeDocument.utf8), to: store.url)

        XCTAssertThrowsError(try store.latest())
    }

    func testReportDecodingRejectsEveryUnsafeDeclaredValue() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalFileStore()
        let store = PerformanceReportStore(
            homeDirectory: root.appending(path: "home"),
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        try files.createDirectory(store.url.deletingLastPathComponent())
        let safeDocument = """
        {"schemaVersion":1,"startedAt":"2023-11-14T22:13:20Z","duration":30,"sampleCount":1,"scenario":"single-display","averageCPUPercent":10,"peakCPUPercent":10,"averageResidentBytes":1024,"peakResidentBytes":1024,"activeDisplayCount":1,"activeSessionCount":1,"activeResourceCount":1,"sharedResourceCount":0,"sharedResourceReferenceCount":0,"resourceCreationCount":1,"pauseReasons":[],"chip":"Apple M4","physicalMemoryBytes":16000000000,"macOSVersion":"macOS 15"}
        """
        let unsafeReplacements = [
            ("\"scenario\":\"single-display\"", "\"scenario\":\"source=https://example.test/private.mp4?token=secret\""),
            ("\"chip\":\"Apple M4\"", "\"chip\":\"Summer holiday.mov\""),
            ("\"macOSVersion\":\"macOS 15\"", "\"macOSVersion\":\"Wallume.backup\""),
        ]

        for (safeValue, unsafeValue) in unsafeReplacements {
            let document = safeDocument.replacingOccurrences(of: safeValue, with: unsafeValue)
            try files.writeAtomically(Data(document.utf8), to: store.url)

            XCTAssertThrowsError(try store.latest())
        }
    }

    func testMetricSamplerAdapterConvertsRuntimeSampleAtProvidedTimestamp() async throws {
        let runtimeSampler = StubRuntimeMetricSampler(
            sample: RuntimeMetricSample(residentBytes: 4_096, cpuPercent: 12.5)
        )
        let sampler = PerformanceMetricSampler(sampler: runtimeSampler)
        let timestamp = Date(timeIntervalSince1970: 100)

        let sample = try await sampler.sample(at: timestamp)

        XCTAssertEqual(
            sample,
            PerformanceSample(timestamp: timestamp, cpuPercent: 12.5, residentBytes: 4_096)
        )
        XCTAssertEqual(runtimeSampler.sampleCallCount, 1)
    }

    func testRealtimeStartsOnceStopsOnPageDisappearanceAndNeverWritesReport() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 100))
        let sampler = SequencePerformanceMetricSampler()
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, sampler: sampler, reports: reports)

        await service.beginRealtime()
        await service.beginRealtime()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        var snapshot = await service.snapshot
        XCTAssertTrue(snapshot.isRealtimeActive)

        await clock.advanceOneSecond()
        try await waitUntil { await sampler.sampleCount == 1 }
        snapshot = await service.snapshot
        XCTAssertEqual(snapshot.realtimeSummary.samples.count, 1)

        await service.endRealtime()
        snapshot = await service.snapshot
        let pendingSleepCount = await clock.pendingSleepCount
        XCTAssertFalse(snapshot.isRealtimeActive)
        XCTAssertEqual(pendingSleepCount, 0)
        await clock.advanceOneSecond()
        await Task.yield()

        let sampleCount = await sampler.sampleCount
        XCTAssertEqual(sampleCount, 1)
        XCTAssertEqual(reports.saveCallCount, 0)
    }

    func testRealtimeDoesNotSampleAfterCancellationDuringClockRead() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 150))
        let sampler = SequencePerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.beginRealtime()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.blockNextNow()
        await clock.advanceToNextDeadline()
        try await waitUntil { await clock.pendingNowCount == 1 }

        let ending = Task { await service.endRealtime() }
        try await waitUntil { !(await service.snapshot.isRealtimeActive) }
        await clock.releaseNow()
        await ending.value

        let sampleCount = await sampler.sampleCount
        XCTAssertEqual(sampleCount, 0)
    }

    func testRealtimeTreatsUnexpectedCancellationErrorFromClockAsSamplingFailure() async throws {
        let clock = CancellationErrorPerformanceClock(now: Date(timeIntervalSince1970: 160))
        let service = makeService(clock: clock)

        await service.beginRealtime()
        try await waitUntil { !(await service.snapshot.isRealtimeActive) }

        let snapshot = await service.snapshot
        XCTAssertEqual(snapshot.realtimeError, .samplingFailed)
    }

    func testDiagnosticDoesNotSampleAfterCancellationDuringClockRead() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 175))
        let sampler = SequencePerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.startDiagnostic(scenario: .singleDisplay)
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.blockNextNow()
        await clock.advanceToNextDeadline()
        try await waitUntil { await clock.pendingNowCount == 1 }

        let cancellation = Task { await service.cancelDiagnostic() }
        try await waitUntil { !(await service.snapshot.isDiagnosticRunning) }
        await clock.releaseNow()
        await cancellation.value

        let sampleCount = await sampler.sampleCount
        XCTAssertEqual(sampleCount, 0)
    }

    func testDiagnosticTreatsUnexpectedCancellationErrorFromSamplerAsSamplingFailure() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 180))
        let sampler = CancellationErrorPerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.startDiagnostic(scenario: .singleDisplay)
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceToNextDeadline()
        try await waitUntil { !(await service.snapshot.isDiagnosticRunning) }

        let snapshot = await service.snapshot
        XCTAssertEqual(snapshot.diagnosticError, .samplingFailed)
    }

    func testRealtimeSummaryTrimsToLatestSixtyOneSecondSamples() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = ManualPerformanceClock(now: start)
        let sampler = SequencePerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.beginRealtime()
        for expectedCount in 1...61 {
            try await waitUntil { await clock.pendingSleepCount == 1 }
            await clock.advanceOneSecond()
            try await waitUntil { await sampler.sampleCount == expectedCount }
        }

        let snapshot = await service.snapshot
        XCTAssertEqual(snapshot.realtimeSummary.samples.count, 60)
        XCTAssertEqual(snapshot.realtimeSummary.samples.first?.timestamp, start.addingTimeInterval(2))
        XCTAssertEqual(snapshot.realtimeSummary.samples.last?.timestamp, start.addingTimeInterval(61))
        try await waitUntil { await clock.pendingSleepCount == 1 }
        let requestedDeadlines = await clock.requestedDeadlines
        XCTAssertEqual(
            requestedDeadlines,
            (1...62).map { start.addingTimeInterval(TimeInterval($0)) }
        )

        await service.endRealtime()
    }

    func testDiagnosticIsSerialSurvivesPageDisappearanceAndSavesExactlyThirtyScheduledSamples() async throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let clock = ManualPerformanceClock(now: start)
        let sampler = SequencePerformanceMetricSampler()
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, sampler: sampler, reports: reports)

        await service.beginRealtime()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await service.startDiagnostic(scenario: .twoDisplays)
        await service.startDiagnostic(scenario: .paused)
        try await waitUntil { await clock.pendingSleepCount == 1 }

        await service.endRealtime()
        let runningAfterDisappearance = await service.snapshot.isDiagnosticRunning
        XCTAssertTrue(runningAfterDisappearance)
        try await waitUntil { await clock.pendingSleepCount == 1 }

        for expectedCount in 1...30 {
            await clock.advanceOneSecond()
            try await waitUntil {
                let snapshot = await service.snapshot
                return snapshot.diagnosticSampleCount == expectedCount
            }
            if expectedCount < 30 {
                try await waitUntil { await clock.pendingSleepCount == 1 }
            }
        }

        try await waitUntil { reports.saveCallCount == 1 }
        let snapshot = await service.snapshot
        let report = try XCTUnwrap(snapshot.completedReport)
        XCTAssertFalse(snapshot.isDiagnosticRunning)
        XCTAssertEqual(report.startedAt, start)
        XCTAssertEqual(report.duration, 30)
        XCTAssertEqual(report.sampleCount, 30)
        XCTAssertEqual(report.scenario, .twoDisplays)
        let sampleCount = await sampler.sampleCount
        let requestedDeadlines = await clock.requestedDeadlines
        let timestamps = await sampler.timestamps
        XCTAssertEqual(sampleCount, 30)
        XCTAssertEqual(reports.savedReports, [report])
        XCTAssertEqual(
            Array(requestedDeadlines.suffix(30)),
            (1...30).map { start.addingTimeInterval(TimeInterval($0)) }
        )
        XCTAssertEqual(
            timestamps,
            (1...30).map { start.addingTimeInterval(TimeInterval($0)) }
        )
    }

    func testVisibleRealtimeSharesEachDiagnosticTickWithoutDoubleSamplingProcessMetrics() async throws {
        let start = Date(timeIntervalSince1970: 2_250)
        let clock = ManualPerformanceClock(now: start)
        let sampler = SequencePerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.beginRealtime()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await service.startDiagnostic(scenario: .singleDisplay)
        try await waitUntil { await clock.pendingSleepCount == 1 }

        for expectedCount in 1...30 {
            await clock.advanceOneSecond()
            try await waitUntil {
                let snapshot = await service.snapshot
                return snapshot.diagnosticSampleCount == expectedCount
                    && snapshot.realtimeSummary.samples.count == expectedCount
            }
            if expectedCount < 30 {
                try await waitUntil { await clock.pendingSleepCount == 1 }
            }
        }

        let snapshot = await service.snapshot
        let sampleCount = await sampler.sampleCount
        XCTAssertEqual(sampleCount, 30)
        XCTAssertEqual(snapshot.completedReport?.sampleCount, 30)
        XCTAssertEqual(snapshot.realtimeSummary.samples.count, 30)

        await service.endRealtime()
    }

    func testDiagnosticUsesAbsoluteOneSecondDeadlinesWithoutSamplerDrift() async throws {
        let start = Date(timeIntervalSince1970: 2_400)
        let clock = ManualPerformanceClock(now: start)
        let sampler = DriftingPerformanceMetricSampler(clock: clock, latency: 0.25)
        let service = makeService(clock: clock, sampler: sampler)

        await service.startDiagnostic(scenario: .singleDisplay)
        try await completeDiagnostic(service: service, clock: clock)

        let expectedTimestamps = (1...30).map {
            start.addingTimeInterval(TimeInterval($0))
        }
        let timestamps = await sampler.timestamps
        let requestedDeadlines = await clock.requestedDeadlines
        let snapshot = await service.snapshot
        XCTAssertEqual(timestamps, expectedTimestamps)
        XCTAssertEqual(requestedDeadlines, expectedTimestamps)
        XCTAssertEqual(snapshot.completedReport?.duration, 30)
    }

    func testDiagnosticWindowStartsAfterSlowRealtimeSampleReleasesSampler() async throws {
        let start = Date(timeIntervalSince1970: 2_450)
        let clock = ManualPerformanceClock(now: start)
        let sampler = BlockingFirstPerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.beginRealtime()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceToNextDeadline()
        try await waitUntil { await sampler.sampleCount == 1 }

        let diagnosticStart = Task {
            await service.startDiagnostic(scenario: .singleDisplay)
        }
        try await waitUntil { await service.snapshot.isDiagnosticRunning }
        await clock.elapse(5)
        await sampler.releaseFirstSample()
        await diagnosticStart.value
        try await waitUntil {
            let pendingSleepCount = await clock.pendingSleepCount
            let snapshot = await service.snapshot
            return pendingSleepCount == 1 || snapshot.diagnosticSampleCount > 0
        }

        let snapshot = await service.snapshot
        let deadlines = await clock.requestedDeadlines
        XCTAssertEqual(snapshot.diagnosticSampleCount, 0)
        XCTAssertEqual(deadlines.last, start.addingTimeInterval(7))

        await service.cancelDiagnostic()
        await service.endRealtime()
    }

    func testCancelledDiagnosticBeforeFirstRunDoesNotWaitForUncooperativeRealtimeSampler() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 2_460))
        let sampler = BlockingFirstPerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)
        let completion = CompletionProbe()

        await service.beginRealtime()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceToNextDeadline()
        try await waitUntil { await sampler.sampleCount == 1 }

        let start = Task {
            await service.startDiagnostic(scenario: .singleDisplay)
            await completion.markCompleted()
        }
        start.cancel()
        try await waitUntil { await completion.isCompleted }

        let snapshot = await service.snapshot
        XCTAssertTrue(snapshot.isRealtimeActive)
        XCTAssertFalse(snapshot.isDiagnosticRunning)

        await sampler.releaseFirstSample()
        await service.endRealtime()
        await start.value
    }

    func testDiagnosticFailsWithoutReportInsteadOfBackfillingMissedTicks() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 2_475))
        let sampler = DriftingPerformanceMetricSampler(clock: clock, latency: 1.5)
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, sampler: sampler, reports: reports)

        await service.startDiagnostic(scenario: .paused)
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceToNextDeadline()
        try await waitUntil { !(await service.snapshot.isDiagnosticRunning) }

        let snapshot = await service.snapshot
        XCTAssertNil(snapshot.completedReport)
        XCTAssertNotNil(snapshot.diagnosticErrorDescription)
        XCTAssertEqual(reports.saveCallCount, 0)
    }

    func testConcurrentDiagnosticStartsReserveOnlyOneActiveRunBeforeClockReturns() async throws {
        let clock = ManualPerformanceClock(
            now: Date(timeIntervalSince1970: 2_500),
            shouldBlockNow: true
        )
        let service = makeService(clock: clock)

        let firstStart = Task { await service.startDiagnostic(scenario: .twoDisplays) }
        try await waitUntil { await clock.pendingNowCount == 1 }
        let duplicateStart = Task { await service.startDiagnostic(scenario: .paused) }
        for _ in 0..<20 { await Task.yield() }

        let pendingNowCount = await clock.pendingNowCount
        XCTAssertEqual(pendingNowCount, 1)

        await clock.releaseNow()
        await firstStart.value
        await duplicateStart.value
        let snapshot = await service.snapshot
        XCTAssertTrue(snapshot.isDiagnosticRunning)
        XCTAssertEqual(snapshot.diagnosticScenario, .twoDisplays)

        await service.cancelDiagnostic()
    }

    func testCancelDiagnosticCancelsPendingStartupWithoutReleasingClock() async throws {
        let clock = ManualPerformanceClock(
            now: Date(timeIntervalSince1970: 2_625),
            shouldBlockNow: true
        )
        let service = makeService(clock: clock)
        let completion = CompletionProbe()

        let start = Task { await service.startDiagnostic(scenario: .singleDisplay) }
        try await waitUntil { await clock.pendingNowCount == 1 }
        let cancellation = Task {
            await service.cancelDiagnostic()
            await completion.markCompleted()
        }
        try await waitUntil { await completion.isCompleted }

        let pendingNowCount = await clock.pendingNowCount
        let snapshot = await service.snapshot
        XCTAssertEqual(pendingNowCount, 0)
        XCTAssertFalse(snapshot.isDiagnosticRunning)

        await clock.releaseNow()
        await start.value
        await cancellation.value
    }

    func testStopCancelsPendingStartupWithoutReleasingClock() async throws {
        let clock = ManualPerformanceClock(
            now: Date(timeIntervalSince1970: 2_675),
            shouldBlockNow: true
        )
        let service = makeService(clock: clock)
        let completion = CompletionProbe()

        let start = Task { await service.startDiagnostic(scenario: .singleDisplay) }
        try await waitUntil { await clock.pendingNowCount == 1 }
        let stopping = Task {
            await service.stop()
            await completion.markCompleted()
        }
        try await waitUntil { await completion.isCompleted }

        let pendingNowCount = await clock.pendingNowCount
        let snapshot = await service.snapshot
        XCTAssertEqual(pendingNowCount, 0)
        XCTAssertFalse(snapshot.isDiagnosticRunning)

        await clock.releaseNow()
        await start.value
        await stopping.value
    }

    func testStopCancelsDiagnosticWhileItsStartTimeIsPending() async throws {
        let clock = ManualPerformanceClock(
            now: Date(timeIntervalSince1970: 2_750),
            shouldBlockNow: true
        )
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, reports: reports)
        let start = Task { await service.startDiagnostic(scenario: .singleDisplay) }
        try await waitUntil { await clock.pendingNowCount == 1 }

        await service.stop()
        let stoppedSnapshot = await service.snapshot
        XCTAssertFalse(stoppedSnapshot.isDiagnosticRunning)
        XCTAssertNil(stoppedSnapshot.completedReport)
        XCTAssertEqual(reports.saveCallCount, 0)

        await clock.releaseNow()
        await start.value
        let finalSnapshot = await service.snapshot
        XCTAssertFalse(finalSnapshot.isDiagnosticRunning)
        XCTAssertEqual(reports.saveCallCount, 0)
    }

    func testCancelDiagnosticProducesNoCompletedOrPersistedReport() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 3_000))
        let sampler = SequencePerformanceMetricSampler()
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, sampler: sampler, reports: reports)

        await service.startDiagnostic(scenario: .singleDisplay)
        for expectedCount in 1...5 {
            try await waitUntil { await clock.pendingSleepCount == 1 }
            await clock.advanceOneSecond()
            try await waitUntil { await sampler.sampleCount == expectedCount }
        }

        await service.cancelDiagnostic()
        let snapshot = await service.snapshot
        let pendingSleepCount = await clock.pendingSleepCount
        XCTAssertFalse(snapshot.isDiagnosticRunning)
        XCTAssertNil(snapshot.completedReport)
        XCTAssertEqual(pendingSleepCount, 0)
        for _ in 0..<30 { await clock.advanceOneSecond() }
        await Task.yield()

        let sampleCount = await sampler.sampleCount
        XCTAssertEqual(sampleCount, 5)
        XCTAssertEqual(reports.saveCallCount, 0)
    }

    func testStopCancelsRealtimeAndIncompleteDiagnosticWithoutPersisting() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 4_000))
        let sampler = SequencePerformanceMetricSampler()
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, sampler: sampler, reports: reports)

        await service.beginRealtime()
        await service.startDiagnostic(scenario: .paused)
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceOneSecond()
        try await waitUntil { await sampler.sampleCount == 1 }

        await service.stop()
        let snapshot = await service.snapshot
        XCTAssertFalse(snapshot.isRealtimeActive)
        XCTAssertFalse(snapshot.isDiagnosticRunning)
        XCTAssertNil(snapshot.completedReport)
        let pendingSleepCount = await clock.pendingSleepCount
        XCTAssertEqual(pendingSleepCount, 0)
        XCTAssertEqual(reports.saveCallCount, 0)
    }

    func testStopWaitsForDiagnosticAlreadyCancellingInsideSampler() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 4_500))
        let sampler = BlockingFirstPerformanceMetricSampler()
        let reports = RecordingPerformanceReportStore()
        let service = makeService(clock: clock, sampler: sampler, reports: reports)
        let stopCompletion = CompletionProbe()

        await service.startDiagnostic(scenario: .paused)
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceToNextDeadline()
        try await waitUntil { await sampler.sampleCount == 1 }

        let cancellation = Task { await service.cancelDiagnostic() }
        try await waitUntil { !(await service.snapshot.isDiagnosticRunning) }
        let stopping = Task {
            await service.stop()
            await stopCompletion.markCompleted()
        }
        for _ in 0..<20 { await Task.yield() }

        let completedBeforeRelease = await stopCompletion.isCompleted
        XCTAssertFalse(completedBeforeRelease)

        await sampler.releaseFirstSample()
        await cancellation.value
        await stopping.value
        let completedAfterRelease = await stopCompletion.isCompleted
        XCTAssertTrue(completedAfterRelease)
        XCTAssertEqual(reports.saveCallCount, 0)
    }

    func testSaveFailureRetainsCompletedReportAndRetryClearsFailure() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 5_000))
        let sampler = SequencePerformanceMetricSampler()
        let reports = RecordingPerformanceReportStore(shouldFail: true)
        let service = makeService(clock: clock, sampler: sampler, reports: reports)

        await service.startDiagnostic(scenario: .singleDisplay)
        try await completeDiagnostic(service: service, clock: clock)

        var snapshot = await service.snapshot
        let retainedReport = try XCTUnwrap(snapshot.completedReport)
        XCTAssertFalse(snapshot.isDiagnosticRunning)
        XCTAssertNotNil(snapshot.reportSaveErrorDescription)
        XCTAssertEqual(reports.saveCallCount, 1)
        XCTAssertTrue(reports.savedReports.isEmpty)

        reports.setShouldFail(false)
        await service.retrySaveCompletedReport()

        snapshot = await service.snapshot
        XCTAssertEqual(snapshot.completedReport, retainedReport)
        XCTAssertNil(snapshot.reportSaveErrorDescription)
        XCTAssertEqual(reports.saveCallCount, 2)
        XCTAssertEqual(reports.savedReports, [retainedReport])
    }

    func testUnsavedCompletedReportBlocksReplacementDiagnosticUntilRetrySucceeds() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 5_500))
        let reports = RecordingPerformanceReportStore(shouldFail: true)
        let service = makeService(clock: clock, reports: reports)

        await service.startDiagnostic(scenario: .singleDisplay)
        try await completeDiagnostic(service: service, clock: clock)
        let failedSnapshot = await service.snapshot
        let retainedReport = try XCTUnwrap(failedSnapshot.completedReport)

        await service.startDiagnostic(scenario: .paused)
        let blockedSnapshot = await service.snapshot
        XCTAssertFalse(blockedSnapshot.isDiagnosticRunning)
        XCTAssertEqual(blockedSnapshot.completedReport, retainedReport)
        XCTAssertNotNil(blockedSnapshot.reportSaveErrorDescription)
        let pendingSleepCount = await clock.pendingSleepCount
        XCTAssertEqual(pendingSleepCount, 0)

        reports.setShouldFail(false)
        await service.retrySaveCompletedReport()
        await service.startDiagnostic(scenario: .paused)
        let retrySnapshot = await service.snapshot
        XCTAssertTrue(retrySnapshot.isDiagnosticRunning)

        await service.cancelDiagnostic()
    }

    func testRuntimeUpdatesPublishAndCompletedDiagnosticUsesLatestContext() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 6_000))
        let service = makeService(clock: clock)
        let runtime = populatedRuntimeSnapshot()
        var events = await service.events().makeAsyncIterator()

        let initialEvent = await events.next()
        XCTAssertEqual(initialEvent?.runtime, PerformanceRuntimeContext(snapshot: .empty))
        await service.startDiagnostic(scenario: .twoDisplays)
        await service.update(runtime: runtime)

        let nextEvent = await events.next()
        let updated = try XCTUnwrap(nextEvent)
        XCTAssertTrue(updated.isDiagnosticRunning)
        XCTAssertEqual(updated.runtime, PerformanceRuntimeContext(snapshot: runtime))

        try await completeDiagnostic(service: service, clock: clock)
        let finalSnapshot = await service.snapshot
        let report = try XCTUnwrap(finalSnapshot.completedReport)
        XCTAssertEqual(report.activeDisplayCount, 1)
        XCTAssertEqual(report.activeSessionCount, 1)
        XCTAssertEqual(report.activeResourceCount, 1)
        XCTAssertEqual(report.resourceCreationCount, 7)
        XCTAssertEqual(report.pauseReasons, [.thermalPressure])
    }

    func testEventsKeepOnlyNewestPendingSnapshot() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 6_250))
        let service = makeService(clock: clock)
        var events = await service.events().makeAsyncIterator()
        _ = await events.next()

        await service.update(runtime: populatedRuntimeSnapshot(resourceCreationCount: 1))
        await service.update(runtime: populatedRuntimeSnapshot(resourceCreationCount: 2))

        let nextEvent = await events.next()
        let latest = try XCTUnwrap(nextEvent)
        XCTAssertEqual(latest.runtime.resourceCreationCount, 2)
    }

    func testDiagnosticErrorDoesNotExposeUnderlyingAbsolutePath() async throws {
        let clock = ManualPerformanceClock(now: Date(timeIntervalSince1970: 6_500))
        let sampler = PathLeakingPerformanceMetricSampler()
        let service = makeService(clock: clock, sampler: sampler)

        await service.startDiagnostic(scenario: .singleDisplay)
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.advanceToNextDeadline()
        try await waitUntil { !(await service.snapshot.isDiagnosticRunning) }

        let snapshot = await service.snapshot
        XCTAssertEqual(snapshot.diagnosticError, .samplingFailed)
        XCTAssertFalse(snapshot.diagnosticErrorDescription?.contains("/Users/example/Secret.mov") ?? false)
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

private extension PerformanceDiagnosticsServiceTests {
    func makeService(
        clock: any PerformanceClock,
        sampler: any PerformanceMetricSampling = SequencePerformanceMetricSampler(),
        reports: RecordingPerformanceReportStore = RecordingPerformanceReportStore()
    ) -> PerformanceDiagnosticsService {
        PerformanceDiagnosticsService(
            sampler: sampler,
            clock: clock,
            reportStore: reports,
            machineInformation: PerformanceMachineInformation(
                chip: .appleM4,
                physicalMemoryBytes: 16_000_000_000,
                macOSVersion: .macOS26
            )
        )
    }

    func completeDiagnostic(
        service: PerformanceDiagnosticsService,
        clock: ManualPerformanceClock
    ) async throws {
        for expectedCount in 1...30 {
            try await waitUntil { await clock.pendingSleepCount == 1 }
            await clock.advanceToNextDeadline()
            try await waitUntil {
                let snapshot = await service.snapshot
                return snapshot.diagnosticSampleCount == expectedCount
            }
        }
        try await waitUntil { !(await service.snapshot.isDiagnosticRunning) }
    }

    func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
        throw TestWaitError.timedOut
    }
}

private enum TestWaitError: Error {
    case timedOut
}

private final class StubRuntimeMetricSampler: RuntimeMetricSampling, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSample: RuntimeMetricSample
    private var callCount = 0

    init(sample: RuntimeMetricSample) {
        storedSample = sample
    }

    var sampleCallCount: Int { lock.withLock { callCount } }

    func sample() throws -> RuntimeMetricSample {
        lock.withLock { callCount += 1 }
        return storedSample
    }
}

private actor SequencePerformanceMetricSampler: PerformanceMetricSampling {
    private(set) var timestamps: [Date] = []
    var sampleCount: Int { timestamps.count }

    func sample(at timestamp: Date) async throws -> PerformanceSample {
        timestamps.append(timestamp)
        return PerformanceSample(
            timestamp: timestamp,
            cpuPercent: Double(timestamps.count),
            residentBytes: UInt64(timestamps.count * 100)
        )
    }
}

private actor DriftingPerformanceMetricSampler: PerformanceMetricSampling {
    private let clock: ManualPerformanceClock
    private let latency: TimeInterval
    private(set) var timestamps: [Date] = []

    init(clock: ManualPerformanceClock, latency: TimeInterval) {
        self.clock = clock
        self.latency = latency
    }

    func sample(at timestamp: Date) async throws -> PerformanceSample {
        timestamps.append(timestamp)
        await clock.elapse(latency)
        return PerformanceSample(timestamp: timestamp, cpuPercent: 1, residentBytes: 100)
    }
}

private actor BlockingFirstPerformanceMetricSampler: PerformanceMetricSampling {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sampleCount = 0

    func sample(at timestamp: Date) async throws -> PerformanceSample {
        sampleCount += 1
        if sampleCount == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
        return PerformanceSample(timestamp: timestamp, cpuPercent: 1, residentBytes: 100)
    }

    func releaseFirstSample() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PathLeakingPerformanceMetricSampler: PerformanceMetricSampling {
    func sample(at timestamp: Date) async throws -> PerformanceSample {
        throw PathLeakingPerformanceMetricSamplerError.failure("/Users/example/Secret.mov")
    }
}

private actor CancellationErrorPerformanceMetricSampler: PerformanceMetricSampling {
    func sample(at timestamp: Date) async throws -> PerformanceSample {
        throw CancellationError()
    }
}

private enum PathLeakingPerformanceMetricSamplerError: Error {
    case failure(String)
}

private actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor CancellationErrorPerformanceClock: PerformanceClock {
    private let currentDate: Date

    init(now: Date) {
        currentDate = now
    }

    func now() async -> Date { currentDate }

    func sleep(until deadline: Date) async throws {
        throw CancellationError()
    }
}

private actor ManualPerformanceClock: PerformanceClock {
    private struct NowSleeper {
        let id: UUID
        let continuation: CheckedContinuation<Date, Never>
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var currentDate: Date
    private let shouldBlockNow: Bool
    private var blockedNowCalls = 0
    private var nowSleepers: [NowSleeper] = []
    private var sleepers: [Sleeper] = []
    private(set) var requestedDeadlines: [Date] = []

    init(now: Date, shouldBlockNow: Bool = false) {
        currentDate = now
        self.shouldBlockNow = shouldBlockNow
    }

    var pendingNowCount: Int { nowSleepers.count }
    var pendingSleepCount: Int { sleepers.count }

    func now() async -> Date {
        guard shouldBlockNow || blockedNowCalls > 0 else { return currentDate }
        if blockedNowCalls > 0 { blockedNowCalls -= 1 }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: currentDate)
                } else {
                    nowSleepers.append(NowSleeper(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelNow(id: id) }
        }
    }

    func blockNextNow() {
        blockedNowCalls += 1
    }

    func releaseNow() {
        let pending = nowSleepers
        nowSleepers.removeAll()
        for sleeper in pending { sleeper.continuation.resume(returning: currentDate) }
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= currentDate {
                    continuation.resume()
                } else {
                    requestedDeadlines.append(deadline)
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advanceOneSecond() {
        currentDate = currentDate.addingTimeInterval(1)
        resumeDueSleepers()
    }

    func advanceToNextDeadline() {
        if let deadline = sleepers.map(\.deadline).min() {
            currentDate = max(currentDate, deadline)
        }
        resumeDueSleepers()
    }

    private func resumeDueSleepers() {
        let due = sleepers.filter { $0.deadline <= currentDate }
        sleepers.removeAll { $0.deadline <= currentDate }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func elapse(_ duration: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(duration)
    }

    private func cancel(id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = sleepers.remove(at: index)
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private func cancelNow(id: UUID) {
        guard let index = nowSleepers.firstIndex(where: { $0.id == id }) else { return }
        let sleeper = nowSleepers.remove(at: index)
        sleeper.continuation.resume(returning: currentDate)
    }
}

private final class RecordingPerformanceReportStore: PerformanceReportSaving, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail: Bool
    private var callCount = 0
    private var reports: [PerformanceDiagnosticReport] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    var saveCallCount: Int { lock.withLock { callCount } }
    var savedReports: [PerformanceDiagnosticReport] { lock.withLock { reports } }

    func setShouldFail(_ shouldFail: Bool) {
        lock.withLock { self.shouldFail = shouldFail }
    }

    func save(_ report: PerformanceDiagnosticReport) throws {
        let fails = lock.withLock { () -> Bool in
            callCount += 1
            return shouldFail
        }
        if fails { throw RecordingReportError.writeFailed }
        lock.withLock { reports.append(report) }
    }
}

private enum RecordingReportError: Error {
    case writeFailed
}

private func populatedRuntimeSnapshot(resourceCreationCount: Int = 7) -> WallpaperRuntimeSnapshot {
    let mediaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let resourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    return WallpaperRuntimeSnapshot(
        runtime: RuntimeSnapshot(
            sessions: [
                RuntimeDisplaySession(
                    displayID: DisplayID("display-a"),
                    mediaID: mediaID,
                    resourceID: resourceID
                ),
            ],
            resourceReferenceCounts: [resourceID: 1],
            pauseReasons: [.thermalPressure],
            failures: [],
            resourceCreationCount: resourceCreationCount
        ),
        surfaceFailures: []
    )
}
