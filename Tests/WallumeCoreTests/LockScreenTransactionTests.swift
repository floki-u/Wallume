import Foundation
import XCTest
@testable import WallumeCore

final class LockScreenTransactionTests: XCTestCase {
    func testInstallCommitsOnlyAfterVideoIndexAndPosterVerify() throws {
        let fixture = try TransactionFixture.make()
        defer { fixture.remove() }

        let result = try fixture.transaction.install(fixture.request)

        XCTAssertEqual(result.phase, .committed)
        XCTAssertEqual(try fixture.digest.sha256(of: fixture.slotVideo), result.video.installedHash)
        XCTAssertEqual(try fixture.digest.sha256(of: fixture.posterTarget), result.poster.installedHash)
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
        XCTAssertTrue(fixture.files.exists(result.primaryBackup))
        XCTAssertTrue(fixture.files.exists(result.recoveryBackup))
        XCTAssertEqual(
            try fixture.journals.read(
                LockScreenTransactionManifest.self,
                from: try fixture.onlyJournalURL()
            ),
            result
        )
        XCTAssertEqual(
            result.primaryBackup.lastPathComponent,
            fixture.slotVideo.lastPathComponent + WallumeBuildInfo.backupMarker
        )
        XCTAssertEqual(
            result.primaryBackup.deletingLastPathComponent().standardizedFileURL,
            result.video.target.deletingLastPathComponent().standardizedFileURL
        )
        assertOrder(
            ["journal:prepared", "fault:afterPreparedJournal", "journal:writing",
             "exchange:video", "fault:afterVideoReplacement", "exchange:index",
             "fault:afterIndexReplacement", "exchange:poster",
             "fault:afterPosterReplacement", "refresh", "fault:beforeCommit",
             "journal:committed"],
            in: fixture.events
        )
    }

