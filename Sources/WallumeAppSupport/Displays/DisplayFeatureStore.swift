import Foundation
import Observation
import WallumeCore

public struct DisplayCardState: Identifiable, Equatable, Sendable {
    public let display: DisplayRecord
    public let media: MediaItem?
    public let presentationMode: WallpaperPresentationMode
    public let runtimeError: String?
    public var id: DisplayID { display.id }
    public var connection: DisplayConnection { display.connection }
}

public struct DisplayFeatureCommands: Sendable {
    public var assign: @Sendable (UUID, Set<DisplayID>) async throws -> Void
    public var remove: @Sendable (DisplayID) async throws -> Void
    public var clear: @Sendable (DisplayID) async throws -> Void
    public var setMode: @Sendable (WallpaperPresentationMode, DisplayID) async throws -> Void
    public var setPaused: @Sendable (Bool) async throws -> Void
    public var retry: @Sendable (DisplayID) async throws -> Void

    public init(
        assign: @escaping @Sendable (UUID, Set<DisplayID>) async throws -> Void,
        remove: @escaping @Sendable (DisplayID) async throws -> Void,
        clear: @escaping @Sendable (DisplayID) async throws -> Void,
        setMode: @escaping @Sendable (WallpaperPresentationMode, DisplayID) async throws -> Void,
        setPaused: @escaping @Sendable (Bool) async throws -> Void,
        retry: @escaping @Sendable (DisplayID) async throws -> Void
    ) {
        self.assign = assign; self.remove = remove; self.clear = clear
        self.setMode = setMode; self.setPaused = setPaused; self.retry = retry
    }

    public static let noop = DisplayFeatureCommands(
        assign: { _, _ in }, remove: { _ in }, clear: { _ in },
        setMode: { _, _ in }, setPaused: { _ in }, retry: { _ in }
    )
}

@MainActor @Observable
public final class DisplayFeatureStore {
    public private(set) var cards = [DisplayCardState]()
    public private(set) var assignmentTargets = [DisplayRecord]()
    public private(set) var userPaused = false
    public private(set) var effectivePauseReasons = Set<RuntimePauseReason>()
    public private(set) var pageError: String?
    public var selectedMediaForAssignment: MediaItem?
    private let commands: DisplayFeatureCommands

    public init(commands: DisplayFeatureCommands) { self.commands = commands }

    public func update(
        catalog: [DisplayRecord],
        assignments: DisplayAssignmentSnapshot,
        media: [MediaItem],
        runtime: RuntimeSnapshot?
    ) {
        let records = Dictionary(uniqueKeysWithValues: assignments.records.map { ($0.displayID, $0) })
        let mediaByID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        let failures = Dictionary((runtime?.failures ?? []).map { ($0.displayID, $0.message) }, uniquingKeysWith: { first, _ in first })
        cards = catalog.map { display in
            let record = records[display.id]
            return DisplayCardState(
                display: display,
                media: record?.mediaID.flatMap { mediaByID[$0] },
                presentationMode: record?.presentationMode ?? .fill,
                runtimeError: failures[display.id]
            )
        }
        assignmentTargets = catalog.filter { $0.connection == .connected }
        userPaused = assignments.userPaused
        effectivePauseReasons = runtime?.pauseReasons ?? (assignments.userPaused ? [.user] : [])
    }

    public func assign(mediaID: UUID, displayIDs: Set<DisplayID>) async { await perform { try await commands.assign(mediaID, displayIDs) } }
    public func removeAssignment(displayID: DisplayID) async { await perform { try await commands.remove(displayID) } }
    public func clearRememberedDisplay(displayID: DisplayID) async { await perform { try await commands.clear(displayID) } }
    public func setPresentationMode(_ mode: WallpaperPresentationMode, displayID: DisplayID) async { await perform { try await commands.setMode(mode, displayID) } }
    public func setUserPaused(_ paused: Bool) async { await perform { try await commands.setPaused(paused) } }
    public func retry(displayID: DisplayID) async { await perform { try await commands.retry(displayID) } }
    public func reportPageError(_ message: String) { pageError = message }
    public func dismissPageError() { pageError = nil }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation(); pageError = nil }
        catch { pageError = error.localizedDescription }
    }
}
