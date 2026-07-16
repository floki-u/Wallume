import Foundation
import WallumeCore

public struct PersistedDisplayAssignment: Codable, Equatable, Sendable {
    public let displayID: String
    public let displayName: String
    public let mediaID: UUID
    public init(displayID: String, displayName: String, mediaID: UUID) {
        self.displayID = displayID; self.displayName = displayName; self.mediaID = mediaID
    }
}

public struct DisplayAssignmentsDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let assignments: [PersistedDisplayAssignment]
    public init(assignments: [PersistedDisplayAssignment]) { schemaVersion = 1; self.assignments = assignments }
}

public struct PersistedMediaUsageChecker: MediaUsageChecking {
    private let url: URL
    private let files: any FileStore
    private let store: AtomicJSONStore
    public init(url: URL, files: any FileStore, store: AtomicJSONStore) { self.url = url; self.files = files; self.store = store }
    public func references(to mediaID: UUID) -> [DisplayReference] {
        guard files.exists(url) else { return [] }
        do {
            let document = try store.read(DisplayAssignmentsDocument.self, from: url)
            return document.assignments.filter { $0.mediaID == mediaID }
                .map { DisplayReference(id: $0.displayID, name: $0.displayName) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            return [DisplayReference(id: "configuration-error", name: "显示器配置无法读取")]
        }
    }
}