    func testFailureAfterVideoReplacementLeavesRecoverableWritingJournal() throws {
        let fixture = try TransactionFixture.make(failingAt: .afterVideoReplacement)
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request))

        let manifest = try fixture.journals.read(
            LockScreenTransactionManifest.self,
            from: try fixture.onlyJournalURL()
        )
        XCTAssertEqual(manifest.phase, .writing)
        XCTAssertTrue(fixture.files.exists(manifest.primaryBackup))
        XCTAssertTrue(fixture.files.exists(manifest.recoveryBackup))
    }

    func testEveryFaultBoundaryLeavesTheLastDurableNonCommittedPhase() throws {
        let cases: [(TransactionFaultPoint, TransactionPhase, Int)] = [
            (.afterPreparedJournal, .prepared, 0),
            (.afterVideoReplacement, .writing, 0),
            (.afterIndexReplacement, .writing, 0),
            (.afterPosterReplacement, .writing, 0),
            (.beforeCommit, .writing, 1),
        ]
        for (point, expectedPhase, refreshCount) in cases {
            let fixture = try TransactionFixture.make(failingAt: point)
            defer { fixture.remove() }

            XCTAssertThrowsError(try fixture.transaction.install(fixture.request), "\(point)")

            let manifest = try fixture.journals.read(
                LockScreenTransactionManifest.self,
                from: try fixture.onlyJournalURL()
            )
            XCTAssertEqual(manifest.phase, expectedPhase, "\(point)")
            XCTAssertEqual(fixture.refresher.refreshCount, refreshCount, "\(point)")
            XCTAssertFalse(fixture.events.contains("journal:committed"), "\(point)")
        }
    }

    func testUnsupportedOSIsRejectedBeforeAnyDirectoryCreation() throws {
        let fixture = TransactionFixture.makeUnsupported()
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            XCTAssertEqual($0 as? LockScreenTransactionError, .unsupportedOS(27))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testEveryRequiredBackupIsVerifiedBeforePreparedJournalOrReplacement() throws {
        for corruption in [FileCorruption.primaryVideoBackup, .recoveryVideoBackup, .posterBackup] {
            let fixture = try TransactionFixture.make(corrupting: corruption)
            defer { fixture.remove() }

            XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
                guard case .backupVerificationFailed = $0 as? LockScreenTransactionError else {
                    return XCTFail("unexpected error: \($0)")
                }
            }
            XCTAssertFalse(fixture.events.contains(where: { $0.hasPrefix("journal:") }), "\(corruption)")
            XCTAssertFalse(fixture.events.contains(where: { $0.hasPrefix("replace:") }), "\(corruption)")
        }
    }

    func testVerificationFailuresNeverCommitOrAdvanceToLaterReplacement() throws {
        let cases: [(FileCorruption, String, [String])] = [
            (.installedVideo, "exchange:video", ["exchange:index", "exchange:poster", "refresh"]),
            (.installedIndex, "exchange:index", ["exchange:poster", "refresh"]),
            (.installedPoster, "exchange:poster", ["refresh"]),
        ]
        for (corruption, reached, forbidden) in cases {
            let fixture = try TransactionFixture.make(corrupting: corruption)
            defer { fixture.remove() }

            XCTAssertThrowsError(try fixture.transaction.install(fixture.request), "\(corruption)")

            XCTAssertTrue(fixture.events.contains(reached), "\(corruption)")
            XCTAssertTrue(forbidden.allSatisfy { !fixture.events.contains($0) }, "\(corruption)")
            XCTAssertFalse(fixture.events.contains("journal:committed"), "\(corruption)")
            let manifest = try fixture.journals.read(
                LockScreenTransactionManifest.self,
                from: try fixture.onlyJournalURL()
            )
            XCTAssertEqual(manifest.phase, .writing, "\(corruption)")
        }
    }

    func testRefreshFailureLeavesWritingJournal() throws {
        let fixture = try TransactionFixture.make(refreshFails: true)
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request))

        let manifest = try fixture.journals.read(
            LockScreenTransactionManifest.self,
            from: try fixture.onlyJournalURL()
        )
        XCTAssertEqual(manifest.phase, .writing)
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
        XCTAssertFalse(fixture.events.contains("fault:beforeCommit"))
        XCTAssertFalse(fixture.events.contains("journal:committed"))
    }

    func testMissingOriginalPosterRecordsNoBackupAndStillInstallsPoster() throws {
        let fixture = try TransactionFixture.make(originalPosterExists: false)
        defer { fixture.remove() }

        let manifest = try fixture.transaction.install(fixture.request)

        XCTAssertNil(manifest.poster.originalHash)
        XCTAssertNil(manifest.poster.originalBackup)
        XCTAssertEqual(manifest.poster.installedHash, try fixture.digest.sha256(of: fixture.posterTarget))
        XCTAssertTrue(fixture.events.contains("exclusive:poster"))
        XCTAssertEqual(manifest.phase, .committed)
    }

    func testInvalidIndexFailsBeforeBackupOrJournalDirectoriesAreCreated() throws {
        let fixture = try TransactionFixture.make(indexData: Data([0xFF, 0x00, 0xFF]))
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            XCTAssertEqual($0 as? WallpaperIndexError, .invalidPropertyList)
        }
        XCTAssertFalse(fixture.files.exists(fixture.paths.systemBackupsDirectory))
        XCTAssertFalse(fixture.files.exists(fixture.paths.transactionsDirectory))
        XCTAssertFalse(fixture.events.contains(where: { $0.hasPrefix("replace:") }))
    }

    func testVideoChangedAfterPreflightIsPreservedAndAbortsBeforeReplacement() throws {
        let fixture = try TransactionFixture.make(corrupting: .raceVideo)
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            guard case let .targetChanged(target) = $0 as? LockScreenTransactionError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(target.lastPathComponent, "AERIAL-ONE.mov")
        }

        XCTAssertEqual(try fixture.files.read(fixture.slotVideo), Data("external-video".utf8))
        XCTAssertFalse(fixture.events.contains("replace:video"))
        XCTAssertFalse(fixture.events.contains("replace:index"))
        XCTAssertFalse(fixture.events.contains("replace:poster"))
        XCTAssertFalse(fixture.events.contains("refresh"))
        XCTAssertFalse(fixture.events.contains("journal:committed"))
        XCTAssertEqual(try fixture.persistedManifest().phase, .writing)
    }

    func testPosterCreatedAfterInitiallyMissingIsPreservedAndAborts() throws {
        let fixture = try TransactionFixture.make(
            corrupting: .racePoster,
            originalPosterExists: false
        )
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            XCTAssertEqual(
                $0 as? LockScreenTransactionError,
                .targetChanged(fixture.posterTarget)
            )
        }

        XCTAssertEqual(
            try fixture.files.read(fixture.posterTarget),
            Data("external-poster".utf8)
        )
        XCTAssertFalse(fixture.events.contains("replace:poster"))
        XCTAssertFalse(fixture.events.contains("refresh"))
        XCTAssertFalse(fixture.events.contains("journal:committed"))
        XCTAssertEqual(try fixture.persistedManifest().phase, .writing)
    }

    func testIndexChangedAfterPlanningIsPreservedAndAbortsBeforeReplacement() throws {
        let fixture = try TransactionFixture.make(corrupting: .raceIndex)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            XCTAssertEqual(
                $0 as? LockScreenTransactionError,
                .targetChanged(fixture.paths.wallpaperIndex)
            )
        }

        XCTAssertEqual(
            try selectedAerialID(in: fixture.files.read(fixture.paths.wallpaperIndex)),
            "EXTERNAL-AERIAL"
        )
        XCTAssertTrue(fixture.events.contains("exchange:video"))
        XCTAssertFalse(fixture.events.contains("replace:index"))
        XCTAssertFalse(fixture.events.contains("replace:poster"))
        XCTAssertFalse(fixture.events.contains("refresh"))
        XCTAssertFalse(fixture.events.contains("journal:committed"))
        XCTAssertEqual(try fixture.persistedManifest().phase, .writing)
    }

    func testExistingPosterChangedBeforeReplacementIsPreservedAndAborts() throws {
        let fixture = try TransactionFixture.make(corrupting: .racePoster)
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            XCTAssertEqual(
                $0 as? LockScreenTransactionError,
                .targetChanged(fixture.posterTarget)
            )
        }

        XCTAssertEqual(
            try fixture.files.read(fixture.posterTarget),
            Data("external-poster".utf8)
        )
        XCTAssertTrue(fixture.events.contains("exchange:video"))
        XCTAssertTrue(fixture.events.contains("exchange:index"))
        XCTAssertFalse(fixture.events.contains("replace:poster"))
        XCTAssertFalse(fixture.events.contains("refresh"))
        XCTAssertFalse(fixture.events.contains("journal:committed"))
        XCTAssertEqual(try fixture.persistedManifest().phase, .writing)
    }

    func testMismatchRollbackFailureIsReportedAsSeriousRecoveryFailure() throws {
        let fixture = try TransactionFixture.make(corrupting: .raceVideoRollbackFailure)
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.transaction.install(fixture.request)) {
            guard case let .guardedReplacementRecoveryFailed(target) =
                $0 as? LockScreenTransactionError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(target.lastPathComponent, "AERIAL-ONE.mov")
        }

        XCTAssertEqual(try fixture.files.read(fixture.slotVideo), Data("optimized-video".utf8))
        XCTAssertEqual(
            try fixture.files.read(fixture.preparedURL(for: fixture.slotVideo)),
            Data("external-video".utf8)
        )
        XCTAssertEqual(fixture.events.filter { $0 == "exchange:video" }.count, 1)
        XCTAssertFalse(fixture.events.contains("exchange:index"))
        XCTAssertFalse(fixture.events.contains("refresh"))
        XCTAssertFalse(fixture.events.contains("journal:committed"))
        XCTAssertEqual(try fixture.persistedManifest().phase, .writing)
    }

    private func assertOrder(
        _ expected: [String],
        in actual: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = actual.startIndex
        for event in expected {
            guard let index = actual[cursor...].firstIndex(of: event) else {
                return XCTFail("missing ordered event \(event) in \(actual)", file: file, line: line)
            }
            cursor = actual.index(after: index)
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] { lock.withLock { storage } }
    func append(_ event: String) { lock.withLock { storage.append(event) } }
}

