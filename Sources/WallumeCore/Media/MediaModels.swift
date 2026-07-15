import Foundation

public struct MediaLibraryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var items: [MediaItem]

    public init(items: [MediaItem] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.items = items
    }
}

public struct MediaItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceHash: String
    public let sourceURL: URL
    public let displayName: String
    public let sourceByteCount: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameRate: Double
    public let durationSeconds: Double
    public let codec: String
    public let variantURL: URL
    public let thumbnailURL: URL
    public let coverURL: URL
    public let createdAt: Date

    public init(
        id: UUID,
        sourceHash: String,
        sourceURL: URL,
        displayName: String,
        sourceByteCount: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Double,
        durationSeconds: Double,
        codec: String,
        variantURL: URL,
        thumbnailURL: URL,
        coverURL: URL,
        createdAt: Date
    ) {
        self.id = id
        self.sourceHash = sourceHash
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.sourceByteCount = sourceByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.codec = codec
        self.variantURL = variantURL
        self.thumbnailURL = thumbnailURL
        self.coverURL = coverURL
        self.createdAt = createdAt
    }
}

public enum MediaImportStatus: String, Codable, Sendable {
    case imported
    case duplicate
    case skipped
    case failed
    case cancelled
}

public enum MediaImportError: Error, Sendable, Equatable {
    case notFound(UUID)
}
