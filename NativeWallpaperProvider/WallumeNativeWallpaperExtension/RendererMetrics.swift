import Foundation
import os

/// Lightweight, process-wide renderer telemetry for diagnosing native wallpaper playback.
/// It intentionally records counts only: no media paths or user content leave the machine.
enum RendererMetrics {
    private struct State: Codable {
        var activeRenderers = 0
        var enqueuedFrames = 0
        var readerExhaustions = 0
        var updatedAt = Date()
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())
    /// Frame submission can happen dozens of times per second for every hosted
    /// wallpaper surface. Persisting an atomic JSON file for every frame turns
    /// diagnostics itself into I/O contention on the render queue, especially when
    /// desktop, lock screen and several Spaces are live. Keep the counters exact in
    /// memory and publish their snapshot at a human-observable cadence instead.
    private static let persistenceLock = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private static let minimumWriteInterval: TimeInterval = 1
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/com.wallume.app.wallpaper/Data/Documents/wallume-renderer-metrics.json")

    static func rendererStarted() { update(forcePersist: true) { $0.activeRenderers += 1 } }
    static func rendererStopped() { update(forcePersist: true) { $0.activeRenderers = max(0, $0.activeRenderers - 1) } }
    static func frameEnqueued() { update { $0.enqueuedFrames += 1 } }
    static func readerExhausted() { update { $0.readerExhaustions += 1 } }
    static func heartbeat() { update(forcePersist: true) { _ in } }

    private static func update(forcePersist: Bool = false, _ mutation: @Sendable (inout State) -> Void) {
        let snapshot = lock.withLock { state -> State in
            mutation(&state)
            state.updatedAt = Date()
            return state
        }
        let shouldPersist = persistenceLock.withLock { lastWrite -> Bool in
            let now = Date()
            guard forcePersist || now.timeIntervalSince(lastWrite) >= minimumWriteInterval else { return false }
            lastWrite = now
            return true
        }
        guard shouldPersist else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
