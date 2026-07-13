import Foundation

public enum TransactionPhase: String, Codable, Sendable {
    case prepared
    case writing
    case committed
    case restoring
    case restored
    case conflicted
}

public struct FileReplacementRecord: Codable, Equatable, Sendable {
    public let target: URL
    public let originalHash: String?
    public let installedHash: String
    public let originalBackup: URL?

    public init(
        target: URL,
        originalHash: String?,
        installedHash: String,
        originalBackup: URL?
    ) {
        self.target = target
        self.originalHash = originalHash
        self.installedHash = installedHash
        self.originalBackup = originalBackup
    }
}

public struct LockScreenTransactionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public let id: UUID
    public var phase: TransactionPhase
    public let createdAt: Date
    public let osMajorVersion: Int
    public let aerialID: String
    public let video: FileReplacementRecord
    public let poster: FileReplacementRecord
    public let indexURL: URL
    public let indexMutations: [PlistMutation]
    public let primaryBackup: URL
    public let recoveryBackup: URL
    public var backupCleanupAuthorized: Bool?

    public init(
        schemaVersion: Int,
        id: UUID,
        phase: TransactionPhase,
        createdAt: Date,
        osMajorVersion: Int,
        aerialID: String,
        video: FileReplacementRecord,
        poster: FileReplacementRecord,
        indexURL: URL,
        indexMutations: [PlistMutation],
        primaryBackup: URL,
        recoveryBackup: URL,
        backupCleanupAuthorized: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.phase = phase
        self.createdAt = createdAt
        self.osMajorVersion = osMajorVersion
        self.aerialID = aerialID
        self.video = video
        self.poster = poster
        self.indexURL = indexURL
        self.indexMutations = indexMutations
        self.primaryBackup = primaryBackup
        self.recoveryBackup = recoveryBackup
        self.backupCleanupAuthorized = backupCleanupAuthorized
    }
}

public struct LockScreenTransactionRequest: Sendable {
    public let systemVersion: OperatingSystemVersion
    public let aerialID: String
    public let optimizedVideo: URL
    public let poster: URL

    public init(
        systemVersion: OperatingSystemVersion,
        aerialID: String,
        optimizedVideo: URL,
        poster: URL
    ) {
        self.systemVersion = systemVersion
        self.aerialID = aerialID
        self.optimizedVideo = optimizedVideo
        self.poster = poster
    }
}
