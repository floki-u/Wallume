import Foundation

/// Durable ownership record for one Wallume-managed Tahoe Aerial asset.
///
/// The file is deliberately stored under Wallume's application support directory, not in the
/// Apple manifest. A release build and a development build with the same product identity can
/// therefore discover and clean the same entries without adding undocumented marker fields to
/// system-owned JSON.
public struct TahoeAerialRegistration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let asset: TahoeAerialAssetRecord
    public let videoHash: String
    public let thumbnailHash: String?
    public let createdAt: Date

    public init(
        asset: TahoeAerialAssetRecord,
        videoHash: String,
        thumbnailHash: String? = nil,
        createdAt: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.asset = asset
        self.videoHash = videoHash
        self.thumbnailHash = thumbnailHash
        self.createdAt = createdAt
    }
}

public struct TahoeAerialAssetRecord: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let videoURL: URL
    public let thumbnailURL: URL?

    public init(id: String, displayName: String, videoURL: URL, thumbnailURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
    }

    public init(_ asset: TahoeAerialAsset) {
        self.init(
            id: asset.id,
            displayName: asset.displayName,
            videoURL: asset.localVideoURL,
            thumbnailURL: asset.localThumbnailURL
        )
    }

    public var asset: TahoeAerialAsset {
        TahoeAerialAsset(
            id: id,
            displayName: displayName,
            localVideoURL: videoURL,
            localThumbnailURL: thumbnailURL
        )
    }
}

public enum TahoeAerialRegistrationError: Error, Equatable, Sendable {
    case invalidRegistration
    case duplicateRegistration(String)
    case registrationNotFound(String)
    case unsupportedSchema(Int)
}

/// Owns registration journals independently from the legacy slot-replacement journals.
public struct TahoeAerialRegistrationStore: Sendable {
    private let directory: URL
    private let files: any FileStore
    private let journals: AtomicJSONStore

    public init(directory: URL, files: any FileStore, journals: AtomicJSONStore) {
        self.directory = directory
        self.files = files
        self.journals = journals
    }

    public func registrations() throws -> [TahoeAerialRegistration] {
        guard files.exists(directory) else { return [] }
        return try files.contents(directory)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(read)
    }

    public func record(_ registration: TahoeAerialRegistration) throws {
        try validate(registration)
        try files.createDirectory(directory.deletingLastPathComponent())
        try files.createPrivateDirectory(directory)
        let url = journalURL(for: registration.asset.id)
        guard !files.exists(url) else {
            throw TahoeAerialRegistrationError.duplicateRegistration(registration.asset.id)
        }
        try journals.write(registration, to: url)
    }

    public func remove(assetID: String) throws {
        let url = journalURL(for: assetID)
        guard files.exists(url) else {
            throw TahoeAerialRegistrationError.registrationNotFound(assetID)
        }
        try files.remove(url)
    }

    public func journalURL(for assetID: String) -> URL {
        directory.appending(path: "\(assetID).json")
    }

    private func read(_ url: URL) throws -> TahoeAerialRegistration {
        let registration = try journals.read(TahoeAerialRegistration.self, from: url)
        try validate(registration)
        guard url.standardizedFileURL.path == journalURL(for: registration.asset.id)
            .standardizedFileURL.path else {
            throw TahoeAerialRegistrationError.invalidRegistration
        }
        return registration
    }

    private func validate(_ registration: TahoeAerialRegistration) throws {
        guard registration.schemaVersion == TahoeAerialRegistration.currentSchemaVersion else {
            throw TahoeAerialRegistrationError.unsupportedSchema(registration.schemaVersion)
        }
        let asset = registration.asset
        guard !asset.id.isEmpty,
              !asset.id.contains("/"),
              !asset.id.contains(".."),
              !asset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              asset.videoURL.isFileURL,
              asset.thumbnailURL?.isFileURL != false,
              !registration.videoHash.isEmpty else {
            throw TahoeAerialRegistrationError.invalidRegistration
        }
    }
}
