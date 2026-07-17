import Foundation
import WallumeCore

public actor DisplayAssignmentStore {
    private let url: URL
    private let files: any FileStore
    private let jsonStore: AtomicJSONStore
    private let library: any MediaLibraryManaging
    private var value = DisplayAssignmentSnapshot.empty
    private var acceptsMutations = true
    private var continuations = [UUID: AsyncStream<DisplayAssignmentSnapshot>.Continuation]()

    public init(
        url: URL,
        files: any FileStore,
        jsonStore: AtomicJSONStore,
        library: any MediaLibraryManaging
    ) {
        self.url = url
        self.files = files
        self.jsonStore = jsonStore
        self.library = library
    }

    public func load() throws -> DisplayAssignmentSnapshot {
        guard files.exists(url) else {
            acceptsMutations = true
            value = .empty
            publish()
            return value
        }
        acceptsMutations = false
        do {
            let data = try files.read(url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let schemaVersion = object?["schemaVersion"] as? Int ?? -1
            switch schemaVersion {
            case 1:
                let legacy = try JSONDecoder().decode(LegacyDisplayAssignmentsDocument.self, from: data)
                value = DisplayAssignmentSnapshot(
                    records: legacy.assignments.map {
                        PersistedDisplayRecord(
                            displayID: DisplayID($0.displayID), displayName: $0.displayName,
                            pixelWidth: 0, pixelHeight: 0, wasMain: false,
                            identityPersistence: .persistent, mediaID: $0.mediaID,
                            presentationMode: .fill
                        )
                    },
                    userPaused: false
                )
            case DisplayAssignmentsDocument.currentSchemaVersion:
                let document = try jsonStore.read(DisplayAssignmentsDocument.self, from: url)
                value = DisplayAssignmentSnapshot(records: document.displays, userPaused: document.userPaused)
            default:
                throw DisplayAssignmentStoreError.unsupportedSchema(schemaVersion)
            }
            acceptsMutations = true
        } catch {
            value = .empty
            throw error
        }
        publish()
        return value
    }

    public func snapshot() -> DisplayAssignmentSnapshot { value }

    public func assign(mediaID: UUID, to screens: [DesktopScreen]) throws {
        try ensureAcceptsMutations()
        guard !screens.isEmpty else { throw DisplayAssignmentStoreError.emptyTargets }
        guard try library.item(id: mediaID) != nil else {
            throw DisplayAssignmentStoreError.mediaUnavailable(mediaID)
        }
        var seen = Set<DisplayID>()
        for screen in screens where !seen.insert(screen.id).inserted {
            throw DisplayAssignmentStoreError.duplicateTarget(screen.id)
        }
        var candidate = value
        for screen in screens {
            let mode = candidate.records.first { $0.displayID == screen.id }?.presentationMode ?? .fill
            candidate.records.removeAll { $0.displayID == screen.id }
            candidate.records.append(PersistedDisplayRecord(screen: screen, mediaID: mediaID, presentationMode: mode))
        }
        try commit(candidate)
    }

    public func removeAssignment(displayID: DisplayID) throws {
        try ensureAcceptsMutations()
        var candidate = value
        guard let index = candidate.records.firstIndex(where: { $0.displayID == displayID }) else {
            throw DisplayAssignmentStoreError.unknownDisplay(displayID)
        }
        candidate.records[index].mediaID = nil
        try commit(candidate)
    }

    public func clearRememberedDisplay(displayID: DisplayID) throws {
        try ensureAcceptsMutations()
        var candidate = value
        guard candidate.records.contains(where: { $0.displayID == displayID }) else {
            throw DisplayAssignmentStoreError.unknownDisplay(displayID)
        }
        candidate.records.removeAll { $0.displayID == displayID }
        try commit(candidate)
    }

    public func setPresentationMode(_ mode: WallpaperPresentationMode, displayID: DisplayID) throws {
        try ensureAcceptsMutations()
        var candidate = value
        guard let index = candidate.records.firstIndex(where: { $0.displayID == displayID }) else {
            throw DisplayAssignmentStoreError.unknownDisplay(displayID)
        }
        candidate.records[index].presentationMode = mode
        try commit(candidate)
    }

    public func setUserPaused(_ paused: Bool) throws {
        try ensureAcceptsMutations()
        var candidate = value
        candidate.userPaused = paused
        try commit(candidate)
    }

    public func events() -> AsyncStream<DisplayAssignmentSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(value)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func commit(_ candidate: DisplayAssignmentSnapshot) throws {
        let durableRecords = candidate.records.filter { $0.identityPersistence == .persistent }
        try jsonStore.write(
            DisplayAssignmentsDocument(userPaused: candidate.userPaused, displays: durableRecords),
            to: url
        )
        value = DisplayAssignmentSnapshot(records: candidate.records, userPaused: candidate.userPaused)
        publish()
    }

    private func ensureAcceptsMutations() throws {
        guard acceptsMutations else {
            throw DisplayAssignmentStoreError.unavailableAfterLoadFailure
        }
    }

    private func publish() {
        continuations.values.forEach { $0.yield(value) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
