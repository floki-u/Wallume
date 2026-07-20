import Darwin
import Foundation

public protocol PerformanceClock: Sendable {
    func now() async -> Date
    func sleep(until deadline: Date) async throws
}

public struct SystemPerformanceClock: PerformanceClock {
    public init() {}

    public func now() async -> Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let delay = deadline.timeIntervalSinceNow
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        try Task.checkCancellation()
    }
}

public protocol PerformanceReportSaving: Sendable {
    func save(_ report: PerformanceDiagnosticReport) throws
}

extension PerformanceReportStore: PerformanceReportSaving {}

public struct PerformanceMachineInformation: Equatable, Sendable {
    public let chip: PerformanceChip
    public let physicalMemoryBytes: UInt64
    public let macOSVersion: PerformanceMacOSVersion

    public init(
        chip: PerformanceChip,
        physicalMemoryBytes: UInt64,
        macOSVersion: PerformanceMacOSVersion
    ) {
        self.chip = chip
        self.physicalMemoryBytes = physicalMemoryBytes
        self.macOSVersion = macOSVersion
    }

    public static var current: PerformanceMachineInformation {
        let process = ProcessInfo.processInfo
        return PerformanceMachineInformation(
            chip: currentChip(),
            physicalMemoryBytes: process.physicalMemory,
            macOSVersion: macOSVersion(process.operatingSystemVersion.majorVersion)
        )
    }

    private static func currentChip() -> PerformanceChip {
        let brand = sysctlString("machdep.cpu.brand_string") ?? ""
        if brand.localizedCaseInsensitiveContains("Apple M1") { return .appleM1 }
        if brand.localizedCaseInsensitiveContains("Apple M2") { return .appleM2 }
        if brand.localizedCaseInsensitiveContains("Apple M3") { return .appleM3 }
        if brand.localizedCaseInsensitiveContains("Apple M4") { return .appleM4 }
        if brand.localizedCaseInsensitiveContains("Intel") { return .intel }
        #if arch(x86_64)
        return .intel
        #else
        return .unknown
        #endif
    }

