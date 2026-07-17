import Foundation
import Observation

/// Injectable page commands. The production values forward to the synchronization service;
/// keeping this boundary here lets the presentation layer publish command failures consistently.
public struct LockScreenFeatureCommands: Sendable {
    public var refreshProbe: @Sendable () async throws -> Void
    public var selectAerialSlot: @Sendable (String) async throws -> Void
    public var confirmEnable: @Sendable () async throws -> Void
    public var disableAndRestore: @Sendable () async throws -> Void
    public var retry: @Sendable () async throws -> Void

    public init(
        refreshProbe: @escaping @Sendable () async throws -> Void,
        selectAerialSlot: @escaping @Sendable (String) async throws -> Void,
        confirmEnable: @escaping @Sendable () async throws -> Void,
        disableAndRestore: @escaping @Sendable () async throws -> Void,
        retry: @escaping @Sendable () async throws -> Void
    ) {
        self.refreshProbe = refreshProbe
        self.selectAerialSlot = selectAerialSlot
        self.confirmEnable = confirmEnable
        self.disableAndRestore = disableAndRestore
        self.retry = retry
    }

    public static func service(_ service: LockScreenSyncService) -> Self {
        Self(
            refreshProbe: { await service.refreshProbe() },
            selectAerialSlot: { await service.selectAerialSlot($0) },
            confirmEnable: { await service.confirmEnable() },
            disableAndRestore: { await service.disableAndRestore() },
            retry: { await service.retry() }
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

    private let commands: LockScreenFeatureCommands
    private let observation = LockScreenObservation()

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

    public func refreshProbe() async { await perform { try await commands.refreshProbe() } }
    public func selectAerialSlot(_ aerialID: String) async { await perform { try await commands.selectAerialSlot(aerialID) } }
    public func confirmEnable() async { await perform { try await commands.confirmEnable() } }
    public func disableAndRestore() async { await perform { try await commands.disableAndRestore() } }
    public func retry() async { await perform { try await commands.retry() } }

    public func reportPageError(_ message: String) { pageError = message }
    public func dismissPageError() { pageError = nil }

    private func receive(_ snapshot: LockScreenSyncState) {
        state = snapshot
        if let error = snapshot.lastError {
            pageError = error
        } else if pageError != nil {
            pageError = nil
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            pageError = error.localizedDescription
        }
    }
}

private final class LockScreenObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}
