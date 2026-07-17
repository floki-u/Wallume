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
        XCTAssertEqual(fixture.advisoryLock.acquireCount, 0)
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

    func testPersistedResultMessageWithAPathFailsClosedWithoutOverwrite() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let path = "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        let data = Data("""
        {"schemaVersion":1,"isEnabled":true,"selectedAerialID":"com.apple.aerials.sea","lastResult":{"waiting":{"message":"\(path)"}}}
        """.utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected unbounded result message to be rejected")
        } catch {}

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testPersistedMediaWithoutSyncDateFailsClosedWithoutOverwrite() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let data = Data("""
        {"schemaVersion":1,"isEnabled":true,"selectedAerialID":"com.apple.aerials.sea","lastSyncedMediaID":"\(UUID().uuidString)"}
        """.utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected incomplete sync metadata to be rejected")
        } catch {}

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testUnknownPersistedFieldsFailClosedWithoutOverwrite() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let data = Data("""
        {"schemaVersion":1,"isEnabled":false,"backupPath":"/temporary/recovery","targetHash":"not-a-hash","mediaPath":"/temporary/media.mov"}
        """.utf8)
        try fixture.files.writeAtomically(data, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected unknown persisted fields to be rejected")
        } catch {}

        do {
            try await fixture.store.update(.disabled)
            XCTFail("Expected failed load to gate mutations")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableAfterLoadFailure)
        }

        XCTAssertEqual(try fixture.files.read(fixture.url), data)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testSwapDuringLoadCannotMakeUnvalidatedDocumentMutable() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let validatedData = Data(#"{"schemaVersion":1,"isEnabled":false}"#.utf8)
        let swappedData = Data(#"{"schemaVersion":1,"isEnabled":false,"backupPath":"/temporary/recovery"}"#.utf8)
        try fixture.files.writeAtomically(validatedData, to: fixture.url)
        fixture.files.swapAfterNextRead(with: swappedData, at: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected swapped document to fail closed")
        } catch {}

        do {
            try await fixture.store.update(.disabled)
            XCTFail("Expected swapped document to gate mutations")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableAfterLoadFailure)
        }

        XCTAssertEqual(try fixture.files.read(fixture.url), swappedData)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testExternalReplacementAfterLoadCannotBeOverwritten() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let enabled = LockScreenConfiguration(isEnabled: true, selectedAerialID: "com.apple.aerials.sea")
        _ = try await fixture.store.load()
        try await fixture.store.update(enabled)
        let externallyReplaced = Data(#"{"schemaVersion":1,"isEnabled":false,"targetHash":"external"}"#.utf8)
        fixture.files.replaceExternally(externallyReplaced, at: fixture.url)
        let writesBeforeUpdate = fixture.files.writeCount

        do {
            try await fixture.store.update(.disabled)
            XCTFail("Expected external replacement to reject mutation")
        } catch {}

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot, .disabled)
        XCTAssertEqual(try fixture.files.read(fixture.url), externallyReplaced)
        XCTAssertEqual(fixture.files.writeCount, writesBeforeUpdate)
    }

    func testPostWriteFailurePublishesDisabledStateAndBlocksFutureUpdates() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let enabled = LockScreenConfiguration(isEnabled: true, selectedAerialID: "com.apple.aerials.sea")
        _ = try await fixture.store.load()
        let stream = await fixture.store.events()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .disabled)
        fixture.files.failAfterNextWrite = true

        do {
            try await fixture.store.update(enabled)
            XCTFail("Expected post-write failure")
        } catch {}

        do {
            try await fixture.store.update(enabled)
            XCTFail("Expected failed store to block retry")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableAfterLoadFailure)
        }

        let safe = await iterator.next()
        XCTAssertEqual(safe, .disabled)
        XCTAssertEqual(fixture.files.writeCount, 1)
        XCTAssertEqual(fixture.advisoryLock.acquireCount, 1)
    }

    func testLoadedStoreDoesNotRereadMalformedExternalReplacement() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let enabled = LockScreenConfiguration(isEnabled: true, selectedAerialID: "com.apple.aerials.sea")
        _ = try await fixture.store.load()
        try await fixture.store.update(enabled)
        let invalidData = Data("not json".utf8)
        try fixture.files.writeAtomically(invalidData, to: fixture.url)
        let retried = try await fixture.store.load()

        XCTAssertEqual(retried, enabled)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot, enabled)
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

    func testValidReplacementCannotReopenStoreAfterMalformedLoadInSameProcess() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let malformed = Data("not json".utf8)
        try fixture.files.writeAtomically(malformed, to: fixture.url)
        let writesBeforeLoad = fixture.files.writeCount

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected malformed load")
        } catch {}
        fixture.files.replaceExternally(
            Data(#"{"schemaVersion":1,"isEnabled":false}"#.utf8),
            at: fixture.url
        )

        do {
            _ = try await fixture.store.load()
            XCTFail("Expected failed store to reject reload until process relaunch")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableAfterLoadFailure)
        }
        do {
            try await fixture.store.update(.disabled)
            XCTFail("Expected failed store to reject mutation")
        } catch let error as LockScreenConfigurationStoreError {
            XCTAssertEqual(error, .unavailableAfterLoadFailure)
        }

        XCTAssertEqual(fixture.files.writeCount, writesBeforeLoad)
    }

    func testRestoreMarkerWithoutTransactionReferenceFailsClosed() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.store.load()
        let writesBeforeUpdate = fixture.files.writeCount
        let invalid = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: "com.apple.aerials.sea",
            lastResult: .restoring
        )

        do {
            try await fixture.store.update(invalid)
            XCTFail("Expected restore marker without transaction to be rejected")
        } catch {}

        XCTAssertEqual(fixture.files.writeCount, writesBeforeUpdate)
    }

    func testLoadedStoreReturnsTrustedSnapshotWithoutRereadingExternalReplacement() async throws {
        let fixture = try LockScreenConfigurationFixture()
        defer { fixture.cleanup() }
        let initial = try await fixture.store.load()
        XCTAssertEqual(initial, .disabled)
        fixture.files.replaceExternally(
            Data(#"{"schemaVersion":1,"isEnabled":true,"selectedAerialID":"com.apple.aerials.sea"}"#.utf8),
            at: fixture.url
        )

        let retried = try await fixture.store.load()

        XCTAssertEqual(retried, .disabled)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot, .disabled)
    }
}

private final class LockScreenConfigurationFixture {
    let root: URL
    let url: URL
    let files = CountingFileStore()
    let advisoryLock = RecordingAdvisoryLock()
    lazy var store = makeStore()

    init() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private" + temporaryPath : temporaryPath
        root = URL(fileURLWithPath: canonicalTemporaryPath).appending(path: UUID().uuidString)
        url = root.appending(path: "lock-screen-configuration.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func reloadedStore() -> LockScreenConfigurationStore { makeStore() }

    private func makeStore() -> LockScreenConfigurationStore {
        LockScreenConfigurationStore(
            url: url,
            files: files,
            jsonStore: AtomicJSONStore(files: files),
            advisoryLock: advisoryLock
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class CountingFileStore: FileStore, @unchecked Sendable {
    private let local = LocalFileStore()
    private(set) var writeCount = 0
    private var pendingSwap: (url: URL, data: Data)?
    var failAfterNextWrite = false

    func exists(_ url: URL) -> Bool { local.exists(url) }
    func read(_ url: URL) throws -> Data {
        let data = try local.read(url)
        if let pendingSwap, pendingSwap.url == url {
            self.pendingSwap = nil
            try local.writeAtomically(pendingSwap.data, to: url)
        }
        return data
    }
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
        if failAfterNextWrite {
            failAfterNextWrite = false
            throw TestFileStoreError.postWriteFailure
        }
    }
    func writeExclusively(_ data: Data, to target: URL) throws { try local.writeExclusively(data, to: target) }
    func copy(_ source: URL, to destination: URL) throws { try local.copy(source, to: destination) }
    func copyExclusively(_ source: URL, to destination: URL) throws { try local.copyExclusively(source, to: destination) }
    func replace(_ target: URL, with preparedFile: URL) throws { try local.replace(target, with: preparedFile) }
    func exchange(_ target: URL, with preparedFile: URL) throws { try local.exchange(target, with: preparedFile) }
    func installExclusively(_ target: URL, from preparedFile: URL) throws { try local.installExclusively(target, from: preparedFile) }
    func remove(_ url: URL) throws { try local.remove(url) }

    func swapAfterNextRead(with data: Data, at url: URL) {
        pendingSwap = (url, data)
    }

    func replaceExternally(_ data: Data, at url: URL) {
        try? local.writeAtomically(data, to: url)
    }
}

private enum TestFileStoreError: Error { case postWriteFailure }

private final class RecordingAdvisoryLock: AdvisoryLocking, @unchecked Sendable {
    private(set) var acquireCount = 0

    func acquire() throws -> any AdvisoryLockToken {
        acquireCount += 1
        return TestAdvisoryLockToken()
    }
}

private final class TestAdvisoryLockToken: AdvisoryLockToken, @unchecked Sendable {}
