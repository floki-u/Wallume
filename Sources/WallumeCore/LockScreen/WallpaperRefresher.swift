import Foundation

public protocol WallpaperRefreshing: Sendable {
    func refresh() throws
}

public struct ProcessWallpaperRefresher: WallpaperRefreshing {
    private let executable: URL
    private let processNames: [String]

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/killall"),
        processNames: [String] = ["WallpaperAgent", "WallpaperAerialsExtension"]
    ) {
        self.executable = executable
        self.processNames = processNames
    }

    public func refresh() throws {
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
