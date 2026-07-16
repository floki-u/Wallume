import Foundation
import Observation

@MainActor @Observable
public final class ImportTaskStore {
    private let queue: ImportQueue
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    public private(set) var snapshot = ImportQueueSnapshot(items: [], warnings: [], isActive: false)
    public var isExpanded = false

    public init(queue: ImportQueue) { self.queue = queue }

    public func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, queue] in
            let stream = await queue.events()
            for await value in stream {
                guard let self else { return }
                self.snapshot = value
            }
        }
    }

    public var menuBarSummary: String {
        let summary = snapshot.summary
        if snapshot.isActive { return "导入 \(summary.processed)/\(summary.total)" }
        if summary.failed > 0 { return "导入完成 · \(summary.failed) 个失败" }
        return summary.total == 0 ? "Wallume" : "导入完成"
    }

    public func cancelCurrent() { Task { await queue.cancelCurrent() } }
    public func cancelAll() { Task { await queue.cancelAll() } }
    public func retry(_ id: UUID) { Task { await queue.retry(id) } }
    public func retryAllFailures() { Task { await queue.retryAllFailures() } }
}
