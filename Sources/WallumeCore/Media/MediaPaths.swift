import Foundation

public struct MediaPaths: Sendable {
    public let libraryIndex: URL
    public let variantsDirectory: URL
    public let thumbnailsDirectory: URL
    public let coversDirectory: URL
    public let importWorkRoot: URL
    public let displayAssignments: URL

    public init(homeDirectory: URL, cacheDirectory: URL) {
        let libraryDirectory = homeDirectory
            .appending(path: "Library/Application Support")
            .appending(path: WallumeBuildInfo.productName)
            .appending(path: "Library")
        let cacheRoot = cacheDirectory.appending(path: "app.wallume.Wallume")

        libraryIndex = libraryDirectory.appending(path: "library.json")
        variantsDirectory = libraryDirectory.appending(path: "Variants")
        thumbnailsDirectory = cacheRoot.appending(path: "Thumbnails")
        coversDirectory = cacheRoot.appending(path: "Metadata")
        importWorkRoot = cacheRoot.appending(path: "ImportWork")
        displayAssignments = libraryDirectory.deletingLastPathComponent().appending(path: "display-assignments.json")
    }

    public func variant(id: UUID) -> URL {
        variantsDirectory.appending(path: "\(id.uuidString).mov")
    }

    public func thumbnail(id: UUID) -> URL {
        thumbnailsDirectory.appending(path: "\(id.uuidString).jpg")
    }

    public func cover(id: UUID) -> URL {
        coversDirectory.appending(path: "\(id.uuidString).jpg")
    }

    public func importWork(id: UUID) -> URL {
        importWorkRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}
