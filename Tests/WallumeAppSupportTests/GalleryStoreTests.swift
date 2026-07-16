import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class GalleryStoreTests: XCTestCase {
    @MainActor
    func testReloadAndSearchMatchNameCodecAndResolution() {
        let library = GalleryLibrary(items: [media("Ocean", width: 1920, codec: "hvc1"), media("Forest", width: 3840, codec: "avc1")])
        let store = GalleryStore(library: library, usage: GalleryUsage())
        store.reload()
        XCTAssertEqual(store.filteredItems.count, 2)
        store.searchText = "3840"
        XCTAssertEqual(store.filteredItems.map(\.displayName), ["Forest"])
        store.searchText = "HVC1"
        XCTAssertEqual(store.filteredItems.map(\.displayName), ["Ocean"])
    }

    @MainActor
    func testDeletionIsBlockedUntilDisplayReferencesClear() {
        let item = media("Ocean")
        let library = GalleryLibrary(items: [item])
        let usage = GalleryUsage(references: [.init(id: "1", name: "Built-in Display"), .init(id: "2", name: "Studio Display")])
        let store = GalleryStore(library: library, usage: usage)
        store.reload()

        store.requestDelete(item)
        XCTAssertEqual(store.deletionBlock?.displays.map(\.name), ["Built-in Display", "Studio Display"])
        XCTAssertTrue(library.removed.isEmpty)

        usage.references = []
        XCTAssertTrue(store.confirmDelete(item))
        XCTAssertEqual(library.removed, [item.id])
    }

    @MainActor
    func testReloadPreservesIndexErrorWithoutReplacingItems() {
        let library = GalleryLibrary(items: [media("Existing")])
        let store = GalleryStore(library: library, usage: GalleryUsage())
        store.reload()
        library.error = SyntheticGalleryError()
        store.reload()
        XCTAssertEqual(store.items.map(\.displayName), ["Existing"])
        XCTAssertNotNil(store.loadError)
    }
}

private func media(_ name: String, width: Int = 1920, codec: String = "hvc1") -> MediaItem {
    .init(id: UUID(), sourceHash: UUID().uuidString, sourceURL: URL(fileURLWithPath: "/\(name).mov"), displayName: name, sourceByteCount: 10, pixelWidth: width, pixelHeight: 1080, frameRate: 30, durationSeconds: 10, codec: codec, variantURL: URL(fileURLWithPath: "/tmp/\(name).mov"), thumbnailURL: URL(fileURLWithPath: "/tmp/\(name).jpg"), coverURL: URL(fileURLWithPath: "/tmp/\(name)-cover.jpg"), createdAt: .distantPast)
}

private final class GalleryLibrary: MediaLibraryManaging, @unchecked Sendable {
    var items: [MediaItem]; var error: Error?; var removed = [UUID]()
    init(items: [MediaItem]) { self.items = items }
    func list() throws -> [MediaItem] { if let error { throw error }; return items }
    func item(id: UUID) throws -> MediaItem? { items.first { $0.id == id } }
    func remove(id: UUID) throws { removed.append(id); items.removeAll { $0.id == id } }
}

private final class GalleryUsage: MediaUsageChecking, @unchecked Sendable {
    var references: [DisplayReference]
    init(references: [DisplayReference] = []) { self.references = references }
    func references(to mediaID: UUID) -> [DisplayReference] { references }
}
private struct SyntheticGalleryError: Error {}
