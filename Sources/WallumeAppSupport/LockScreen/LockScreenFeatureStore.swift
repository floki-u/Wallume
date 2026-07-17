import Foundation
import Observation
import WallumeCore

/// Injectable page commands. The production values forward to the synchronization service;
/// keeping this boundary here lets the presentation layer publish command failures consistently.
public struct LockScreenFeatureCommands: Sendable {
    public var refreshProbe: @Sendable () async throws -> LockScreenCommandTicket?
    public var selectAerialSlot: @Sendable (String) async throws -> LockScreenCommandTicket?
    public var confirmEnable: @Sendable () async throws -> LockScreenCommandTicket?
    public var disableAndRestore: @Sendable () async throws -> LockScreenCommandTicket?
    public var retry: @Sendable () async throws -> LockScreenCommandTicket?
    public var resynchronize: @Sendable () async throws -> LockScreenCommandTicket?

    public init(
        refreshProbe: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        selectAerialSlot: @escaping @Sendable (String) async throws -> LockScreenCommandTicket?,
        confirmEnable: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        disableAndRestore: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        retry: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        resynchronize: (@Sendable () async throws -> LockScreenCommandTicket?)? = nil
    ) {
        self.refreshProbe = refreshProbe
        self.selectAerialSlot = selectAerialSlot
        self.confirmEnable = confirmEnable
        self.disableAndRestore = disableAndRestore
        self.retry = retry
        self.resynchronize = resynchronize ?? retry
    }

    public static func service(_ service: LockScreenSyncService) -> Self {
        Self(
            refreshProbe: { await service.refreshProbe() },
            selectAerialSlot: { await service.selectAerialSlot($0) },
            confirmEnable: { await service.confirmEnable() },
            disableAndRestore: { await service.disableAndRestore() },
            retry: { await service.retry() },
            resynchronize: { await service.resynchronize() }
        )
    }
}

/// Main-actor projection of the lock-screen service for a single SwiftUI page.
///
/// It deliberately contains no filesystem, process, or transaction operation. The service
/// remains alive after this page/store disappears; only this store's event subscription is owned
/// and cancelled here.
@MainActor @Observable
public final class LockScreenFeatureStore {
    public private(set) var state: LockScreenSyncState = .unconfigured
    public private(set) var pageError: String?

    private enum PageErrorSource {
        case command(ticket: LockScreenCommandTicket?)
        case service(baselineGeneration: UInt64)
        case reported
    }
    private let commands: LockScreenFeatureCommands
    private let observation = LockScreenObservation()
    private var pageErrorSource: PageErrorSource?

    public init(service: LockScreenSyncService, commands: LockScreenFeatureCommands? = nil) {
        self.commands = commands ?? .service(service)
        observation.set(Task { [weak self, service] in
            for await snapshot in await service.events() {
                guard !Task.isCancelled else { return }
                self?.receive(snapshot)
            }
        })
    }

    deinit { observation.cancel() }

    public func refreshProbe() async {
        await perform(command: .refreshProbe) {
            try await commands.refreshProbe()
        }
    }

    public func selectAerialSlot(_ aerialID: String) async {
        await perform(command: .selectAerialSlot) { try await commands.selectAerialSlot(aerialID) }
    }

    public func confirmEnable() async {
        await perform(command: .confirmEnable) { try await commands.confirmEnable() }
    }

    public func disableAndRestore() async {
        await perform(command: .disableAndRestore) { try await commands.disableAndRestore() }
    }

    public func retry() async {
        await perform(command: .retry) {
            try await commands.retry()
        }
    }

    public func resynchronize() async {
        await perform(command: .retry) {
            try await commands.resynchronize()
        }
    }

    /// Produces a path-free, local-only snapshot. Saving remains an explicit UI choice.
    public func makeDiagnosticExportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(LockScreenDiagnosticSnapshot(state: state))
    }

    public func reportPageError(_ message: String) {
        pageError = message
        pageErrorSource = .reported
    }

    public func dismissPageError() {
        pageError = nil
        pageErrorSource = nil
    }

    private func receive(_ snapshot: LockScreenSyncState) {
        state = snapshot
        if let error = snapshot.lastError {
            pageError = error
            pageErrorSource = snapshot.errorOriginTicket.map { .command(ticket: $0) }
                ?? .service(baselineGeneration: snapshot.completedCommandGeneration)
        } else if case let .service(baselineGeneration) = pageErrorSource,
                  snapshot.completedCommandGeneration > baselineGeneration,
                  snapshot.lastCompletedCommandSucceeded == true {
            pageError = nil
            pageErrorSource = nil
        } else if case let .command(ticket) = pageErrorSource,
                  snapshot.lastCompletedCommandTicket == ticket,
                  snapshot.lastCompletedCommandSucceeded == true {
            pageError = nil
            pageErrorSource = nil
        }
    }

    private func perform(
        command: LockScreenSyncCommand,
        _ operation: () async throws -> LockScreenCommandTicket?
    ) async {
        do {
            _ = try await operation()
        } catch {
            pageError = error.localizedDescription
            pageErrorSource = .command(ticket: nil)
        }
    }
}

public struct LockScreenDiagnosticSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let phase: String
    public let macOSGeneration: String?
    public let writesPermitted: Bool?
    public let manifestExists: Bool?
    public let indexExists: Bool?
    public let availableSlotCount: Int
    public let foreignBackupCount: Int
    public let selectedAerialID: String?
    public let activeTransactionID: UUID?
    public let syncedMediaID: UUID?
    public let lastSyncedAt: Date?
    public let lastResult: String?

    public init(state: LockScreenSyncState) {
        schemaVersion = Self.currentSchemaVersion
        phase = Self.phaseName(state.phase)
        macOSGeneration = state.probe.map { Self.generationName($0.generation) }
        writesPermitted = state.probe?.writesPermitted
        manifestExists = state.probe?.manifestExists
        indexExists = state.probe?.indexExists
        availableSlotCount = state.probe?.availableSlots.count ?? 0
        foreignBackupCount = state.probe?.foreignBackupNames.count ?? 0
        selectedAerialID = state.selectedAerialID
        activeTransactionID = state.activeTransactionID
        syncedMediaID = state.syncedMedia?.id
        lastSyncedAt = state.lastSyncedAt
        lastResult = state.lastResult?.rawValue
    }

    private static func phaseName(_ phase: LockScreenSyncPhase) -> String {
        switch phase {
        case .unconfigured: "unconfigured"
        case .probing: "probing"
        case .readyToConfigure: "readyToConfigure"
        case .waitingForMainWallpaper: "waitingForMainWallpaper"
        case .syncing: "syncing"
        case .synced: "synced"
        case .restoring: "restoring"
        case .needsRepair: "needsRepair"
        case .unsupported: "unsupported"
        }
    }

    private static func generationName(_ generation: MacOSGeneration) -> String {
        switch generation {
        case .sonoma: "sonoma"
        case .sequoia: "sequoia"
        case .tahoe: "tahoe"
        case let .unsupported(version): "unsupported-\(version)"
        }
    }
}

private final class LockScreenObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}
