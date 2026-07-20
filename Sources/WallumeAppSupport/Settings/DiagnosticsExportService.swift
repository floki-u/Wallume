import Foundation
import WallumeCore

public final class DiagnosticsExportCommitAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    private var activeCommits = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func beginCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminated else { return false }
        activeCommits += 1
        return true
    }

    public func finishCommit() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        precondition(activeCommits > 0, "A diagnostics commit must finish exactly once.")
        activeCommits -= 1
        if terminated, activeCommits == 0 {
            waiters = drainWaiters
            drainWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    public func terminateAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            terminated = true
            if activeCommits == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

public enum DiagnosticsSourceStatus: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public struct DiagnosticsSettingsSummary: Codable, Equatable, Sendable {
    public let launchAtLogin: Bool
    public let openGalleryAtLaunch: Bool
    public let pauseInLowPowerMode: Bool

    public init(settings: ApplicationSettings) {
        launchAtLogin = settings.launchAtLogin
        openGalleryAtLaunch = settings.openGalleryAtLaunch
        pauseInLowPowerMode = settings.pauseInLowPowerMode
    }
}

public struct DiagnosticsRecentTransactionSummary: Codable, Equatable, Sendable {
    public let status: DiagnosticsSourceStatus
    public let completedCount: Int
    public let failedCount: Int

    public init(status: DiagnosticsSourceStatus, completedCount: Int, failedCount: Int) {
        self.status = status
        self.completedCount = completedCount
        self.failedCount = failedCount
    }

    public static let unavailable = DiagnosticsRecentTransactionSummary(
        status: .unavailable,
        completedCount: 0,
        failedCount: 0
    )
}

public struct DiagnosticsPerformanceSummary: Codable, Equatable, Sendable {
    public let status: DiagnosticsSourceStatus
    public let report: PerformanceDiagnosticReport?

    public init(status: DiagnosticsSourceStatus, report: PerformanceDiagnosticReport?) {
        self.status = status
        self.report = report
    }
}

public enum DiagnosticsCurrentErrorSummary: String, Codable, Equatable, Sendable {
    case none
    case present
    case unavailable
}

public struct DiagnosticsBuildSystemInfo: Codable, Equatable, Sendable {
    public let productVersion: String
    public let buildNumber: String
    public let systemVersion: String
    public let architecture: String

    public init(
        productVersion: String,
        buildNumber: String,
        systemVersion: String,
        architecture: String
    ) {
        self.productVersion = Self.version(productVersion)
        self.buildNumber = Self.buildNumber(buildNumber)
        self.systemVersion = Self.systemVersion(systemVersion)
        self.architecture = Self.architecture(architecture)
    }

    private static let unavailable = "unavailable"

    private static func version(_ value: String) -> String {
        guard value.contains(where: \.isWholeNumber),
              value.allSatisfy({ $0.isWholeNumber || ".-+".contains($0) }) else {
            return unavailable
        }
        return value
    }

    private static func buildNumber(_ value: String) -> String {
        guard !value.isEmpty, value.allSatisfy(\.isWholeNumber) else { return unavailable }
        return value
    }

    private static func systemVersion(_ value: String) -> String {
        guard value.hasPrefix("macOS ") else { return unavailable }
        let version = String(value.dropFirst("macOS ".count))
        return Self.version(version) == version ? value : unavailable
    }

    private static func architecture(_ value: String) -> String {
        ["arm64", "x86_64", "unknown"].contains(value) ? value : unavailable
    }
}

public struct DiagnosticsExportDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let settings: DiagnosticsSettingsSummary
    public let lockScreen: LockScreenDiagnosticsSummary
    public let recentTransactions: DiagnosticsRecentTransactionSummary
    public let currentError: DiagnosticsCurrentErrorSummary
    public let performance: DiagnosticsPerformanceSummary
    public let buildSystem: DiagnosticsBuildSystemInfo

    public init(
        settings: DiagnosticsSettingsSummary,
        lockScreen: LockScreenDiagnosticsSummary,
        recentTransactions: DiagnosticsRecentTransactionSummary,
        currentError: DiagnosticsCurrentErrorSummary,
        performance: DiagnosticsPerformanceSummary,
        buildSystem: DiagnosticsBuildSystemInfo
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.settings = settings
        self.lockScreen = lockScreen
        self.recentTransactions = recentTransactions
        self.currentError = currentError
        self.performance = performance
        self.buildSystem = buildSystem
    }
}

public enum DiagnosticsExportUserError: Error, Equatable, LocalizedError, Sendable {
    case writeFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .writeFailed:
            "Unable to export diagnostics. Please try again."
        case .cancelled:
            "Diagnostics export was cancelled."
        }
    }
}

public struct DiagnosticsExportService: Sendable {
    private let settings: @Sendable () -> ApplicationSettings
    private let lockScreenSummary: @Sendable () throws -> LockScreenDiagnosticsSummary
    private let recentTransactionSummary: @Sendable () throws -> DiagnosticsRecentTransactionSummary
    private let currentErrorSummary: @Sendable () throws -> DiagnosticsCurrentErrorSummary
    private let performanceReportStore: any PerformanceReportReading
    private let buildSystemInfo: DiagnosticsBuildSystemInfo
    private let jsonStore: AtomicJSONStore
    private let commitAdmission: DiagnosticsExportCommitAdmission

    public init(
        settings: @escaping @Sendable () -> ApplicationSettings,
        lockScreenSummary: @escaping @Sendable () throws -> LockScreenDiagnosticsSummary,
        recentTransactionSummary: @escaping @Sendable () throws -> DiagnosticsRecentTransactionSummary,
        currentErrorSummary: @escaping @Sendable () throws -> DiagnosticsCurrentErrorSummary = { .unavailable },
        commitAdmission: DiagnosticsExportCommitAdmission = .init(),
        performanceReportStore: any PerformanceReportReading,
        buildSystemInfo: DiagnosticsBuildSystemInfo,
        files: any FileStore
    ) {
        self.settings = settings
        self.lockScreenSummary = lockScreenSummary
        self.recentTransactionSummary = recentTransactionSummary
        self.currentErrorSummary = currentErrorSummary
        self.performanceReportStore = performanceReportStore
        self.buildSystemInfo = buildSystemInfo
        jsonStore = AtomicJSONStore(files: files)
        self.commitAdmission = commitAdmission
    }

    public func export(to destination: URL) async throws {
        do {
            try Task.checkCancellation()
            let document = DiagnosticsExportDocument(
                settings: DiagnosticsSettingsSummary(settings: settings()),
                lockScreen: (try? lockScreenSummary()) ?? .unavailable,
                recentTransactions: (try? recentTransactionSummary()) ?? .unavailable,
                currentError: (try? currentErrorSummary()) ?? .unavailable,
                performance: performanceSummary(),
                buildSystem: buildSystemInfo
            )
            try Task.checkCancellation()
            guard commitAdmission.beginCommit() else { throw CancellationError() }
            defer { commitAdmission.finishCommit() }
            try Task.checkCancellation()
            try jsonStore.write(document, to: destination)
        } catch is CancellationError {
            throw DiagnosticsExportUserError.cancelled
        } catch {
            throw DiagnosticsExportUserError.writeFailed
        }
    }

    private func performanceSummary() -> DiagnosticsPerformanceSummary {
        do {
            guard let report = try performanceReportStore.latest() else {
                return DiagnosticsPerformanceSummary(status: .unavailable, report: nil)
            }
            return DiagnosticsPerformanceSummary(
                status: .available,
                report: report
            )
        } catch {
            return DiagnosticsPerformanceSummary(status: .unavailable, report: nil)
        }
    }
}
