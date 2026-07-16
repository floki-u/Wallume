import Foundation
import Observation
import WallumeCore

@MainActor @Observable
public final class GalleryStore {
    private let library: any MediaLibraryManaging
    private let usage: any MediaUsageChecking
    public private(set) var items = [MediaItem]()
    public var searchText = ""
    public var selectedItem: MediaItem?
    public private(set) var loadError: String?
    public private(set) var deletionBlock: MediaDeletionBlock?

    public init(library: any MediaLibraryManaging, usage: any MediaUsageChecking) {
        self.library = library; self.usage = usage
    }

    public var filteredItems: [MediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.displayName.lowercased().contains(query)
                || $0.codec.lowercased().contains(query)
                || "\($0.pixelWidth)x\($0.pixelHeight)".contains(query)
                || "\($0.pixelWidth)".contains(query)
        }
    }

    public func reload() {
        do { items = try library.list(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }

    public func requestDelete(_ item: MediaItem) {
        let displays = usage.references(to: item.id)
        deletionBlock = displays.isEmpty ? nil : MediaDeletionBlock(mediaID: item.id, displays: displays)
    }

    public func dismissDeletionBlock() { deletionBlock = nil }

    @discardableResult
    public func confirmDelete(_ item: MediaItem) -> Bool {
        let displays = usage.references(to: item.id)
        guard displays.isEmpty else {
            deletionBlock = MediaDeletionBlock(mediaID: item.id, displays: displays); return false
        }
        do {
            try library.remove(id: item.id)
            items.removeAll { $0.id == item.id }
            if selectedItem?.id == item.id { selectedItem = nil }
            deletionBlock = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }
}
