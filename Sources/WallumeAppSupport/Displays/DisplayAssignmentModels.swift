import Foundation
import WallumeCore

public struct PersistedDisplayRecord: Codable, Equatable, Sendable {
    public var displayID: DisplayID
    public var displayName: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var wasMain: Bool
    public var identityPersistence: DisplayIdentityPersistence
    public var mediaID: UUID?
    public var presentationMode: WallpaperPresentationMode

    public init(
        displayID: DisplayID,
        displayName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        wasMain: Bool,
        identityPersistence: DisplayIdentityPersistence,
        mediaID: UUID?,
        presentationMode: WallpaperPresentationMode
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.wasMain = wasMain
        self.identityPersistence = identityPersistence
        self.mediaID = mediaID
        self.presentationMode = presentationMode
    }

    init(screen: DesktopScreen, mediaID: UUID?, presentationMode: WallpaperPresentationMode) {
        self.init(
            displayID: screen.id,
            displayName: screen.name,
            pixelWidth: screen.pixelWidth,
            pixelHeight: screen.pixelHeight,
            wasMain: screen.isMain,
            identityPersistence: screen.identityPersistence,
            mediaID: mediaID,
            presentationMode: presentationMode
        )
    }
}

public struct DisplayAssignmentsDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var userPaused: Bool
    public var displays: [PersistedDisplayRecord]

    public init(userPaused: Bool = false, displays: [PersistedDisplayRecord] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.userPaused = userPaused
        self.displays = displays
    }
}

public struct DisplayAssignmentSnapshot: Equatable, Sendable {
    public var records: [PersistedDisplayRecord]
    public var userPaused: Bool

    public init(records: [PersistedDisplayRecord], userPaused: Bool) {
        self.records = records.sorted { $0.displayID < $1.displayID }
        self.userPaused = userPaused
    }

    public static let empty = DisplayAssignmentSnapshot(records: [], userPaused: false)
}

public struct PersistedDisplayAssignment: Codable, Equatable, Sendable {
    public let displayID: String
    public let displayName: String
    public let mediaID: UUID

    public init(displayID: String, displayName: String, mediaID: UUID) {
        self.displayID = displayID
        self.displayName = displayName
        self.mediaID = mediaID
    }
}

struct LegacyDisplayAssignmentsDocument: Codable {
    let schemaVersion: Int
    let assignments: [PersistedDisplayAssignment]
}

public enum DisplayAssignmentStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case mediaUnavailable(UUID)
    case emptyTargets
    case duplicateTarget(DisplayID)
    case unknownDisplay(DisplayID)
}
