import Foundation
import XCTest
@testable import WallumeCore

final class TahoeAerialRegistrationTests: XCTestCase {
    func testReleaseAndDevelopmentStoresDiscoverTheSameRegistration() throws {
        let fixture = try Fixture()
        let registration = fixture.registration(id: "BD000000-0000-4000-8000-000000000001")

        try fixture.store.record(registration)

        XCTAssertEqual(try fixture.freshStore.registrations(), [registration])
    }

    func testDuplicateAssetIDIsRejectedWithoutReplacingExistingRecord() throws {
        let fixture = try Fixture()
        let original = fixture.registration(id: "BD000000-0000-4000-8000-000000000001")
        let replacement = TahoeAerialRegistration(
            asset: TahoeAerialAssetRecord(
                id: original.asset.id,
                displayName: "Other",
                videoURL: URL(fileURLWithPath: "/tmp/Other.mov")
            ),
            videoHash: "other-hash",
            createdAt: original.createdAt.addingTimeInterval(1)
        )
        try fixture.store.record(original)

        XCTAssertThrowsError(try fixture.store.record(replacement)) { error in
            XCTAssertEqual(error as? TahoeAerialRegistrationError, .duplicateRegistration(original.asset.id))
        }
        XCTAssertEqual(try fixture.store.registrations(), [original])
    }

    func testRemoveDeletesOnlyTheRequestedRegistration() throws {
        let fixture = try Fixture()
        let first = fixture.registration(id: "BD000000-0000-4000-8000-000000000001")
        let second = fixture.registration(id: "BD000000-0000-4000-8000-000000000002")
        try fixture.store.record(first)
        try fixture.store.record(second)

        try fixture.store.remove(assetID: first.asset.id)

        XCTAssertEqual(try fixture.store.registrations(), [second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.journalURL(for: first.asset.id).path))
    }
}

private final class Fixture {
    let root: URL
    let files = LocalFileStore()
    let store: TahoeAerialRegistrationStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-TahoeAerialRegistrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TahoeAerialRegistrationStore(
            directory: root.appending(path: "registrations"),
            files: files,
            journals: AtomicJSONStore(files: files)
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var freshStore: TahoeAerialRegistrationStore {
        TahoeAerialRegistrationStore(
            directory: root.appending(path: "registrations"),
            files: files,
            journals: AtomicJSONStore(files: files)
        )
    }

    func registration(id: String) -> TahoeAerialRegistration {
        TahoeAerialRegistration(
            asset: TahoeAerialAssetRecord(
                id: id,
                displayName: "Aurora",
                videoURL: root.appending(path: "\(id).mov")
            ),
            videoHash: "0123456789abcdef",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
