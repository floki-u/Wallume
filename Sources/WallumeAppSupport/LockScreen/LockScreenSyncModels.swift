import Foundation
import WallumeCore

public enum LockScreenSyncPhase: Equatable, Sendable {
    case unconfigured
    case probing
    case readyToConfigure
    case waitingForMainWallpaper
    case syncing
    case synced
    case restoring
    case needsRepair
    case unsupported
}

/// Identifies a user-initiated service command that has reached a terminal outcome.
public enum LockScreenSyncCommand: Equatable, Sendable {
    case refreshProbe
    case selectAerialSlot
    case confirmEnable
    case disableAndRestore
    case retry
}

/// Monotonic identity assigned when the service accepts a user command.
public struct LockScreenCommandTicket: Equatable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct LockScreenSyncedMediaSummary: Equatable, Sendable {
    public let id: UUID
    public let displayName: String?

    public init(id: UUID, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }
}

public struct LockScreenSyncCapabilities: Equatable, Sendable {
    public let canRefreshProbe: Bool
    public let canSelectAerialSlot: Bool
    public let canConfirmEnable: Bool
    public let canDisableAndRestore: Bool
    public let canRetry: Bool

    public init(
        canRefreshProbe: Bool,
        canSelectAerialSlot: Bool,
        canConfirmEnable: Bool,
        canDisableAndRestore: Bool,
        canRetry: Bool
    ) {
        self.canRefreshProbe = canRefreshProbe
        self.canSelectAerialSlot = canSelectAerialSlot
        self.canConfirmEnable = canConfirmEnable
        self.canDisableAndRestore = canDisableAndRestore
        self.canRetry = canRetry
    }

    public static let unavailable = LockScreenSyncCapabilities(
        canRefreshProbe: false,
        canSelectAerialSlot: false,
        canConfirmEnable: false,
        canDisableAndRestore: false,
        canRetry: false
    )
}

public struct LockScreenSyncState: Equatable, Sendable {
    public let phase: LockScreenSyncPhase
    public let selectedAerialID: String?
    public let probe: LockScreenProbeReport?
    public let activeTransactionID: UUID?
    public let syncedMedia: LockScreenSyncedMediaSummary?
    public let lastSyncedAt: Date?
    public let lastResult: LockScreenConfigurationResult?
    public let lastError: String?
    public let errorOriginTicket: LockScreenCommandTicket?
    public let capabilities: LockScreenSyncCapabilities
    public let completedCommandGeneration: UInt64
    public let lastCompletedCommand: LockScreenSyncCommand?
    public let lastCompletedCommandTicket: LockScreenCommandTicket?
    public let lastCompletedCommandSucceeded: Bool?

    public init(
        phase: LockScreenSyncPhase,
        selectedAerialID: String? = nil,
        probe: LockScreenProbeReport? = nil,
        activeTransactionID: UUID? = nil,
        syncedMedia: LockScreenSyncedMediaSummary? = nil,
        lastSyncedAt: Date? = nil,
        lastResult: LockScreenConfigurationResult? = nil,
        lastError: String? = nil,
        errorOriginTicket: LockScreenCommandTicket? = nil,
        capabilities: LockScreenSyncCapabilities = .unavailable,
        completedCommandGeneration: UInt64 = 0,
        lastCompletedCommand: LockScreenSyncCommand? = nil,
        lastCompletedCommandTicket: LockScreenCommandTicket? = nil,
        lastCompletedCommandSucceeded: Bool? = nil
    ) {
        self.phase = phase
        self.selectedAerialID = selectedAerialID
        self.probe = probe
        self.activeTransactionID = activeTransactionID
        self.syncedMedia = syncedMedia
        self.lastSyncedAt = lastSyncedAt
        self.lastResult = lastResult
        self.lastError = lastError
        self.errorOriginTicket = errorOriginTicket
        self.capabilities = capabilities
        self.completedCommandGeneration = completedCommandGeneration
        self.lastCompletedCommand = lastCompletedCommand
        self.lastCompletedCommandTicket = lastCompletedCommandTicket
        self.lastCompletedCommandSucceeded = lastCompletedCommandSucceeded
    }

    public static let unconfigured = LockScreenSyncState(phase: .unconfigured)
}

public struct LockScreenSyncInput: Equatable, Sendable {
    public let assignments: DisplayAssignmentSnapshot
    public let screens: [DesktopScreen]
    public let mediaByID: [UUID: MediaItem]

    public init(
        assignments: DisplayAssignmentSnapshot,
        screens: [DesktopScreen],
        mediaByID: [UUID: MediaItem]
    ) {
        self.assignments = assignments
        self.screens = screens
        self.mediaByID = mediaByID
    }

    public init(
        assignments: DisplayAssignmentSnapshot,
        screens: [DesktopScreen],
        media: [MediaItem]
    ) {
        self.init(
            assignments: assignments,
            screens: screens,
            mediaByID: Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        )
    }

    public static let empty = LockScreenSyncInput(
        assignments: .empty,
        screens: [],
        mediaByID: [:]
    )
}
