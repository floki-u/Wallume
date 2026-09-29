import Foundation

public struct MediaLibraryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public var items: [MediaItem]

    public init(items: [MediaItem] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard storedVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported media library schema \(storedVersion)."
            )
        }
        schemaVersion = Self.currentSchemaVersion
        items = try container.decode([MediaItem].self, forKey: .items)
    }
}

public enum MediaKind: String, Codable, Sendable, Equatable {
    case video
    case image

    public static func infer(from url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4": .video
        case "png", "jpg", "jpeg", "heic": .image
        default: nil
        }
    }
}

public struct MediaItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: MediaKind
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
        kind: MediaKind = .video,
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
        self.kind = kind
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

    private enum CodingKeys: String, CodingKey {
        case id, kind, sourceHash, sourceURL, displayName, sourceByteCount
        case pixelWidth, pixelHeight, frameRate, durationSeconds, codec
        case variantURL, thumbnailURL, coverURL, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .video
        sourceHash = try container.decode(String.self, forKey: .sourceHash)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        displayName = try container.decode(String.self, forKey: .displayName)
        sourceByteCount = try container.decode(Int64.self, forKey: .sourceByteCount)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        frameRate = try container.decode(Double.self, forKey: .frameRate)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        codec = try container.decode(String.self, forKey: .codec)
        variantURL = try container.decode(URL.self, forKey: .variantURL)
        thumbnailURL = try container.decode(URL.self, forKey: .thumbnailURL)
        coverURL = try container.decode(URL.self, forKey: .coverURL)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
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
    case artifactMissing(URL)
}
