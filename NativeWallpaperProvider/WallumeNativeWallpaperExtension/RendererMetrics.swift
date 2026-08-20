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
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/com.wallume.app.wallpaper/Data/Documents/wallume-renderer-metrics.json")

    static func rendererStarted() { update { $0.activeRenderers += 1 } }
    static func rendererStopped() { update { $0.activeRenderers = max(0, $0.activeRenderers - 1) } }
    static func frameEnqueued() { update { $0.enqueuedFrames += 1 } }
    static func readerExhausted() { update { $0.readerExhaustions += 1 } }

    private static func update(_ mutation: @Sendable (inout State) -> Void) {
        let snapshot = lock.withLock { state -> State in
            mutation(&state)
            state.updatedAt = Date()
            return state
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
