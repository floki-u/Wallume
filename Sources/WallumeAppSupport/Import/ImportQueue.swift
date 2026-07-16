import Foundation
import WallumeCore

public actor ImportQueue {
    private let importer: any SingleMediaImporting
    private let scanner: any ImportScanning
    private var items = [ImportQueueItem]()
    private var warnings = [ImportScanWarning]()
    private var processor: Task<Void, Never>?
    private var currentTask: Task<MediaImportResult, Never>?
    private var continuations = [UUID: AsyncStream<ImportQueueSnapshot>.Continuation]()

    public init(importer: any SingleMediaImporting, scanner: any ImportScanning = LocalImportScanner()) {
        self.importer = importer; self.scanner = scanner
    }

    public func snapshot() -> ImportQueueSnapshot {
        ImportQueueSnapshot(items: items, warnings: warnings, isActive: processor != nil)
    }

    public func events() -> AsyncStream<ImportQueueSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        }
    }

    public func enqueue(_ urls: [URL]) {
        let result = scanner.scan(urls)
        warnings.append(contentsOf: result.warnings)
        let existing = Set(items.map { $0.source.standardizedFileURL.path })
        for source in result.candidates where !existing.contains(source.standardizedFileURL.path) {
            items.append(ImportQueueItem(source: source.standardizedFileURL))
        }
        publish()
        startIfNeeded()
    }

    public func cancelCurrent() { currentTask?.cancel() }

    public func cancelAll() {
        for itemIndex in items.indices {
            guard let attemptIndex = items[itemIndex].attempts.indices.last,
                  items[itemIndex].attempts[attemptIndex].status == .waiting else { continue }
            items[itemIndex].attempts[attemptIndex].status = .cancelled
        }
        currentTask?.cancel()
        publish()
    }

    public func retry(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].attempts.last?.status == .failed else { return }
        items[index].attempts.append(ImportAttempt())
        publish(); startIfNeeded()
    }

    public func retryAllFailures() {
        for index in items.indices where items[index].attempts.last?.status == .failed {
            items[index].attempts.append(ImportAttempt())
        }
        publish(); startIfNeeded()
    }

    private func startIfNeeded() {
        guard processor == nil, nextWaiting() != nil else { return }
        processor = Task { await self.processLoop() }
        publish()
    }

    private func processLoop() async {
        while let (itemIndex, attemptIndex) = nextWaiting() {
            items[itemIndex].attempts[attemptIndex].status = .running
            let itemID = items[itemIndex].id
            let attemptID = items[itemIndex].attempts[attemptIndex].id
            let source = items[itemIndex].source
            publish()
            let importer = self.importer
            let task = Task {
                await importer.importURL(source) { event in
                    Task { await self.receive(event, itemID: itemID, attemptID: attemptID) }
                }
            }
            currentTask = task
            let result = await task.value
            currentTask = nil
            if let indices = indices(itemID: itemID, attemptID: attemptID) {
                items[indices.0].attempts[indices.1].status = Self.status(for: result.status)
                items[indices.0].attempts[indices.1].message = result.message
                items[indices.0].attempts[indices.1].progress = nil
            }
            publish()
        }
        processor = nil
        publish()
    }

    private func receive(_ event: MediaImportEvent, itemID: UUID, attemptID: UUID) {
        guard let indices = indices(itemID: itemID, attemptID: attemptID),
              case let .stage(stage, progress) = event else { return }
        items[indices.0].attempts[indices.1].stage = stage
        items[indices.0].attempts[indices.1].progress = progress
        publish()
    }

    private func nextWaiting() -> (Int, Int)? {
        for itemIndex in items.indices {
            if let attemptIndex = items[itemIndex].attempts.indices.last,
               items[itemIndex].attempts[attemptIndex].status == .waiting { return (itemIndex, attemptIndex) }
        }
        return nil
    }

    private func indices(itemID: UUID, attemptID: UUID) -> (Int, Int)? {
        guard let item = items.firstIndex(where: { $0.id == itemID }),
              let attempt = items[item].attempts.firstIndex(where: { $0.id == attemptID }) else { return nil }
        return (item, attempt)
    }

    private func publish() { let value = snapshot(); continuations.values.forEach { $0.yield(value) } }
    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }

    private static func status(for status: MediaImportStatus) -> ImportAttemptStatus {
        switch status {
        case .imported: .imported
        case .duplicate: .duplicate
        case .failed, .skipped: .failed
        case .cancelled: .cancelled
        }
    }
}
