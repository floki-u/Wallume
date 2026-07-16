import Foundation

public struct DisplayID: Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RuntimeAssignment: Hashable, Sendable {
    public let displayID: DisplayID
    public let mediaID: UUID

    public init(displayID: DisplayID, mediaID: UUID) {
        self.displayID = displayID
        self.mediaID = mediaID
    }
}

public enum RuntimePauseReason: String, CaseIterable, Hashable, Sendable {
    case user
    case appObscured
    case screenLocked
    case lowPower
    case systemSleep
}

public struct RuntimeEnvironment: Equatable, Sendable {
    public let pauseReasons: Set<RuntimePauseReason>

    public init(
        userPaused: Bool,
        appObscured: Bool,
        screenLocked: Bool,
        lowPowerMode: Bool,
        systemSleeping: Bool
    ) {
        pauseReasons = Set([
            userPaused ? .user : nil,
            appObscured ? .appObscured : nil,
            screenLocked ? .screenLocked : nil,
            lowPowerMode ? .lowPower : nil,
            systemSleeping ? .systemSleep : nil,
        ].compactMap { $0 })
    }

    public static let active = RuntimeEnvironment(
        userPaused: false,
        appObscured: false,
        screenLocked: false,
        lowPowerMode: false,
        systemSleeping: false
    )
}

public struct RuntimeFailure: Equatable, Sendable {
    public let displayID: DisplayID
    public let mediaID: UUID
    public let message: String

    public init(displayID: DisplayID, mediaID: UUID, message: String) {
        self.displayID = displayID
        self.mediaID = mediaID
        self.message = message
    }
}

public struct RuntimeDisplaySession: Equatable, Sendable {
    public let displayID: DisplayID
    public let mediaID: UUID
    public let resourceID: UUID

    public init(displayID: DisplayID, mediaID: UUID, resourceID: UUID) {
        self.displayID = displayID
        self.mediaID = mediaID
        self.resourceID = resourceID
    }
}

public struct RuntimeSnapshot: Equatable, Sendable {
    public let sessions: [RuntimeDisplaySession]
    public let resourceReferenceCounts: [UUID: Int]
    public let pauseReasons: Set<RuntimePauseReason>
    public let failures: [RuntimeFailure]
    public let resourceCreationCount: Int

    public init(
        sessions: [RuntimeDisplaySession],
        resourceReferenceCounts: [UUID: Int],
        pauseReasons: Set<RuntimePauseReason>,
        failures: [RuntimeFailure],
        resourceCreationCount: Int
    ) {
        self.sessions = sessions.sorted { $0.displayID < $1.displayID }
        self.resourceReferenceCounts = resourceReferenceCounts
        self.pauseReasons = pauseReasons
        self.failures = failures.sorted {
            ($0.displayID, $0.mediaID.uuidString) < ($1.displayID, $1.mediaID.uuidString)
        }
        self.resourceCreationCount = resourceCreationCount
    }
}

public protocol MediaCatalog: Sendable {
    func item(id: UUID) throws -> MediaItem?
}
