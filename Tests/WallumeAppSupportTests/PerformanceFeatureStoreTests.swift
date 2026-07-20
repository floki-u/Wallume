import Foundation
import XCTest
@testable import WallumeAppSupport

final class PerformanceFeatureStoreTests: XCTestCase {
    @MainActor
    func testPageLifecycleAndDiagnosticActionsDispatchOnlyTheirCommands() async throws {
        let service = PerformanceDiagnosticsService()
        let recorder = PerformanceCommandRecorder()
        let store = PerformanceFeatureStore(
            service: service,
            commands: .init(
                beginRealtime: { await recorder.append("begin") },
                endRealtime: { await recorder.append("end") },
                startDiagnostic: { await recorder.append("start:\($0.rawValue)") },
                cancelDiagnostic: { await recorder.append("cancel") },
                retrySave: { await recorder.append("retry") }
            )
        )

        await store.pageAppeared()
        await store.startDiagnostic(scenario: .twoDisplays)
        await store.cancelDiagnostic()
        await store.retrySave()
        await store.pageDisappeared()

        let values = await recorder.values
        XCTAssertEqual(values, ["begin", "start:two-displays", "cancel", "retry", "end"])
    }

    @MainActor
    func testCommandFailureIsRetainedUntilDismissed() async throws {
        enum TestError: LocalizedError { case failed; var errorDescription: String? { "操作失败" } }
        let store = PerformanceFeatureStore(
            service: PerformanceDiagnosticsService(),
            commands: .init(
                beginRealtime: { throw TestError.failed }, endRealtime: {},
                startDiagnostic: { _ in }, cancelDiagnostic: {}, retrySave: {}
            )
        )

        await store.pageAppeared()
        XCTAssertEqual(store.pageError, "操作失败")
        store.dismissPageError()
        XCTAssertNil(store.pageError)
    }

    @MainActor
    func testExportEncodesOnlyTheCompletedReportJSON() throws {
        let store = PerformanceFeatureStore(service: PerformanceDiagnosticsService())
        XCTAssertThrowsError(try store.makeDiagnosticExportData())
    }
}

private actor PerformanceCommandRecorder {
    private var commands = [String]()
    func append(_ command: String) { commands.append(command) }
    var values: [String] { commands }
}
