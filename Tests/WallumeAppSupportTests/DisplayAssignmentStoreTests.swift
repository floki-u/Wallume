import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class DisplayAssignmentStoreTests: XCTestCase {
    func testMigratesVersionOneAssignmentsToFillMode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let mediaID = fixture.media.id
        let legacy = """
        {"schemaVersion":1,"assignments":[{"displayID":"cg-uuid:one","displayName":"Studio","mediaID":"\(mediaID.uuidString)"}]}
        """
        try fixture.files.writeAtomically(Data(legacy.utf8), to: fixture.url)

        let snapshot = try await fixture.store.load()

        XCTAssertEqual(snapshot.records.first?.displayName, "Studio")
        XCTAssertEqual(snapshot.records.first?.mediaID, mediaID)
        XCTAssertEqual(snapshot.records.first?.presentationMode, .fill)
        XCTAssertFalse(snapshot.userPaused)
    }

    func testBatchAssignmentPersistsBothDisplaysAndPreservesModes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let one = fixture.screen("one", name: "Built-in", main: true)
        let two = fixture.screen("two", name: "Studio")

        try await fixture.store.assign(mediaID: fixture.media.id, to: [one, two])
        try await fixture.store.setPresentationMode(.stretch, displayID: two.id)
        try await fixture.store.setUserPaused(true)
        let snapshot = await fixture.store.snapshot()

        XCTAssertEqual(snapshot.records.map(\.displayID), [one.id, two.id])
        XCTAssertEqual(snapshot.records.map(\.mediaID), [fixture.media.id, fixture.media.id])
        XCTAssertEqual(snapshot.records.first { $0.displayID == two.id }?.presentationMode, .stretch)
        XCTAssertTrue(snapshot.userPaused)

        let reloaded = try await fixture.makeStore().load()
        XCTAssertEqual(reloaded, snapshot)
    }

    func testWriteFailurePreservesPreviousSnapshotAndFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let screen = fixture.screen("one", name: "Built-in")
        try await fixture.store.assign(mediaID: fixture.media.id, to: [screen])
        let before = await fixture.store.snapshot()
        let beforeData = try fixture.files.read(fixture.url)
        fixture.files.failWrites = true

        do {
            try await fixture.store.setUserPaused(true)
            XCTFail("Expected write failure")
        } catch {}

        let after = await fixture.store.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try fixture.files.read(fixture.url), beforeData)
    }

    func testCorruptAndUnsupportedDocumentsFailClosedWithoutOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let data = Data(#"{"schemaVersion":99,"displays":[],"userPaused":false}"#.utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected unsupported schema")
        } catch let error as DisplayAssignmentStoreError {
            XCTAssertEqual(error, .unsupportedSchema(99))
        }

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot, .empty)
    }
}

private final class Fixture {
    let root: URL
    let url: URL
    let files = ToggleFileStore()
    let media = MediaItem(
        id: UUID(), sourceHash: "hash", sourceURL: URL(fileURLWithPath: "/source.mov"),
        displayName: "Ocean", sourceByteCount: 1, pixelWidth: 1920, pixelHeight: 1080,
        frameRate: 30, durationSeconds: 1, codec: "hvc1",
        variantURL: URL(fileURLWithPath: "/variant.mov"),
        thumbnailURL: URL(fileURLWithPath: "/thumb.jpg"),
        coverURL: URL(fileURLWithPath: "/cover.jpg"), createdAt: .distantPast
    )
    lazy var library = AssignmentLibrary(item: media)
    lazy var store = makeStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        url = root.appending(path: "assignments.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeStore() -> DisplayAssignmentStore {
        DisplayAssignmentStore(url: url, files: files, jsonStore: AtomicJSONStore(files: files), library: library)
    }

    func screen(_ suffix: String, name: String, main: Bool = false) -> DesktopScreen {
        DesktopScreen(
            id: DisplayID("cg-uuid:\(suffix)"), frame: .zero, name: name,
            pixelWidth: 1920, pixelHeight: 1080, isMain: main,
            identityPersistence: .persistent
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct AssignmentLibrary: MediaLibraryManaging {
    let itemValue: MediaItem
    init(item: MediaItem) { itemValue = item }
    func list() throws -> [MediaItem] { [itemValue] }
    func item(id: UUID) throws -> MediaItem? { id == itemValue.id ? itemValue : nil }
    func remove(id: UUID) throws {}
}

private enum ToggleFileError: Error { case writeFailed }

private final class ToggleFileStore: FileStore, @unchecked Sendable {
    private let local = LocalFileStore()
    var failWrites = false
    func exists(_ url: URL) -> Bool { local.exists(url) }
    func read(_ url: URL) throws -> Data { try local.read(url) }
    func contents(_ directory: URL) throws -> [URL] { try local.contents(directory) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(url) }
    func createPrivateDirectory(_ url: URL) throws { try local.createPrivateDirectory(url) }
    func identity(of url: URL) throws -> FileIdentity { try local.identity(of: url) }
    func hasNoSymlinkComponents(_ url: URL) throws -> Bool { try local.hasNoSymlinkComponents(url) }
    func removeDurably(_ url: URL, ifIdentityMatches identity: FileIdentity) throws -> Bool { try local.removeDurably(url, ifIdentityMatches: identity) }
    func writeAtomically(_ data: Data, to target: URL) throws { if failWrites { throw ToggleFileError.writeFailed }; try local.writeAtomically(data, to: target) }
    func writeExclusively(_ data: Data, to target: URL) throws { try local.writeExclusively(data, to: target) }
    func copy(_ source: URL, to destination: URL) throws { try local.copy(source, to: destination) }
    func copyExclusively(_ source: URL, to destination: URL) throws { try local.copyExclusively(source, to: destination) }
    func replace(_ target: URL, with preparedFile: URL) throws { try local.replace(target, with: preparedFile) }
    func exchange(_ target: URL, with preparedFile: URL) throws { try local.exchange(target, with: preparedFile) }
    func installExclusively(_ target: URL, from preparedFile: URL) throws { try local.installExclusively(target, from: preparedFile) }
    func remove(_ url: URL) throws { try local.remove(url) }
}
