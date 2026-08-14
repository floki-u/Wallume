import Foundation

public protocol WallpaperRefreshing: Sendable {
    func refresh() throws
}

public struct ProcessWallpaperRefresher: WallpaperRefreshing {
    private let executable: URL
    private let processNames: [String]
    private let aerialCacheDirectory: URL

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/killall"),
        processNames: [String] = ["WallpaperAgent", "WallpaperAerialsExtension"],
        aerialCacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.aerials")
    ) {
        self.executable = executable
        self.processNames = processNames
        self.aerialCacheDirectory = aerialCacheDirectory
    }

    public func refresh() throws {
        // The Aerial extension caches decoded manifest/thumbnail output in this user cache.  It
        // is derived data only: clearing it before restarting WallpaperAgent prevents a newly
        // registered asset from being shadowed by a stale render, and macOS rebuilds it itself.
        let files = FileManager.default
        if let entries = try? files.contentsOfDirectory(
            at: aerialCacheDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.pathExtension == "bmp" {
                try? files.removeItem(at: entry)
            }
            let version = aerialCacheDirectory.appending(path: "cacheVersion.db")
            try? Data("{\"version\":0}".utf8).write(to: version, options: .atomic)
        }
        for processName in processNames {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-TERM", processName]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                throw CocoaError(.executableLoad)
            }
        }
    }
}

public enum TransactionFaultPoint: Sendable, Equatable {
    case afterPreparedJournal
    case afterVideoReplacement
    case afterIndexReplacement
    case afterPosterReplacement
    case beforeCommit
}

public protocol FaultInjecting: Sendable {
    func hit(_ point: TransactionFaultPoint) throws
}

public struct NoFaults: FaultInjecting {
    public init() {}
    public func hit(_ point: TransactionFaultPoint) throws {}
}
