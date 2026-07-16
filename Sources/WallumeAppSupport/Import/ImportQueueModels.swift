import Foundation
import WallumeCore

public enum ImportAttemptStatus: String, Equatable, Sendable {
    case waiting, running, imported, duplicate, failed, cancelled
}

public struct ImportAttempt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var status: ImportAttemptStatus
    public var stage: MediaImportStage?
    public var progress: Double?
    public var message: String?

    public init(id: UUID = UUID(), status: ImportAttemptStatus = .waiting) {
        self.id = id; self.status = status
    }
}

public struct ImportQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: URL
    public var attempts: [ImportAttempt]

    public init(id: UUID = UUID(), source: URL, attempts: [ImportAttempt] = [.init()]) {
        self.id = id; self.source = source; self.attempts = attempts
    }
}

public struct ImportQueueSummary: Equatable, Sendable {
    public let imported: Int
    public let duplicate: Int
    public let failed: Int
    public let cancelled: Int
    public let processed: Int
    public let total: Int
}

public struct ImportQueueSnapshot: Equatable, Sendable {
    public let items: [ImportQueueItem]
    public let warnings: [ImportScanWarning]
    public let isActive: Bool

    public var summary: ImportQueueSummary {
        let statuses = items.compactMap { $0.attempts.last?.status }
        let finished = statuses.filter { ![.waiting, .running].contains($0) }
        return ImportQueueSummary(
            imported: statuses.filter { $0 == .imported }.count,
            duplicate: statuses.filter { $0 == .duplicate }.count,
            failed: statuses.filter { $0 == .failed }.count,
            cancelled: statuses.filter { $0 == .cancelled }.count,
            processed: finished.count,
            total: statuses.count
        )
    }
}

public protocol SingleMediaImporting: Sendable {
    func importURL(
        _ source: URL,
        onEvent: @escaping @Sendable (MediaImportEvent) -> Void
    ) async -> MediaImportResult
}

extension MediaImporter: SingleMediaImporting {}
