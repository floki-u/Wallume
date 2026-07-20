import Foundation
import Observation

/// Injectable commands for the performance page. The store owns presentation state only; all
/// sampling, persistence, and cancellation policy stays in `PerformanceDiagnosticsService`.
public struct PerformanceFeatureCommands: Sendable {
    public var beginRealtime: @Sendable () async throws -> Void
    public var endRealtime: @Sendable () async throws -> Void
    public var startDiagnostic: @Sendable (PerformanceDiagnosticScenario) async throws -> Void
    public var cancelDiagnostic: @Sendable () async throws -> Void
    public var retrySave: @Sendable () async throws -> Void

    public init(
        beginRealtime: @escaping @Sendable () async throws -> Void,
        endRealtime: @escaping @Sendable () async throws -> Void,
        startDiagnostic: @escaping @Sendable (PerformanceDiagnosticScenario) async throws -> Void,
        cancelDiagnostic: @escaping @Sendable () async throws -> Void,
        retrySave: @escaping @Sendable () async throws -> Void
    ) {
        self.beginRealtime = beginRealtime
        self.endRealtime = endRealtime
        self.startDiagnostic = startDiagnostic
        self.cancelDiagnostic = cancelDiagnostic
        self.retrySave = retrySave
    }

    public static func service(_ service: PerformanceDiagnosticsService) -> Self {
        Self(
            beginRealtime: { await service.beginRealtime() },
            endRealtime: { await service.endRealtime() },
            startDiagnostic: { await service.startDiagnostic(scenario: $0) },
            cancelDiagnostic: { await service.cancelDiagnostic() },
            retrySave: { await service.retrySaveCompletedReport() }
        )
    }
}

/// Main-actor projection of diagnostic snapshots for one SwiftUI page.
///
/// Page disappearance ends in-memory realtime collection only. It intentionally never cancels
/// a user-triggered diagnostic, so diagnostics continue while the user navigates elsewhere.
@MainActor @Observable
public final class PerformanceFeatureStore {
    public private(set) var snapshot: PerformanceDiagnosticsSnapshot
    public private(set) var pageError: String?

    private let commands: PerformanceFeatureCommands
    private let observation = PerformanceFeatureObservation()

    public init(service: PerformanceDiagnosticsService, commands: PerformanceFeatureCommands? = nil) {
        self.commands = commands ?? .service(service)
        snapshot = PerformanceDiagnosticsSnapshot(
            realtimeSummary: PerformanceSummary(samples: []),
            runtime: PerformanceRuntimeContext(snapshot: .empty),
            isRealtimeActive: false,
            isDiagnosticRunning: false,
            diagnosticScenario: nil,
            diagnosticSampleCount: 0,
            diagnosticSampleLimit: PerformanceDiagnosticsService.diagnosticSampleLimit,
            completedReport: nil,
            realtimeError: nil,
            reportSaveError: nil,
            diagnosticError: nil
        )
        observation.set(Task { [weak self, service] in
            for await value in await service.events() {
                guard !Task.isCancelled else { return }
                self?.receive(value)
            }
        })
    }

    deinit { observation.cancel() }

    public func pageAppeared() async { await perform { try await commands.beginRealtime() } }

    /// Does not cancel diagnostics: their lifecycle belongs to the service/application.
    public func pageDisappeared() async { await perform { try await commands.endRealtime() } }

    public func startDiagnostic(scenario: PerformanceDiagnosticScenario) async {
        await perform { try await commands.startDiagnostic(scenario) }
    }

    public func cancelDiagnostic() async { await perform { try await commands.cancelDiagnostic() } }

    public func retrySave() async { await perform { try await commands.retrySave() } }

    /// Produces an export payload from the already-redacted completed report, with no file I/O.
    public func makeDiagnosticExportData() throws -> Data {
        guard let report = snapshot.completedReport else { throw PerformanceExportError.noCompletedReport }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public func reportPageError(_ message: String) { pageError = message }
    public func dismissPageError() { pageError = nil }

    private func receive(_ value: PerformanceDiagnosticsSnapshot) {
        snapshot = value
        if let error = value.realtimeError ?? value.diagnosticError ?? value.reportSaveError {
            pageError = error.userVisibleDescription
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation() }
        catch { pageError = error.localizedDescription }
    }
}

public enum PerformanceExportError: LocalizedError, Equatable, Sendable {
    case noCompletedReport
    public var errorDescription: String? { "No completed diagnostic report is available to export." }
}

private final class PerformanceFeatureObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}
