import Foundation

/// The durable, user-controlled intent for lock-screen synchronization.
///
/// This document deliberately contains only identifiers and a concise result code. Transaction
/// manifests remain the authority for recovery material, so target hashes, backup locations, and
/// media file paths must never be persisted here.
public struct LockScreenConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let isEnabled: Bool
    public let selectedAerialID: String?
    public let activeTransactionID: UUID?
    public let lastSyncedMediaID: UUID?
    public let lastSyncedAt: Date?
    public let lastResult: LockScreenConfigurationResult?

    public init(
        isEnabled: Bool,
        selectedAerialID: String? = nil,
        activeTransactionID: UUID? = nil,
        lastSyncedMediaID: UUID? = nil,
        lastSyncedAt: Date? = nil,
        lastResult: LockScreenConfigurationResult? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.isEnabled = isEnabled
        self.selectedAerialID = selectedAerialID
        self.activeTransactionID = activeTransactionID
        self.lastSyncedMediaID = lastSyncedMediaID
        self.lastSyncedAt = lastSyncedAt
        self.lastResult = lastResult
    }

    /// The initial state before a user explicitly selects and confirms an Aerial slot.
    public static let disabled = LockScreenConfiguration(isEnabled: false)
}

/// A concise, non-sensitive outcome suitable for durable UI status.
///
/// User-facing text is derived outside of the persisted configuration so file paths, hashes, and
/// other operational details cannot enter this document.
public enum LockScreenConfigurationResult: String, Codable, Equatable, Sendable {
    case synced
    case waiting
    case failed
    case needsRepair
}