    private static func macOSVersion(_ majorVersion: Int) -> PerformanceMacOSVersion {
        switch majorVersion {
        case 14: .macOS14
        case 15: .macOS15
        case 26: .macOS26
        default: .unknown
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

/// An immutable view of all performance state that can be safely sent to UI observers.
public struct PerformanceDiagnosticsSnapshot: Equatable, Sendable {
    public let realtimeSummary: PerformanceSummary
    public let runtime: PerformanceRuntimeContext
    public let isRealtimeActive: Bool
    public let isDiagnosticRunning: Bool
    public let diagnosticScenario: PerformanceDiagnosticScenario?
    public let diagnosticSampleCount: Int
    public let diagnosticSampleLimit: Int
    public let completedReport: PerformanceDiagnosticReport?
    public let reportSaveErrorDescription: String?
    public let diagnosticErrorDescription: String?

    public init(
        realtimeSummary: PerformanceSummary,
        runtime: PerformanceRuntimeContext,
        isRealtimeActive: Bool,
        isDiagnosticRunning: Bool,
        diagnosticScenario: PerformanceDiagnosticScenario?,
        diagnosticSampleCount: Int,
        diagnosticSampleLimit: Int,
        completedReport: PerformanceDiagnosticReport?,
        reportSaveErrorDescription: String?,
        diagnosticErrorDescription: String?
    ) {
        self.realtimeSummary = realtimeSummary
        self.runtime = runtime
        self.isRealtimeActive = isRealtimeActive
        self.isDiagnosticRunning = isDiagnosticRunning
        self.diagnosticScenario = diagnosticScenario
        self.diagnosticSampleCount = diagnosticSampleCount
        self.diagnosticSampleLimit = diagnosticSampleLimit
        self.completedReport = completedReport
        self.reportSaveErrorDescription = reportSaveErrorDescription
        self.diagnosticErrorDescription = diagnosticErrorDescription
    }
}

public actor PerformanceDiagnosticsService {
    public static let diagnosticSampleLimit = 30

    private let sampler: any PerformanceMetricSampling
    private let clock: any PerformanceClock
    private let reportStore: any PerformanceReportSaving
    private let machineInformation: PerformanceMachineInformation

    private var realtimeSummary = PerformanceSummary(samples: [])
    private var runtime = PerformanceRuntimeContext(snapshot: .empty)
    private var realtimeTask: Task<Void, Never>?
    private var realtimeTaskID: UUID?
    private var isRealtimeActive = false

    private var diagnosticTask: Task<Void, Never>?
    private var diagnosticID: UUID?
    private var diagnosticScenario: PerformanceDiagnosticScenario?
    private var diagnosticSamples: [PerformanceSample] = []
    private var completedReport: PerformanceDiagnosticReport?
    private var reportSaveErrorDescription: String?
    private var diagnosticErrorDescription: String?

    private var continuations = [UUID: AsyncStream<PerformanceDiagnosticsSnapshot>.Continuation]()
    private var tasksBeingCancelled = [UUID: Task<Void, Never>]()
    private var isStopped = false

    public init(
        sampler: any PerformanceMetricSampling = PerformanceMetricSampler(),
        clock: any PerformanceClock = SystemPerformanceClock(),
        reportStore: any PerformanceReportSaving = PerformanceReportStore(),
        machineInformation: PerformanceMachineInformation = .current
    ) {
        self.sampler = sampler
        self.clock = clock
        self.reportStore = reportStore
        self.machineInformation = machineInformation
    }

    public var snapshot: PerformanceDiagnosticsSnapshot {
        PerformanceDiagnosticsSnapshot(
            realtimeSummary: realtimeSummary,
            runtime: runtime,
            isRealtimeActive: isRealtimeActive,
            isDiagnosticRunning: diagnosticID != nil,
            diagnosticScenario: diagnosticScenario,
            diagnosticSampleCount: diagnosticSamples.count,
            diagnosticSampleLimit: Self.diagnosticSampleLimit,
            completedReport: completedReport,
            reportSaveErrorDescription: reportSaveErrorDescription,
            diagnosticErrorDescription: diagnosticErrorDescription
        )
    }

    public func events() -> AsyncStream<PerformanceDiagnosticsSnapshot> {
        let id = UUID()
        let current = snapshot
        return AsyncStream { continuation in
            continuation.yield(current)
            guard !isStopped else {
                continuation.finish()
                return
            }
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func beginRealtime() {
        guard !isStopped, !isRealtimeActive else { return }
        isRealtimeActive = true
        publish()
        startRealtimeSamplingIfNeeded()
    }

    public func endRealtime() async {
        guard isRealtimeActive else { return }
        isRealtimeActive = false
        publish()
        if diagnosticTask == nil {
            await cancelRealtimeSampling()
            startRealtimeSamplingIfNeeded()
        }
    }

    public func update(runtime snapshot: WallpaperRuntimeSnapshot) {
        guard !isStopped else { return }
        runtime = PerformanceRuntimeContext(snapshot: snapshot)
        publish()
    }

    public func startDiagnostic(scenario: PerformanceDiagnosticScenario) async {
        guard !isStopped,
              diagnosticID == nil,
              tasksBeingCancelled.isEmpty,
              reportSaveErrorDescription == nil else { return }
        let id = UUID()
        diagnosticID = id
        diagnosticScenario = scenario
        diagnosticSamples = []
        completedReport = nil
        reportSaveErrorDescription = nil
        diagnosticErrorDescription = nil
        publish()
        await cancelRealtimeSampling()
        guard !isStopped, diagnosticID == id else {
            startRealtimeSamplingIfNeeded()
            return
        }
        let startedAt = await clock.now()
        guard !isStopped, diagnosticID == id else {
            startRealtimeSamplingIfNeeded()
            return
        }
        diagnosticTask = Task { [weak self] in
            await self?.runDiagnostic(id: id, scenario: scenario, startedAt: startedAt)
        }
    }

    public func cancelDiagnostic() async {
        guard diagnosticID != nil else { return }
        let task = diagnosticTask
        diagnosticID = nil
        diagnosticTask = nil
        diagnosticScenario = nil
        diagnosticSamples = []
        diagnosticErrorDescription = nil
        publish()
        if let task { await cancelAndWait(task) }
        startRealtimeSamplingIfNeeded()
    }

    public func retrySaveCompletedReport() {
        guard !isStopped,
              reportSaveErrorDescription != nil,
              let completedReport else { return }
        save(completedReport)
        publish()
    }

    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        isRealtimeActive = false
        realtimeTaskID = nil
        diagnosticID = nil
        diagnosticScenario = nil
        diagnosticSamples = []
        let realtimeTask = realtimeTask
        let diagnosticTask = diagnosticTask
        let cancellingTasks = Array(tasksBeingCancelled.values)
        self.realtimeTask = nil
        self.diagnosticTask = nil
        publish()
        realtimeTask?.cancel()
        diagnosticTask?.cancel()
        for task in cancellingTasks { task.cancel() }
        await realtimeTask?.value
        await diagnosticTask?.value
        for task in cancellingTasks { await task.value }
        let activeContinuations = continuations.values
        continuations.removeAll()
        for continuation in activeContinuations { continuation.finish() }
    }

    private func runRealtime(id: UUID) async {
        var deadline = (await clock.now()).addingTimeInterval(1)
        while !Task.isCancelled {
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                guard realtimeTaskID == id, isRealtimeActive else { return }
                let sampledAt = await clock.now()
                if sampledAt >= deadline.addingTimeInterval(1) {
                    deadline = sampledAt.addingTimeInterval(1)
                    continue
                }
                let sample = try await sampler.sample(at: sampledAt)
                try Task.checkCancellation()
                guard realtimeTaskID == id, isRealtimeActive else { return }
                realtimeSummary = realtimeSummary.appending(sample)
                publish()
                let nextDeadline = deadline.addingTimeInterval(1)
                let finishedAt = await clock.now()
                deadline = nextDeadline > finishedAt
                    ? nextDeadline
                    : finishedAt.addingTimeInterval(1)
            } catch is CancellationError {
                return
            } catch {
                guard realtimeTaskID == id else { return }
                deadline = (await clock.now()).addingTimeInterval(1)
            }
        }
    }

    private func runDiagnostic(
        id: UUID,
        scenario: PerformanceDiagnosticScenario,
        startedAt: Date
    ) async {
        do {
            for sampleIndex in 1...Self.diagnosticSampleLimit {
                let deadline = startedAt.addingTimeInterval(TimeInterval(sampleIndex))
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                guard diagnosticID == id else { return }
                let sampledAt = await clock.now()
                guard sampledAt < deadline.addingTimeInterval(1) else {
                    throw PerformanceDiagnosticsServiceError.missedDiagnosticDeadline
                }
                let sample = try await sampler.sample(at: sampledAt)
                try Task.checkCancellation()
                guard diagnosticID == id else { return }
                diagnosticSamples.append(sample)
                if isRealtimeActive {
                    realtimeSummary = realtimeSummary.appending(sample)
                }
                publish()
            }
            completeDiagnostic(id: id, scenario: scenario, startedAt: startedAt)
        } catch is CancellationError {
            return
        } catch {
            failDiagnostic(id: id, error: error)
        }
    }

    private func completeDiagnostic(
        id: UUID,
        scenario: PerformanceDiagnosticScenario,
        startedAt: Date
    ) {
        guard diagnosticID == id else { return }
        let report = PerformanceDiagnosticReport(
            startedAt: startedAt,
            duration: TimeInterval(Self.diagnosticSampleLimit),
            scenario: scenario,
            summary: PerformanceSummary(samples: diagnosticSamples),
            runtime: runtime,
            chip: machineInformation.chip,
            physicalMemoryBytes: machineInformation.physicalMemoryBytes,
            macOSVersion: machineInformation.macOSVersion
        )
        diagnosticID = nil
        diagnosticTask = nil
        diagnosticScenario = scenario
        completedReport = report
        diagnosticErrorDescription = nil
        save(report)
        publish()
        startRealtimeSamplingIfNeeded()
    }

    private func failDiagnostic(id: UUID, error: any Error) {
        guard diagnosticID == id else { return }
        diagnosticID = nil
        diagnosticTask = nil
        diagnosticScenario = nil
        diagnosticSamples = []
        diagnosticErrorDescription = String(describing: error)
        publish()
        startRealtimeSamplingIfNeeded()
    }

    private func save(_ report: PerformanceDiagnosticReport) {
        do {
            try reportStore.save(report)
            reportSaveErrorDescription = nil
        } catch {
            reportSaveErrorDescription = String(describing: error)
        }
    }

    private func publish() {
        let current = snapshot
        for continuation in continuations.values { continuation.yield(current) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func startRealtimeSamplingIfNeeded() {
        guard !isStopped,
              isRealtimeActive,
              diagnosticID == nil,
              tasksBeingCancelled.isEmpty,
              realtimeTask == nil else { return }
        let id = UUID()
        realtimeTaskID = id
        realtimeTask = Task { [weak self] in
            await self?.runRealtime(id: id)
        }
    }

    private func cancelRealtimeSampling() async {
        guard let task = realtimeTask else { return }
        realtimeTaskID = nil
        realtimeTask = nil
        await cancelAndWait(task)
    }

    private func cancelAndWait(_ task: Task<Void, Never>) async {
        let id = UUID()
        tasksBeingCancelled[id] = task
        task.cancel()
        await task.value
        tasksBeingCancelled.removeValue(forKey: id)
    }
}

private enum PerformanceDiagnosticsServiceError: Error {
    case missedDiagnosticDeadline
}