private struct TestFileStore: FileStore {
    let root: URL
    let recorder: EventRecorder
    let corruption: FileCorruption
    private let local = LocalFileStore()

    func exists(_ url: URL) -> Bool { local.exists(mapped(url)) }
    func read(_ url: URL) throws -> Data { try local.read(mapped(url)) }
    func contents(_ directory: URL) throws -> [URL] {
        try local.contents(mapped(directory)).map { unmapped($0, from: directory) }
    }
    func createDirectory(_ url: URL) throws { try local.createDirectory(mapped(url)) }
    func writeAtomically(_ data: Data, to target: URL) throws {
        if target.path.contains("/LockScreen/transactions/"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let phase = json["phase"] as? String {
            recorder.append("journal:\(phase)")
        }
        try local.writeAtomically(data, to: mapped(target))
    }
    func writeExclusively(_ data: Data, to target: URL) throws {
        try local.writeExclusively(data, to: mapped(target))
    }
    func copy(_ source: URL, to destination: URL) throws {
        try local.copy(mapped(source), to: mapped(destination))
        if corruption.matches(destination) {
            try local.writeAtomically(Data("corrupted-copy".utf8), to: mapped(destination))
        }
    }
    func copyExclusively(_ source: URL, to destination: URL) throws {
        try local.copyExclusively(mapped(source), to: mapped(destination))
    }
    func replace(_ target: URL, with preparedFile: URL) throws {
        if target.lastPathComponent == "Index.plist" { recorder.append("replace:index") }
        else if target.lastPathComponent == "lockscreen.png" { recorder.append("replace:poster") }
        else if target.pathExtension == "mov" { recorder.append("replace:video") }
        try local.replace(mapped(target), with: mapped(preparedFile))
        if corruption.matchesReplacement(target) {
            try local.writeAtomically(Data("corrupted-replacement".utf8), to: mapped(target))
        }
    }
    func exchange(_ target: URL, with preparedFile: URL) throws {
        let kind = targetKind(target)
        if corruption == .raceVideoRollbackFailure,
           kind == "video",
           recorder.events.contains("exchange:video") {
            throw TestError.injected
        }
        if !recorder.events.contains("race:\(kind)") {
            switch (corruption, kind) {
            case (.raceVideo, "video"), (.raceVideoRollbackFailure, "video"):
                try local.writeAtomically(Data("external-video".utf8), to: mapped(target))
                recorder.append("race:video")
            case (.raceIndex, "index"):
                let external = try externallyChangedIndex(local.read(mapped(target)))
                try local.writeAtomically(external, to: mapped(target))
                recorder.append("race:index")
            case (.racePoster, "poster"):
                try local.writeAtomically(Data("external-poster".utf8), to: mapped(target))
                recorder.append("race:poster")
            default:
                break
            }
        }
        try local.exchange(mapped(target), with: mapped(preparedFile))
        recorder.append("exchange:\(kind)")
        if corruption.matchesReplacement(target) {
            try local.writeAtomically(Data("corrupted-replacement".utf8), to: mapped(target))
        }
    }
    func installExclusively(_ target: URL, from preparedFile: URL) throws {
        if corruption == .racePoster {
            try local.writeAtomically(Data("external-poster".utf8), to: mapped(target))
            recorder.append("race:poster")
        }
        try local.installExclusively(mapped(target), from: mapped(preparedFile))
        recorder.append("exclusive:\(targetKind(target))")
    }
    func remove(_ url: URL) throws { try local.remove(mapped(url)) }

    private func mapped(_ url: URL) -> URL {
        guard url.path.hasPrefix("/Library/Caches/Desktop Pictures/") else { return url }
        return root.appending(path: "Synthetic-System-Library")
            .appending(path: String(url.path.dropFirst("/Library/Caches/Desktop Pictures/".count)))
    }

    private func unmapped(_ url: URL, from requestedDirectory: URL) -> URL {
        guard requestedDirectory.path.hasPrefix("/Library/Caches/Desktop Pictures/") else { return url }
        return requestedDirectory.appending(path: url.lastPathComponent)
    }

    private func targetKind(_ target: URL) -> String {
        if target.lastPathComponent == "Index.plist" { return "index" }
        if target.lastPathComponent == "lockscreen.png" { return "poster" }
        return "video"
    }
}

private enum FileCorruption: Sendable, Equatable {
    case none
    case primaryVideoBackup
    case recoveryVideoBackup
    case posterBackup
    case installedVideo
    case installedIndex
    case installedPoster
    case raceVideo
    case raceIndex
    case racePoster
    case raceVideoRollbackFailure

