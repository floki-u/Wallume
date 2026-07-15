import Foundation
import XCTest
@testable import WallumeCore

final class MediaLibraryTests: XCTestCase {
    func testRegisterFindsDuplicateBySourceHash() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = fixture.item(sourceHash: String(repeating: "a", count: 64))

        try fixture.library.register(item)

        XCTAssertEqual(try fixture.library.find(sourceHash: item.sourceHash)?.id, item.id)
        XCTAssertEqual(try fixture.library.list(), [item])
    }

    func testRegisterDoesNotReplaceExistingItemWithSameSourceHash() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let original = fixture.item(sourceHash: String(repeating: "a", count: 64))
        let duplicate = fixture.item(sourceHash: original.sourceHash)

        try fixture.library.register(original)
        try fixture.library.register(duplicate)

        XCTAssertEqual(try fixture.library.list(), [original])
    }

    func testRemoveDeletesOwnedArtifactsAndIndexEntry() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = fixture.item()
        try fixture.writeArtifacts(for: item)
        try fixture.library.register(item)

        try fixture.library.remove(id: item.id)

        XCTAssertNil(try fixture.library.item(id: item.id))
        XCTAssertFalse(fixture.store.exists(item.variantURL))
        XCTAssertFalse(fixture.store.exists(item.thumbnailURL))
        XCTAssertFalse(fixture.store.exists(item.coverURL))
    }

    func testRemoveAllowsMissingOwnedArtifacts() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = fixture.item()
        try fixture.library.register(item)

        try fixture.library.remove(id: item.id)

        XCTAssertTrue(try fixture.library.list().isEmpty)
    }

    func testRemoveRejectsOutsideVariantWithoutDeletingIt() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside.mov")
        let item = fixture.item(variantURL: outside)
        try fixture.store.writeAtomically(Data("keep".utf8), to: outside)
        try fixture.library.register(item)

        XCTAssertThrowsError(try fixture.library.remove(id: item.id))

        XCTAssertEqual(try fixture.store.read(outside), Data("keep".utf8))
        XCTAssertEqual(try fixture.library.item(id: item.id), item)
    }

    func testRemoveRejectsNonRegularOwnedArtifactWithoutDeletingIt() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = fixture.item()
        try fixture.store.createDirectory(item.variantURL)
        try fixture.library.register(item)

        XCTAssertThrowsError(try fixture.library.remove(id: item.id))

        XCTAssertTrue(fixture.store.exists(item.variantURL))
        XCTAssertEqual(try fixture.library.item(id: item.id), item)
    }
}

private final class MediaLibraryFixture {
    let root: URL
    let store = LocalFileStore()
    let paths: MediaPaths
    let library: MediaLibrary

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path) : temporary
        root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = MediaPaths(
            homeDirectory: root.appending(path: "home"),
            cacheDirectory: root.appending(path: "cache")
        )
        library = MediaLibrary(paths: paths, files: store, jsonStore: AtomicJSONStore(files: store))
    }

    func item(
        sourceHash: String = String(repeating: "a", count: 64),
        variantURL: URL? = nil
    ) -> MediaItem {
        let id = UUID()
        return MediaItem(
            id: id,
            sourceHash: sourceHash,
            sourceURL: root.appending(path: "source.mov"),
            displayName: "Source",
            sourceByteCount: 1,
            pixelWidth: 1920,
            pixelHeight: 1080,
            frameRate: 30,
            durationSeconds: 1,
            codec: "hvc1",
            variantURL: variantURL ?? paths.variant(id: id),
            thumbnailURL: paths.thumbnail(id: id),
            coverURL: paths.cover(id: id),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func writeArtifacts(for item: MediaItem) throws {
        for url in [item.variantURL, item.thumbnailURL, item.coverURL] {
            try store.writeAtomically(Data("owned".utf8), to: url)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
