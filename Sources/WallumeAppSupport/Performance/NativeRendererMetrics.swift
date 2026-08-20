import Foundation
import WallumeCore

/// Count-only telemetry emitted by the native wallpaper extension.
///
/// It contains no media names, paths, or display identifiers. A missing file is normal when the
/// native provider has not been selected in System Settings.
public struct NativeRendererMetrics: Codable, Equatable, Sendable {
    public static let unavailable = Self(activeRenderers: 0, enqueuedFrames: 0, readerExhaustions: 0, updatedAt: nil)

    public let activeRenderers: Int
    public let enqueuedFrames: Int
    public let readerExhaustions: Int
    public let updatedAt: Date?

    public init(activeRenderers: Int, enqueuedFrames: Int, readerExhaustions: Int, updatedAt: Date?) {
        self.activeRenderers = activeRenderers
        self.enqueuedFrames = enqueuedFrames
        self.readerExhaustions = readerExhaustions
        self.updatedAt = updatedAt
    }
}

/// Reads the extension's count-only telemetry without coupling the app to the extension target.
public struct NativeRendererMetricsReader: Sendable {
    private let url: URL
    private let files: any FileStore

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, files: any FileStore = LocalFileStore()) {
        url = homeDirectory.appending(path: "Library/Containers/com.wallume.app.wallpaper/Data/Documents/wallume-renderer-metrics.json")
        self.files = files
    }

    public func read() -> NativeRendererMetrics {
        guard let data = try? files.read(url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return .unavailable
        }
        return NativeRendererMetrics(
            activeRenderers: max(0, snapshot.activeRenderers),
            enqueuedFrames: max(0, snapshot.enqueuedFrames),
            readerExhaustions: max(0, snapshot.readerExhaustions),
            updatedAt: snapshot.updatedAt
        )
    }

    private struct Snapshot: Codable, Sendable {
        let activeRenderers: Int
        let enqueuedFrames: Int
        let readerExhaustions: Int
        let updatedAt: Date
    }
}
