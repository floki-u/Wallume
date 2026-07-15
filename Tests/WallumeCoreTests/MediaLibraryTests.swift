import Foundation
import XCTest
@testable import WallumeCore

final class MediaLibraryTests: XCTestCase {
    func testRegisterFindsDuplicateBySourceHash() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = try fixture.item(sourceData: Data("source-a".utf8))

        try fixture.library.register(item)

        XCTAssertEqual(try fixture.library.find(sourceHash: item.sourceHash)?.id, item.id)
        XCTAssertEqual(try fixture.library.list(), [item])
    }

    func testRegisterDoesNotReplaceExistingItemWithSameSourceHash() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let original = try fixture.item(sourceData: Data("same-source".utf8))
        let duplicate = try fixture.item(sourceData: Data("same-source".utf8))

        try fixture.library.register(original)
        try fixture.library.register(duplicate)

        XCTAssertEqual(try fixture.library.list(), [original])
    }

    func testRegisterRejectsItemWhenSourceHashDoesNotMatchSourceBytes() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let alternateSource = fixture.root.appending(path: "alternate-source.mov")
        try fixture.store.writeAtomically(Data("alternate-source".utf8), to: alternateSource)
        let item = try fixture.item(
            sourceData: Data("actual-source".utf8),
            sourceHash: try fixture.digest.sha256(of: alternateSource)
        )

        XCTAssertThrowsError(try fixture.library.register(item))

        XCTAssertTrue(try fixture.library.list().isEmpty)
        XCTAssertFalse(fixture.store.exists(fixture.paths.libraryIndex))
    }

    func testRemoveDeletesOwnedArtifactsAndIndexEntry() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = try fixture.item()
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
        let item = try fixture.item()
        try fixture.library.register(item)

        try fixture.library.remove(id: item.id)

        XCTAssertTrue(try fixture.library.list().isEmpty)
    }

    func testRemoveRejectsOutsideVariantWithoutDeletingIt() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside.mov")
        let item = try fixture.item(variantURL: outside)
        try fixture.store.writeAtomically(Data("keep".utf8), to: outside)
        try fixture.library.register(item)

        XCTAssertThrowsError(try fixture.library.remove(id: item.id))

        XCTAssertEqual(try fixture.store.read(outside), Data("keep".utf8))
        XCTAssertEqual(try fixture.library.item(id: item.id), item)
    }

    func testRemoveRejectsNonRegularOwnedArtifactWithoutDeletingIt() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = try fixture.item()
        try fixture.store.createDirectory(item.variantURL)
        try fixture.library.register(item)

        XCTAssertThrowsError(try fixture.library.remove(id: item.id))

        XCTAssertTrue(fixture.store.exists(item.variantURL))
        XCTAssertEqual(try fixture.library.item(id: item.id), item)
    }

    func testRemoveRejectsSymlinkOwnedArtifactWithoutTouchingReferentOrIndex() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let item = try fixture.item()
        let referent = fixture.root.appending(path: "referent.mov")
        try fixture.store.writeAtomically(Data("keep".utf8), to: referent)
        try fixture.store.createDirectory(item.variantURL.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: item.variantURL, withDestinationURL: referent)
        try fixture.store.writeAtomically(Data("thumb".utf8), to: item.thumbnailURL)
        try fixture.store.writeAtomically(Data("cover".utf8), to: item.coverURL)
        try fixture.library.register(item)

        XCTAssertThrowsError(try fixture.library.remove(id: item.id))

        XCTAssertEqual(try fixture.store.read(referent), Data("keep".utf8))
        XCTAssertTrue(fixture.store.exists(item.variantURL))
        XCTAssertEqual(try fixture.library.item(id: item.id), item)
    }

    func testRemoveRejectsSymlinkParentWithoutTouchingReferentArtifactsOrIndex() throws {
        let fixture = try MediaLibraryFixture()
        defer { fixture.remove() }
        let itemID = UUID()
        let referentDirectory = fixture.root.appending(path: "referent-directory")
        let symlinkParent = fixture.paths.variantsDirectory.appending(path: "linked")
        let variantURL = symlinkParent.appending(path: "\(itemID.uuidString).mov")
        let item = try fixture.item(id: itemID, variantURL: variantURL)
        try fixture.store.createDirectory(referentDirectory)
        try fixture.store.createDirectory(fixture.paths.variantsDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: referentDirectory)
        try fixture.store.writeAtomically(
            Data("keep-variant".utf8),
            to: referentDirectory.appending(path: variantURL.lastPathComponent)
        )
        try fixture.store.writeAtomically(Data("keep-thumbnail".utf8), to: item.thumbnailURL)
        try fixture.store.writeAtomically(Data("keep-cover".utf8), to: item.coverURL)
        try fixture.library.register(item)

        XCTAssertThrowsError(try fixture.library.remove(id: item.id))

        XCTAssertEqual(
            try fixture.store.read(referentDirectory.appending(path: variantURL.lastPathComponent)),
            Data("keep-variant".utf8)
        )
        XCTAssertEqual(try fixture.store.read(item.thumbnailURL), Data("keep-thumbnail".utf8))
        XCTAssertEqual(try fixture.store.read(item.coverURL), Data("keep-cover".utf8))
        XCTAssertEqual(try fixture.library.item(id: item.id), item)
    }
}

private final class MediaLibraryFixture {
    let root: URL
    let store = LocalFileStore()
    let paths: MediaPaths
    let digest = SHA256Digester()
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
        library = MediaLibrary(
            paths: paths,
            files: store,
            jsonStore: AtomicJSONStore(files: store),
            digester: digest
        )
    }

    func item(
        id: UUID = UUID(),
        sourceData: Data = Data("source".utf8),
        sourceHash: String? = nil,
        variantURL: URL? = nil
    ) throws -> MediaItem {
        let sourceURL = root.appending(path: "source-\(id.uuidString).mov")
        try store.writeAtomically(sourceData, to: sourceURL)
        return MediaItem(
            id: id,
            sourceHash: try sourceHash ?? digest.sha256(of: sourceURL),
            sourceURL: sourceURL,
            displayName: "Source",
            sourceByteCount: Int64(sourceData.count),
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
