import Foundation
import Observation

/// Injectable page commands. The production values forward to the synchronization service;
/// keeping this boundary here lets the presentation layer publish command failures consistently.
public struct LockScreenFeatureCommands: Sendable {
    public var refreshProbe: @Sendable () async throws -> LockScreenCommandTicket?
    public var selectAerialSlot: @Sendable (String) async throws -> LockScreenCommandTicket?
    public var confirmEnable: @Sendable () async throws -> LockScreenCommandTicket?
    public var disableAndRestore: @Sendable () async throws -> LockScreenCommandTicket?
    public var retry: @Sendable () async throws -> LockScreenCommandTicket?

    public init(
        refreshProbe: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        selectAerialSlot: @escaping @Sendable (String) async throws -> LockScreenCommandTicket?,
        confirmEnable: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        disableAndRestore: @escaping @Sendable () async throws -> LockScreenCommandTicket?,
        retry: @escaping @Sendable () async throws -> LockScreenCommandTicket?
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

    private enum PageErrorSource {
        case command(ticket: LockScreenCommandTicket?)
        case service
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
            pageErrorSource = snapshot.errorOriginTicket.map { .command(ticket: $0) } ?? .service
        } else if case .service? = pageErrorSource,
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

private final class LockScreenObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}
