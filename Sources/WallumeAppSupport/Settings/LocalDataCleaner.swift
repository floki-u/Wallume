import Foundation
import WallumeCore

public enum LocalDataCleanerError: LocalizedError, Equatable {
    case unsafeDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            "本地数据目录状态异常，已停止清理。"
        }
    }
}

/// Deletes only caller-supplied, Wallume-owned directories after checking that they are real
/// directories without symlink components. It is deliberately separate from provider cleanup,
/// which requires a System Settings reset check before any removal is allowed.
public struct LocalDataCleaner: Sendable {
    private let directories: [URL]
    private let files: any FileStore

    public init(directories: [URL], files: any FileStore = LocalFileStore()) {
        self.directories = directories
        self.files = files
    }

    public func clear() throws {
        for directory in directories where files.exists(directory) {
            guard try files.hasNoSymlinkComponents(directory),
                  try files.identity(of: directory).isDirectory else {
                throw LocalDataCleanerError.unsafeDirectory(directory)
            }
            try files.remove(directory)
        }
    }
}
