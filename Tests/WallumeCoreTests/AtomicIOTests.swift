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

private final class FailFirstDirectorySynchronization: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func synchronize(_ directory: URL) throws {
        let failure = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        if failure { throw InjectedFailure.synchronizeDirectory }
    }
}

private func itemNames(in directory: URL) throws -> Set<String> {
    Set(
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
    )
}

private func retainedPreparedFiles(in directory: URL, for targetName: String) throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".\(targetName).wallume.tmp.") }
}

final class AtomicIOTests: XCTestCase {
    func testAtomicWriteRaceReplacingDestinationWithDirectoryPreservesItsContents() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let sentinel = target.appending(path: "sentinel")
        try Data("old".utf8).write(to: target)
        let prepared = LockedURLs()
        let files = LocalFileStore(
            synchronizeDirectory: { _ in },
            beforeAtomicReplacement: { target, preparedFile in
                prepared.append(preparedFile)
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: sentinel)
            }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target))

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        let preparedFile = try XCTUnwrap(prepared.values.first)
        XCTAssertEqual(try Data(contentsOf: preparedFile), Data("new".utf8))
    }

    func testAtomicWriteRejectsPreparedFileReplacedWithSymlinkBeforeRename() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let referent = root.appending(path: "referent")
        try Data("old".utf8).write(to: target)
        try Data("outside".utf8).write(to: referent)
        let prepared = LockedURLs()
        let files = LocalFileStore(
            synchronizeDirectory: { _ in },
            beforeAtomicReplacement: { _, preparedFile in
                prepared.append(preparedFile)
                try FileManager.default.removeItem(at: preparedFile)
                try FileManager.default.createSymbolicLink(at: preparedFile, withDestinationURL: referent)
            }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target)) { error in
            guard case .unsafeReplacementTarget? = error as? AtomicFileStoreError else {
                return XCTFail("Expected unsafe prepared-source rejection, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        let preparedFile = try XCTUnwrap(prepared.values.first)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: preparedFile.path), referent.path)
    }

    func testPostRenameSynchronizationFailureMustNotReportSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let protectedDirectory = root.appending(path: "protected-directory")
        let protectedLink = root.appending(path: "protected-link")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: protectedDirectory.appending(path: "sentinel"))
        try FileManager.default.createSymbolicLink(at: protectedLink, withDestinationURL: protectedDirectory)
        let files = LocalFileStore(
            synchronizeDirectory: { _ in },
            synchronizeCommittedDirectories: { _, _ in throw InjectedFailure.synchronizeDirectory }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target)) {
            XCTAssertEqual($0 as? AtomicFileStoreError, .durabilityUncertain(target))
        }

        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: protectedDirectory.appending(path: "sentinel")), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedLink.path))
    }

    func testAtomicJSONDurabilityUncertainLeavesNewDocumentReadable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "journal.json")
        let files = LocalFileStore(
            synchronizeDirectory: { _ in },
            synchronizeCommittedDirectories: { _, _ in throw InjectedFailure.synchronizeDirectory }
        )
        let store = AtomicJSONStore(files: files)
        let document = JournalFixture(phase: "committed", count: 1)

        XCTAssertThrowsError(try store.write(document, to: target)) {
            XCTAssertEqual($0 as? AtomicFileStoreError, .durabilityUncertain(target))
        }
        XCTAssertEqual(try store.read(JournalFixture.self, from: target), document)
    }

    func testReplaceRejectsDirectoryTargetWithoutDeletingItsContents() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let prepared = root.appending(path: "prepared")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appending(path: "sentinel"))
        try Data("new".utf8).write(to: prepared)

        XCTAssertThrowsError(try LocalFileStore().replace(target, with: prepared))
        XCTAssertEqual(try Data(contentsOf: target.appending(path: "sentinel")), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: prepared), Data("new".utf8))
    }

    func testGuardedRemoveRejectsSymlinkedParentEvenForSameInode() throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path) : temporary
        let root = base.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trusted = root.appending(path: "trusted")
        let displaced = root.appending(path: "displaced")
        let sentinel = root.appending(path: "sentinel")
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        let target = trusted.appending(path: "capture")
        let sentinelFile = sentinel.appending(path: "capture")
        try Data("owned".utf8).write(to: target)
        try FileManager.default.linkItem(at: target, to: sentinelFile)
        let files = LocalFileStore()
        let identity = try files.identity(of: target)
        try FileManager.default.moveItem(at: trusted, to: displaced)
        try FileManager.default.createSymbolicLink(at: trusted, withDestinationURL: sentinel)

        XCTAssertFalse(try files.removeDurably(target, ifIdentityMatches: identity))
        XCTAssertEqual(try Data(contentsOf: sentinelFile), Data("owned".utf8))
    }

    func testPrivateCleanupDirectoryIsOwnerOnly() throws {
        let temporary = FileManager.default.temporaryDirectory
        let base = temporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporary.path) : temporary
        let root = base.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    func testFailedAtomicWritePreservesDestinationAndRetainsPreparedFileSafely() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let old = Data("old".utf8)
        try old.write(to: target)
        let files = LocalFileStore(
            synchronizeDirectory: { _ in throw InjectedFailure.synchronizeDirectory }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target))

        XCTAssertEqual(try Data(contentsOf: target), old)
        let retained = try XCTUnwrap(retainedPreparedFiles(in: root, for: "target").only)
        XCTAssertEqual(try Data(contentsOf: retained), Data("new".utf8))
    }

    func testFailedAtomicOverwriteAfterReplacementRestoresOldBytesAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        let old = Data("old".utf8)
        try old.write(to: target)
        let synchronization = FailFirstDirectorySynchronization()
        let files = LocalFileStore(
            synchronizeDirectory: { try synchronization.synchronize($0) }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target))
        XCTAssertEqual(try files.read(target), old)

        try files.writeAtomically(Data("new".utf8), to: target)
        XCTAssertEqual(try files.read(target), Data("new".utf8))
    }

    func testFailedCopyPreservesDestinationAndRetainsPreparedFileSafely() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        let old = Data("old".utf8)
        try Data("new".utf8).write(to: source)
        try old.write(to: destination)
        let files = LocalFileStore(
            synchronizeDirectory: { _ in throw InjectedFailure.synchronizeDirectory }
        )

        XCTAssertThrowsError(try files.copy(source, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), old)
        let retained = try XCTUnwrap(retainedPreparedFiles(in: root, for: "destination").only)
        XCTAssertEqual(try Data(contentsOf: retained), Data("new".utf8))
    }

    func testDirectorySynchronizationFailureIsPropagated() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "target")
        let files = LocalFileStore(
            synchronizeDirectory: { _ in throw InjectedFailure.synchronizeDirectory }
        )

        XCTAssertThrowsError(try files.writeAtomically(Data("new".utf8), to: target)) { error in
            guard case InjectedFailure.synchronizeDirectory = error else {
                return XCTFail("Expected directory synchronization failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let retained = try XCTUnwrap(retainedPreparedFiles(in: root, for: "target").only)
        XCTAssertEqual(try Data(contentsOf: retained), Data("new".utf8))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
