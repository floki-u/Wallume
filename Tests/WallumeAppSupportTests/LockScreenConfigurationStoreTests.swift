import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class LockScreenConfigurationStoreTests: XCTestCase {
    func testMissingFileLoadsDisabledUnselectedConfiguration() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }

        let configuration = try await fixture.store.load()

        XCTAssertEqual(configuration, .disabled)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertNil(configuration.selectedAerialID)
        XCTAssertNil(configuration.activeTransactionID)
        XCTAssertNil(configuration.lastSyncedMediaID)
        XCTAssertNil(configuration.lastSyncedAt)
        XCTAssertEqual(fixture.files.writeCount, 0)
    }

    func testUpdateAtomicallyPersistsAndReloadsConfiguration() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let configuration = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: "com.apple.aerials.sea",
            activeTransactionID: UUID(),
            lastSyncedMediaID: UUID(),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastResult: .synced
        )

        _ = try await fixture.store.load()
        try await fixture.store.update(configuration)

        let reloaded = try await fixture.reloadedStore().load()
        XCTAssertEqual(reloaded, configuration)
        XCTAssertEqual(fixture.files.writeCount, 1)
    }

    func testUnsupportedSchemaFailsClosedAndPreservesFile() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let data = Data(#"{"schemaVersion":99,"isEnabled":false}"#.utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected unsupported schema")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unsupportedSchema(99))
        }

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testMalformedJSONFailsClosedAndPreservesFile() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let data = Data("not json".utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected malformed JSON")
        } catch {}

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testMutationBeforeLoadDoesNotAttemptWrite() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let configuration = LockScreenConfiguration(isEnabled: true, selectedAerialID: "com.apple.aerials.sea")

        do {
            try await fixture.store.update(configuration)
            XCTFail("Expected unloaded store to reject mutation")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableBeforeLoad)
        }

        XCTAssertEqual(fixture.files.writeCount, 0)
        XCTAssertFalse(fixture.files.exists(fixture.url))
    }

    func testMutationAfterReadFailureDoesNotAttemptWriteOrOverwriteFile() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let data = Data("not json".utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount
        do {
            _ = try await fixture.store.load()
            XCTFail("Expected malformed JSON")
        } catch {}

        do {
            try await fixture.store.update(.disabled)
            XCTFail("Expected failed store to reject mutation")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableAfterLoadFailure)
        }

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }
}

private final class LockScreenConfigurationFixture {
    let root: URL
    let url: URL
    let files = CountingFileStore()
    lazy var store = makeStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        url = root.appending(path: "lock-screen-configuration.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func reloadedStore() -> LockScreenConfigurationStore { makeStore() }

    private func makeStore() -> LockScreenConfigurationStore {
        LockScreenConfigurationStore(url: url, files: files, jsonStore: AtomicJSONStore(files: files))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class CountingFileStore: FileStore, @unchecked Sendable {
    private let local = LocalFileStore()
    private(set) var writeCount = 0

    func exists(_ url: URL) -> Bool { local.exists(url) }
    func read(_ url: URL) throws -> Data { try local.read(url) }
    func contents(_ directory: URL) throws -> [URL] { try local.contents(directory) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(url) }
    func createPrivateDirectory(_ url: URL) throws { try local.createPrivateDirectory(url) }
    func identity(of url: URL) throws -> FileIdentity { try local.identity(of: url) }
    func hasNoSymlinkComponents(_ url: URL) throws -> Bool { try local.hasNoSymlinkComponents(url) }
    func removeDurably(_ url: URL, ifIdentityMatches identity: FileIdentity) throws -> Bool {
        try local.removeDurably(url, ifIdentityMatches: identity)
    }
    func writeAtomically(_ data: Data, to target: URL) throws {
        writeCount += 1
        try local.writeAtomically(data, to: target)
    }
    func writeExclusively(_ data: Data, to target: URL) throws { try local.writeExclusively(data, to: target) }
    func copy(_ source: URL, to destination: URL) throws { try local.copy(source, to: destination) }
    func copyExclusively(_ source: URL, to destination: URL) throws { try local.copyExclusively(source, to: destination) }
    func replace(_ target: URL, with preparedFile: URL) throws { try local.replace(target, with: preparedFile) }
    func exchange(_ target: URL, with preparedFile: URL) throws { try local.exchange(target, with: preparedFile) }
    func installExclusively(_ target: URL, from preparedFile: URL) throws { try local.installExclusively(target, from: preparedFile) }
    func remove(_ url: URL) throws { try local.remove(url) }
}