    func matches(_ destination: URL) -> Bool {
        switch self {
        case .none, .installedVideo, .installedIndex, .installedPoster,
             .raceVideo, .raceIndex, .racePoster, .raceVideoRollbackFailure:
            false
        case .primaryVideoBackup:
            destination.lastPathComponent.hasSuffix(WallumeBuildInfo.backupMarker)
        case .recoveryVideoBackup:
            destination.lastPathComponent.hasSuffix(".mov.original")
        case .posterBackup:
            destination.lastPathComponent.hasSuffix("lockscreen.png.original")
        }
    }

    func matchesReplacement(_ target: URL) -> Bool {
        switch self {
        case .installedVideo: target.pathExtension == "mov"
        case .installedIndex: target.lastPathComponent == "Index.plist"
        case .installedPoster: target.lastPathComponent == "lockscreen.png"
        default: false
        }
    }

}

private func externallyChangedIndex(_ data: Data) throws -> Data {
    let patcher = WallpaperIndexPatcher()
    return try patcher.apply(
        patcher.plan(indexData: data, aerialID: "EXTERNAL-AERIAL"),
        to: data
    )
}

private func selectedAerialID(in indexData: Data) throws -> String? {
    let mutation = try XCTUnwrap(
        WallpaperIndexPatcher().plan(indexData: indexData, aerialID: "IGNORED").first
    )
    let configuration = try XCTUnwrap(
        PropertyListSerialization.propertyList(
            from: mutation.before,
            options: [],
            format: nil
        ) as? Data
    )
    let values = try XCTUnwrap(
        PropertyListSerialization.propertyList(
            from: configuration,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    return values["selectedID"] as? String
}

private struct TestDigester: Digesting {
    let files: TestFileStore
    func sha256(of url: URL) throws -> String {
        let data = try files.read(url)
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

private final class TestRefresher: WallpaperRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: EventRecorder
    private let fails: Bool
    private var count = 0
    init(recorder: EventRecorder, fails: Bool = false) {
        self.recorder = recorder
        self.fails = fails
    }
    var refreshCount: Int { lock.withLock { count } }
    func refresh() throws {
        lock.withLock { count += 1 }
        recorder.append("refresh")
        if fails { throw TestError.injected }
    }
}

private struct TestFaults: FaultInjecting {
    let failure: TransactionFaultPoint?
    let recorder: EventRecorder
    func hit(_ point: TransactionFaultPoint) throws {
        recorder.append("fault:\(point)")
        if point == failure { throw TestError.injected }
    }
}

private enum TestError: Error { case injected, missingFixture, wrongJournalCount }

private struct TransactionFixture {
    let root: URL
    let paths: AerialPaths
    let files: TestFileStore
    let digest: TestDigester
    let journals: AtomicJSONStore
    let refresher: TestRefresher
    let transaction: LockScreenTransaction
    let request: LockScreenTransactionRequest
    let slotVideo: URL
    let optimizedVideo: URL
    let poster: URL
    let posterTarget: URL
    let recorder: EventRecorder

    var events: [String] { recorder.events }

    static func make(
        failingAt: TransactionFaultPoint? = nil,
        corrupting corruption: FileCorruption = .none,
        refreshFails: Bool = false,
        originalPosterExists: Bool = true,
        indexData: Data? = nil
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-TransactionTests-\(UUID().uuidString)")
        let paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST-USER")
        let recorder = EventRecorder()
        let files = TestFileStore(root: root, recorder: recorder, corruption: corruption)
        let digest = TestDigester(files: files)
        let journals = AtomicJSONStore(files: files)
        let refresher = TestRefresher(recorder: recorder, fails: refreshFails)
        try files.createDirectory(paths.videosDirectory)
        try files.createDirectory(paths.manifest.deletingLastPathComponent())
        try files.createDirectory(paths.wallpaperIndex.deletingLastPathComponent())
        try files.createDirectory(paths.lockScreenPoster.deletingLastPathComponent())
        let manifest = Data(#"{"assets":[{"id":"AERIAL-ONE","accessibilityLabel":"Test Coast"}]}"#.utf8)
        try files.writeAtomically(manifest, to: paths.manifest)
        let slotVideo = paths.videosDirectory.appending(path: "AERIAL-ONE.mov")
        try files.writeAtomically(Data("original-video".utf8), to: slotVideo)
        if let indexData {
            try files.writeAtomically(indexData, to: paths.wallpaperIndex)
        } else {
            guard let index = Bundle.module.url(forResource: "index-tahoe", withExtension: "plist", subdirectory: "Fixtures") else {
                throw TestError.missingFixture
            }
            try files.copy(index, to: paths.wallpaperIndex)
        }
        if originalPosterExists {
            try files.writeAtomically(Data("original-poster".utf8), to: paths.lockScreenPoster)
        }
        let optimizedVideo = root.appending(path: "inputs/optimized.mov")
        let poster = root.appending(path: "inputs/poster.png")
        try files.writeAtomically(Data("optimized-video".utf8), to: optimizedVideo)
        try files.writeAtomically(Data("new-poster".utf8), to: poster)
        let transaction = LockScreenTransaction(
            paths: paths,
            files: files,
            digester: digest,
            journals: journals,
            discovery: AerialDiscovery(files: files),
            patcher: WallpaperIndexPatcher(),
            refresher: refresher,
            faults: TestFaults(failure: failingAt, recorder: recorder),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeID: { UUID(uuidString: "00000000-0000-0000-0000-000000000006")! }
        )
        return Self(
            root: root, paths: paths, files: files, digest: digest, journals: journals,
            refresher: refresher, transaction: transaction,
            request: .init(
                systemVersion: .init(majorVersion: 26, minorVersion: 5, patchVersion: 2),
                aerialID: "AERIAL-ONE", optimizedVideo: optimizedVideo, poster: poster
            ),
            slotVideo: slotVideo, optimizedVideo: optimizedVideo, poster: poster,
            posterTarget: paths.lockScreenPoster, recorder: recorder
        )
    }

    static func makeUnsupported() -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-UnsupportedTransactionTests-\(UUID().uuidString)")
        let paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST-USER")
        let recorder = EventRecorder()
        let files = TestFileStore(root: root, recorder: recorder, corruption: .none)
        let digest = TestDigester(files: files)
        let journals = AtomicJSONStore(files: files)
        let refresher = TestRefresher(recorder: recorder)
        let request = LockScreenTransactionRequest(
            systemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            aerialID: "AERIAL-ONE",
            optimizedVideo: root.appending(path: "missing.mov"),
            poster: root.appending(path: "missing.png")
        )
        let transaction = LockScreenTransaction(
            paths: paths,
            files: files,
            digester: digest,
            journals: journals,
            discovery: AerialDiscovery(files: files),
            patcher: WallpaperIndexPatcher(),
            refresher: refresher,
            faults: TestFaults(failure: nil, recorder: recorder)
        )
        return Self(
            root: root, paths: paths, files: files, digest: digest, journals: journals,
            refresher: refresher, transaction: transaction, request: request,
            slotVideo: paths.videosDirectory.appending(path: "AERIAL-ONE.mov"),
            optimizedVideo: request.optimizedVideo, poster: request.poster,
            posterTarget: paths.lockScreenPoster, recorder: recorder
        )
    }

    func onlyJournalURL() throws -> URL {
        let journals = try files.contents(paths.transactionsDirectory)
        guard journals.count == 1 else { throw TestError.wrongJournalCount }
        return journals[0]
    }

    func persistedManifest() throws -> LockScreenTransactionManifest {
        try journals.read(LockScreenTransactionManifest.self, from: onlyJournalURL())
    }

    func preparedURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appending(
            path: ".\(target.lastPathComponent).wallume.00000000-0000-0000-0000-000000000006.prepared"
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
