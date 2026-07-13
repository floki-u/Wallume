import XCTest
@testable import WallumeCore

private struct JournalFixture: Codable, Equatable, Sendable {
    let phase: String
    let count: Int
}

private enum InjectedFailure: Error {
    case replace
    case synchronizeDirectory
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error] = []

    func append(_ error: Error) {
        lock.withLock {
            failures.append(error)
        }
    }

    var values: [Error] {
        lock.withLock { failures }
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    var values: [URL] { lock.withLock { urls } }
}

private func itemNames(in directory: URL) throws -> Set<String> {
    Set(
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
    )
}

final class AtomicIOTests: XCTestCase {
    func testPrivateCleanupDirectoryIsOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "cleanup")

        try LocalFileStore().createPrivateDirectory(directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testIndependentAdvisoryLocksSerializeAccess() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "shared.lock")
        var first: (any AdvisoryLockToken)? = try FileAdvisoryLock(url: url).acquire()
        XCTAssertNotNil(first)
        let acquired = expectation(description: "second lock acquired")
        let state = LockedURLs()
        DispatchQueue.global().async {
            do {
                let second = try FileAdvisoryLock(url: url).acquire()
                state.append(url)
                withExtendedLifetime(second) {}
                acquired.fulfill()
            } catch {
                acquired.fulfill()
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(state.values.isEmpty)
        first = nil
        wait(for: [acquired], timeout: 2)
        XCTAssertEqual(state.values, [url])
    }

    func testRemoveSynchronizesItsParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        try Data("value".utf8).write(to: target)
        let synchronized = LockedURLs()
        let files = LocalFileStore(
            replaceItem: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { synchronized.append($0) }
        )

        try files.remove(target)

        XCTAssertEqual(synchronized.values.map(\.standardizedFileURL), [root.standardizedFileURL])
    }
    func testAtomicExchangeSwapsTwoExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let prepared = root.appending(path: "prepared")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: prepared)
        let files = LocalFileStore()

        try files.exchange(target, with: prepared)

        XCTAssertEqual(try files.read(target), Data("new".utf8))
        XCTAssertEqual(try files.read(prepared), Data("old".utf8))
    }

    func testExclusiveInstallNeverOverwritesAnExistingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let prepared = root.appending(path: "prepared")
        try Data("external".utf8).write(to: target)
        try Data("new".utf8).write(to: prepared)
        let files = LocalFileStore()

        XCTAssertThrowsError(try files.installExclusively(target, from: prepared))

        XCTAssertEqual(try files.read(target), Data("external".utf8))
        XCTAssertEqual(try files.read(prepared), Data("new".utf8))
    }

    func testExclusiveWriteAndCopyNeverOverwriteExistingArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let source = root.appending(path: "source")
        let files = LocalFileStore()
        try files.writeAtomically(Data("external".utf8), to: target)
        try files.writeAtomically(Data("source".utf8), to: source)

        XCTAssertThrowsError(try files.writeExclusively(Data("new".utf8), to: target))
        XCTAssertThrowsError(try files.copyExclusively(source, to: target))

        XCTAssertEqual(try files.read(target), Data("external".utf8))
        XCTAssertEqual(try itemNames(in: root), ["source", "target"])
    }

    func testExchangeSynchronizationFailureRestoresOriginalNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let prepared = root.appending(path: "prepared")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: prepared)
        let files = LocalFileStore(
            replaceItem: { _, _ in },
            synchronizeDirectory: { _ in throw InjectedFailure.synchronizeDirectory }
        )

        XCTAssertThrowsError(try files.exchange(target, with: prepared)) {
            XCTAssertEqual($0 as? AtomicFileStoreError, .exchangeRecoveryFailed(target))
        }

        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: prepared), Data("new".utf8))
    }

    func testAtomicJSONRoundTripLeavesNoTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "journal.json")
        let files = LocalFileStore()
        let store = AtomicJSONStore(files: files)
        try files.writeAtomically(Data("old".utf8), to: target)

        try store.write(JournalFixture(phase: "prepared", count: 2), to: target)

        XCTAssertEqual(
            try store.read(JournalFixture.self, from: target),
            .init(phase: "prepared", count: 2)
        )
        XCTAssertEqual(try itemNames(in: root), ["journal.json"])
    }

    func testSHA256UsesLowercaseHex() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "value")
        try Data("wallume".utf8).write(to: file)

        XCTAssertEqual(
            try SHA256Digester().sha256(of: file),
            "66c0fb338a923a6b5af567f8489078f61fc52d070a952d6aa602b484a5c31e60"
        )
    }

    func testConcurrentAtomicWritesInstallOneCompletePayload() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "shared")
        let files = LocalFileStore()
        let payloads = (0..<32).map { Data(repeating: UInt8($0), count: 256 * 1_024) }
        let failures = LockedFailures()

        DispatchQueue.concurrentPerform(iterations: payloads.count) { index in
            do {
                try files.writeAtomically(payloads[index], to: target)
            } catch {
                failures.append(error)
            }
        }

        XCTAssertTrue(failures.values.isEmpty, "Unexpected write failures: \(failures.values)")
        XCTAssertTrue(payloads.contains(try files.read(target)))
        XCTAssertEqual(try itemNames(in: root), ["shared"])
    }

    func testCopyAtomicallyOverwritesDestinationWithCompleteContents() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        let expected = Data(repeating: 0xA5, count: 512 * 1_024)
        try expected.write(to: source)
        try Data("old".utf8).write(to: destination)
        let files = LocalFileStore()

        try files.copy(source, to: destination)

        XCTAssertEqual(try files.read(destination), expected)
        XCTAssertEqual(try itemNames(in: root), ["source", "destination"])
    }

    func testFailedAtomicWritePreservesDestinationAndCleansTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let old = Data("old".utf8)
        try old.write(to: target)
        let files = LocalFileStore(
            replaceItem: { _, _ in throw InjectedFailure.replace },
            synchronizeDirectory: { _ in }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target))

        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertEqual(try itemNames(in: root), ["target"])
    }

    func testFailedCopyPreservesDestinationAndCleansTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        let old = Data("old".utf8)
        try Data("new".utf8).write(to: source)
        try old.write(to: destination)
        let files = LocalFileStore(
            replaceItem: { _, _ in throw InjectedFailure.replace },
            synchronizeDirectory: { _ in }
        )

        XCTAssertThrowsError(try files.copy(source, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), old)
        XCTAssertEqual(try itemNames(in: root), ["source", "destination"])
    }

    func testDirectorySynchronizationFailureIsPropagated() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "target")
        let files = LocalFileStore(
            replaceItem: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
            },
            synchronizeDirectory: { _ in throw InjectedFailure.synchronizeDirectory }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target)) { error in
            guard case InjectedFailure.synchronizeDirectory = error else {
                return XCTFail("Expected directory synchronization failure, got \(error)")
            }
        }
        XCTAssertEqual(try itemNames(in: root), ["target"])
    }
}
