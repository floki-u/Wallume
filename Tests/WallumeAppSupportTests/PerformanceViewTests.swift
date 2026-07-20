import AppKit
import SwiftUI
import XCTest
@testable import WallumeAppSupport

final class PerformanceViewTests: XCTestCase {
    func testIdleAndRealtimePageStates() {
        let idle = PerformancePageViewState(snapshot: snapshot())
        XCTAssertEqual(idle.mode, .idle)
        XCTAssertTrue(idle.canStartDiagnostic)

        let realtime = PerformancePageViewState(snapshot: snapshot(isRealtimeActive: true))
        XCTAssertEqual(realtime.mode, .realtime)
        XCTAssertTrue(realtime.canStartDiagnostic)
    }

    func testRunningCompletedAndSaveFailurePageStates() {
        let running = PerformancePageViewState(snapshot: snapshot(isDiagnosticRunning: true, diagnosticSampleCount: 12))
        XCTAssertEqual(running.mode, .running)
        XCTAssertEqual(running.progress, 12.0 / 30.0)
        XCTAssertTrue(running.canCancelDiagnostic)

        let completed = PerformancePageViewState(snapshot: snapshot(completedReport: report()))
        XCTAssertEqual(completed.mode, .completed)
        XCTAssertTrue(completed.canExportReport)

        let failed = PerformancePageViewState(snapshot: snapshot(completedReport: report(), reportSaveError: .reportSaveFailed))
        XCTAssertEqual(failed.mode, .saveFailed)
        XCTAssertTrue(failed.canRetrySave)
        XCTAssertTrue(failed.canExportReport)
    }

    @MainActor
    func testSwiftUIViewHasNonzeroFittingSize() {
        let host = NSHostingView(rootView: PerformanceView(store: PerformanceFeatureStore(service: PerformanceDiagnosticsService())))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}

private func snapshot(
    isRealtimeActive: Bool = false,
    isDiagnosticRunning: Bool = false,
    diagnosticSampleCount: Int = 0,
    completedReport: PerformanceDiagnosticReport? = nil,
    reportSaveError: PerformanceDiagnosticsUserError? = nil
) -> PerformanceDiagnosticsSnapshot {
    PerformanceDiagnosticsSnapshot(
        realtimeSummary: PerformanceSummary(samples: []),
        runtime: .init(activeDisplayCount: 0, activeSessionCount: 0, activeResourceCount: 0, sharedResourceCount: 0, sharedResourceReferenceCount: 0, resourceCreationCount: 0, pauseReasons: []),
        isRealtimeActive: isRealtimeActive, isDiagnosticRunning: isDiagnosticRunning,
        diagnosticScenario: isDiagnosticRunning ? .singleDisplay : nil,
        diagnosticSampleCount: diagnosticSampleCount, diagnosticSampleLimit: 30,
        completedReport: completedReport, realtimeError: nil,
        reportSaveError: reportSaveError, diagnosticError: nil
    )
}

private func report() -> PerformanceDiagnosticReport {
    PerformanceDiagnosticReport(startedAt: .distantPast, duration: 30, scenario: .singleDisplay,
        summary: PerformanceSummary(samples: []),
        runtime: .init(activeDisplayCount: 0, activeSessionCount: 0, activeResourceCount: 0, sharedResourceCount: 0, sharedResourceReferenceCount: 0, resourceCreationCount: 0, pauseReasons: []),
        chip: .appleM1, physicalMemoryBytes: 8_000_000_000, macOSVersion: .macOS14)
}
