import Foundation
import WallumeCore

public struct PersistedMediaUsageChecker: MediaUsageChecking {
    private let url: URL
    private let files: any FileStore
    private let store: AtomicJSONStore
    public init(url: URL, files: any FileStore, store: AtomicJSONStore) { self.url = url; self.files = files; self.store = store }
    public func references(to mediaID: UUID) -> [DisplayReference] {
        guard files.exists(url) else { return [] }
        do {
            let data = try files.read(url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let schema = object?["schemaVersion"] as? Int
            let assignments: [PersistedDisplayAssignment]
            if schema == 1 {
                assignments = try JSONDecoder().decode(LegacyDisplayAssignmentsDocument.self, from: data).assignments
            } else if schema == DisplayAssignmentsDocument.currentSchemaVersion {
                assignments = try store.read(DisplayAssignmentsDocument.self, from: url).displays.compactMap { record in
                    record.mediaID.map {
                        PersistedDisplayAssignment(displayID: record.displayID.rawValue, displayName: record.displayName, mediaID: $0)
                    }
                }
            } else {
                throw DisplayAssignmentStoreError.unsupportedSchema(schema ?? -1)
            }
            return assignments.filter { $0.mediaID == mediaID }
                .map { DisplayReference(id: $0.displayID, name: $0.displayName) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            return [DisplayReference(id: "configuration-error", name: "显示器配置无法读取")]
        }
    }
}
