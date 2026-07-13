import Foundation
import XCTest
@testable import WallumeCore

final class RecoveryCoordinatorTests: XCTestCase {
    func testRestoresEveryOwnedValueWhenCurrentHashesStillMatchInstalledHashes() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertEqual(report.conflicts, [])
        XCTAssertTrue(report.restored.contains(fixture.manifest.video.target))
        XCTAssertTrue(report.restored.contains(fixture.manifest.poster.target))
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.originalHash
        )
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
    }

    func testDoesNotOverwriteSystemRedownloadOrExternalIndexChange() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.writeAtomically(
            Data("system-redownload".utf8),
            to: fixture.manifest.video.target
        )
        try fixture.externallyChangeIndex()

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(
            String(data: try fixture.files.read(fixture.manifest.video.target), encoding: .utf8),
            "system-redownload"
        )
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertTrue(report.retainedBackups.contains(fixture.manifest.recoveryBackup))
    }

    func testPreparedAndPartiallyWritingJournalsConvergeWithoutConflicts() throws {
        let cases: [(String, TransactionPhase, Bool, Bool, Bool, Int)] = [
            ("afterPreparedJournal", .prepared, false, false, false, 0),
            ("afterVideoReplacement", .writing, true, false, false, 1),
            ("afterIndexReplacement", .writing, true, true, false, 2),
            ("afterPosterReplacement", .writing, true, true, true, 3),
            ("beforeCommit", .writing, true, true, true, 3),
        ]
        for (name, phase, videoInstalled, indexInstalled, posterInstalled, changedCount) in cases {
            let fixture = try RecoveryFixture.installed()
            defer { fixture.remove() }
            try fixture.setCrashState(
                phase: phase,
                videoInstalled: videoInstalled,
                indexInstalled: indexInstalled,
                posterInstalled: posterInstalled
            )

            let report = try fixture.recovery.restore(id: fixture.manifest.id)

            XCTAssertTrue(report.conflicts.isEmpty, name)
            XCTAssertEqual(report.restored.count, changedCount, name)
            XCTAssertEqual(try fixture.loadManifest().phase, .restored)
            XCTAssertEqual(fixture.refresher.refreshCount, changedCount == 0 ? 0 : 1)
        }
    }

    func testRemovesInstalledPosterWhenItDidNotExistBeforeInstall() throws {
        let fixture = try RecoveryFixture.installed(originalPosterExists: false)
        defer { fixture.remove() }

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertTrue(report.restored.contains(fixture.manifest.poster.target))
        XCTAssertFalse(fixture.files.exists(fixture.manifest.poster.target))
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
    }

    func testOriginallyAbsentPosterThatWasNeverWrittenIsAlreadyRestored() throws {
        let fixture = try RecoveryFixture.installed(originalPosterExists: false)
        defer { fixture.remove() }
        try fixture.files.remove(fixture.manifest.poster.target)
        try fixture.setCrashState(
            phase: .prepared,
            videoInstalled: false,
            indexInstalled: false,
            posterInstalled: false
        )

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertTrue(report.restored.isEmpty)
        XCTAssertFalse(fixture.files.exists(fixture.manifest.poster.target))
        XCTAssertEqual(fixture.refresher.refreshCount, 0)
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
    }

    func testMissingVideoBackupsFailsClosedAndRetainsEveryRemainingBackup() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.remove(fixture.manifest.primaryBackup)
        try fixture.files.remove(fixture.manifest.recoveryBackup)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.installedHash
        )
        XCTAssertTrue(report.retainedBackups.contains(try XCTUnwrap(fixture.manifest.poster.originalBackup)))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testCorruptVideoBackupsFailClosedWithoutReplacingInstalledVideo() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.writeAtomically(Data("corrupt-primary".utf8), to: fixture.manifest.primaryBackup)
        try fixture.files.writeAtomically(Data("corrupt-recovery".utf8), to: fixture.manifest.recoveryBackup)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.digest.sha256(of: fixture.manifest.video.target), fixture.manifest.video.installedHash)
        XCTAssertTrue(report.retainedBackups.contains(fixture.manifest.primaryBackup))
        XCTAssertTrue(report.retainedBackups.contains(fixture.manifest.recoveryBackup))
    }

    func testPartialIndexConflictRestoresOnlyStillOwnedMutation() throws {
        let originalIndex = try recoveryIndexWithTwoChoices()
        let fixture = try RecoveryFixture.installed(indexOriginal: originalIndex)
        defer { fixture.remove() }
        XCTAssertEqual(fixture.manifest.indexMutations.count, 2)
        let externalFragment = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "EXTERNAL", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        let externallyChanged = try recoveryReplacingValue(
            externalFragment,
            at: fixture.manifest.indexMutations[0].path,
            in: fixture.files.read(fixture.manifest.indexURL)
        )
        try fixture.files.writeAtomically(externallyChanged, to: fixture.manifest.indexURL)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        let restoredIndex = try fixture.files.read(fixture.manifest.indexURL)
        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertTrue(report.restored.contains(fixture.manifest.indexURL))
        XCTAssertEqual(
            try recoveryValue(at: fixture.manifest.indexMutations[0].path, in: restoredIndex) as? Data,
            externalFragment
        )
        XCTAssertEqual(
            try recoveryValue(at: fixture.manifest.indexMutations[1].path, in: restoredIndex) as? Data,
            try PropertyListSerialization.propertyList(
                from: fixture.manifest.indexMutations[1].before,
                options: [],
                format: nil
            ) as? Data
        )
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testAbsentOriginalPosterQuarantinePreservesExternalRace() throws {
        let fixture = try RecoveryFixture.installed(originalPosterExists: false)
        defer { fixture.remove() }
        fixture.files.raceQuarantineSource = fixture.manifest.poster.target

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.poster.target))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.poster.target), Data("external-race".utf8))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testIndexSnapshotRaceIsSwappedBackWithoutOverwritingExternalBytes() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        fixture.files.raceTarget = fixture.manifest.indexURL

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.indexURL), Data("external-race".utf8))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testInvalidExternalIndexIsPreservedAndRecordedAsConflict() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let invalidIndex = Data([0xFF, 0x00, 0xFF])
        try fixture.files.writeAtomically(invalidIndex, to: fixture.manifest.indexURL)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.indexURL), invalidIndex)
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testSecondRestoreAfterCleanRecoveryIsIdempotentAndDoesNotRefresh() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertEqual(report, RecoveryReport(restored: [], conflicts: [], retainedBackups: []))
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
    }

    func testInspectFindsRecoverablePhasesInStableOrderAndSkipsRestored() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.remove(fixture.journalURL)
        let phases: [TransactionPhase] = [.conflicted, .restored, .committed, .prepared, .writing]
        for (offset, phase) in phases.enumerated() {
            var manifest = fixture.manifestWith(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset + 1))!,
                phase: phase,
                createdAt: Date(timeIntervalSince1970: Double(100 - offset))
            )
            manifest.phase = phase
            try fixture.writeManifest(manifest)
        }

        let candidates = try fixture.recovery.inspect()

        XCTAssertEqual(candidates.map(\.phase), [.writing, .prepared, .committed, .conflicted])
    }

    func testInspectFailsClosedForUnknownSchema() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.remove(fixture.journalURL)
        try fixture.writeManifest(fixture.manifestWith(schemaVersion: 99))

        XCTAssertThrowsError(try fixture.recovery.inspect()) {
            XCTAssertEqual($0 as? RecoveryCoordinatorError, .unsupportedSchema(99))
        }
    }

    func testInspectFailsClosedForCorruptJournal() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.writeAtomically(Data("not-json".utf8), to: fixture.journalURL)

        XCTAssertThrowsError(try fixture.recovery.inspect()) {
            guard case .invalidJournalFile = $0 as? RecoveryCoordinatorError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testRestoreFailsClosedForMismatchedOriginalHashAndBackupPair() throws {
        let fixture = try RecoveryFixture.installed(originalPosterExists: false)
        defer { fixture.remove() }
        let inconsistentPoster = FileReplacementRecord(
            target: fixture.manifest.poster.target,
            originalHash: nil,
            installedHash: fixture.manifest.poster.installedHash,
            originalBackup: fixture.root.appending(path: "unexpected-poster-backup")
        )
        let inconsistent = fixture.manifestWith(poster: inconsistentPoster)
        try fixture.writeManifest(inconsistent)

        XCTAssertThrowsError(try fixture.recovery.restore(id: inconsistent.id)) {
            XCTAssertEqual($0 as? RecoveryCoordinatorError, .invalidManifest(inconsistent.id))
        }
        XCTAssertTrue(fixture.files.exists(inconsistent.poster.target))
    }

    func testAtomicExchangeRollbackFailureIsReportedAsSeriousError() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        fixture.files.raceTarget = fixture.manifest.video.target
        fixture.files.failRollbackTarget = fixture.manifest.video.target

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id)) {
            XCTAssertEqual(
                $0 as? RecoveryCoordinatorError,
                .guardedRecoveryFailed(fixture.manifest.video.target)
            )
        }
    }

    func testDisplacedEntityVerificationErrorSwapsTargetBack() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        fixture.files.failPreparedReadNumber = 2

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id)) {
            XCTAssertTrue($0 is RecoveryFixtureError)
        }
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.installedHash
        )
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }
}

private struct RecoveryFixture {
    let root: URL
    let paths: AerialPaths
    let files: RecoveryTestFileStore
    let digest: RecoveryTestDigester
    let journals: AtomicJSONStore
    let refresher: RecoveryTestRefresher
    let recovery: RecoveryCoordinator
    let manifest: LockScreenTransactionManifest

    var journalURL: URL {
        paths.transactionsDirectory.appending(path: "\(manifest.id.uuidString).json")
    }

    var allBackups: [URL] {
        [manifest.video.originalBackup, manifest.poster.originalBackup,
         Optional(manifest.primaryBackup), Optional(manifest.recoveryBackup)].compactMap { $0 }
    }

    static func installed(
        originalPosterExists: Bool = true,
        indexOriginal: Data? = nil
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Wallume-RecoveryTests-\(UUID().uuidString)")
        let paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST")
        let files = RecoveryTestFileStore()
        let digest = RecoveryTestDigester(files: files)
        let journals = AtomicJSONStore(files: files)
        let refresher = RecoveryTestRefresher()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let fixtureDirectory = root.appending(path: "fixture")
        let video = fixtureDirectory.appending(path: "video.mov")
        let poster = fixtureDirectory.appending(path: "poster.png")
        let index = fixtureDirectory.appending(path: "Index.plist")
        let videoBackup = fixtureDirectory.appending(path: "video.original")
        let recoveryBackup = fixtureDirectory.appending(path: "video.recovery")
        let posterBackup = fixtureDirectory.appending(path: "poster.original")

        try files.createDirectory(paths.transactionsDirectory)
        try files.createDirectory(fixtureDirectory)
        try files.writeAtomically(Data("original-video".utf8), to: videoBackup)
        try files.writeAtomically(Data("original-video".utf8), to: recoveryBackup)
        if originalPosterExists {
            try files.writeAtomically(Data("original-poster".utf8), to: posterBackup)
        }
        try files.writeAtomically(Data("installed-video".utf8), to: video)
        try files.writeAtomically(Data("installed-poster".utf8), to: poster)
        let originalIndex: Data
        if let indexOriginal {
            originalIndex = indexOriginal
        } else {
            guard let originalIndexURL = Bundle.module.url(
                forResource: "index-tahoe",
                withExtension: "plist",
                subdirectory: "Fixtures"
            ) else { throw RecoveryFixtureError.missingIndexFixture }
            originalIndex = try files.read(originalIndexURL)
        }
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: originalIndex, aerialID: "AERIAL-ONE")
        try files.writeAtomically(try patcher.apply(mutations, to: originalIndex), to: index)

        let manifest = LockScreenTransactionManifest(
            schemaVersion: 1,
            id: id,
            phase: .committed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            osMajorVersion: 26,
            aerialID: "AERIAL-ONE",
            video: FileReplacementRecord(
                target: video,
                originalHash: try digest.sha256(of: videoBackup),
                installedHash: try digest.sha256(of: video),
                originalBackup: videoBackup
            ),
            poster: FileReplacementRecord(
                target: poster,
                originalHash: originalPosterExists ? try digest.sha256(of: posterBackup) : nil,
                installedHash: try digest.sha256(of: poster),
                originalBackup: originalPosterExists ? posterBackup : nil
            ),
            indexURL: index,
            indexMutations: mutations,
            primaryBackup: videoBackup,
            recoveryBackup: recoveryBackup
        )
        try journals.write(
            manifest,
            to: paths.transactionsDirectory.appending(path: "\(id.uuidString).json")
        )
        return Self(
            root: root,
            paths: paths,
            files: files,
            digest: digest,
            journals: journals,
            refresher: refresher,
            recovery: RecoveryCoordinator(
                paths: paths,
                files: files,
                digester: digest,
                journals: journals,
                patcher: patcher,
                refresher: refresher
            ),
            manifest: manifest
        )
    }

    func loadManifest() throws -> LockScreenTransactionManifest {
        try journals.read(
            LockScreenTransactionManifest.self,
            from: paths.transactionsDirectory.appending(path: "\(manifest.id.uuidString).json")
        )
    }

    func setCrashState(
        phase: TransactionPhase,
        videoInstalled: Bool,
        indexInstalled: Bool,
        posterInstalled: Bool
    ) throws {
        if !videoInstalled {
            try files.copy(manifest.primaryBackup, to: manifest.video.target)
        }
        if !indexInstalled {
            let current = try files.read(manifest.indexURL)
            let original = try WallpaperIndexPatcher().restore(manifest.indexMutations, in: current).data
            try files.writeAtomically(original, to: manifest.indexURL)
        }
        if !posterInstalled, let backup = manifest.poster.originalBackup {
            try files.copy(backup, to: manifest.poster.target)
        }
        var changed = manifest
        changed.phase = phase
        try writeManifest(changed)
    }

    func manifestWith(
        schemaVersion: Int = 1,
        id: UUID? = nil,
        phase: TransactionPhase? = nil,
        createdAt: Date? = nil,
        poster: FileReplacementRecord? = nil
    ) -> LockScreenTransactionManifest {
        LockScreenTransactionManifest(
            schemaVersion: schemaVersion,
            id: id ?? manifest.id,
            phase: phase ?? manifest.phase,
            createdAt: createdAt ?? manifest.createdAt,
            osMajorVersion: manifest.osMajorVersion,
            aerialID: manifest.aerialID,
            video: manifest.video,
            poster: poster ?? manifest.poster,
            indexURL: manifest.indexURL,
            indexMutations: manifest.indexMutations,
            primaryBackup: manifest.primaryBackup,
            recoveryBackup: manifest.recoveryBackup
        )
    }

    func writeManifest(_ value: LockScreenTransactionManifest) throws {
        try journals.write(
            value,
            to: paths.transactionsDirectory.appending(path: "\(value.id.uuidString).json")
        )
    }

    func externallyChangeIndex() throws {
        let current = try files.read(manifest.indexURL)
        let patcher = WallpaperIndexPatcher()
        let mutations = try patcher.plan(indexData: current, aerialID: "EXTERNAL-AERIAL")
        try files.writeAtomically(try patcher.apply(mutations, to: current), to: manifest.indexURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct RecoveryTestDigester: Digesting {
    let files: RecoveryTestFileStore
    func sha256(of url: URL) throws -> String {
        try files.read(url).map { String(format: "%02x", $0) }.joined()
    }
}

private final class RecoveryTestFileStore: FileStore, @unchecked Sendable {
    private let local = LocalFileStore()
    private let lock = NSLock()
    var raceTarget: URL?
    var failRollbackTarget: URL?
    var raceQuarantineSource: URL?
    var failPreparedReadNumber: Int?
    private var exchangeCounts: [URL: Int] = [:]
    private var preparedReadCount = 0

    func exists(_ url: URL) -> Bool { local.exists(url) }
    func read(_ url: URL) throws -> Data {
        if url.lastPathComponent.contains(".restore.") {
            preparedReadCount += 1
            if failPreparedReadNumber == preparedReadCount {
                throw RecoveryFixtureError.injected
            }
        }
        return try local.read(url)
    }
    func contents(_ directory: URL) throws -> [URL] { try local.contents(directory) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(url) }
    func writeAtomically(_ data: Data, to target: URL) throws {
        try local.writeAtomically(data, to: target)
    }
    func copy(_ source: URL, to destination: URL) throws { try local.copy(source, to: destination) }
    func replace(_ target: URL, with preparedFile: URL) throws {
        try local.replace(target, with: preparedFile)
    }
    func exchange(_ target: URL, with preparedFile: URL) throws {
        let count = lock.withLock { () -> Int in
            exchangeCounts[target, default: 0] += 1
            return exchangeCounts[target]!
        }
        if raceTarget == target, count == 1 {
            try local.writeAtomically(Data("external-race".utf8), to: target)
        }
        if failRollbackTarget == target, count == 2 {
            throw RecoveryFixtureError.injected
        }
        try local.exchange(target, with: preparedFile)
    }
    func installExclusively(_ target: URL, from preparedFile: URL) throws {
        if raceQuarantineSource == preparedFile {
            raceQuarantineSource = nil
            try local.writeAtomically(Data("external-race".utf8), to: preparedFile)
        }
        try local.installExclusively(target, from: preparedFile)
    }
    func remove(_ url: URL) throws { try local.remove(url) }
}

private final class RecoveryTestRefresher: WallpaperRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var refreshCount: Int { lock.withLock { count } }
    func refresh() throws { lock.withLock { count += 1 } }
}

private enum RecoveryFixtureError: Error { case missingIndexFixture, injected }

private func recoveryIndexWithTwoChoices() throws -> Data {
    func configuration(_ selectedID: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": selectedID, "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
    }
    return try PropertyListSerialization.data(
        fromPropertyList: [
            "Idle": [
                "Content": [
                    "Choices": [
                        [
                            "AssetID": "FIRST",
                            "Provider": "com.apple.wallpaper.choice.aerials",
                            "Configuration": try configuration("ORIGINAL-FIRST"),
                        ],
                        [
                            "AssetID": "SECOND",
                            "Provider": "com.apple.wallpaper.choice.aerials",
                            "Configuration": try configuration("ORIGINAL-SECOND"),
                        ],
                    ],
                ],
            ],
        ],
        format: .binary,
        options: 0
    )
}

private func recoveryReplacingValue(
    _ value: Any,
    at path: [PlistPathComponent],
    in data: Data
) throws -> Data {
    var root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    try recoverySetValue(value, at: path[...], in: &root)
    return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}

private func recoveryValue(at path: [PlistPathComponent], in data: Data) throws -> Any {
    var value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    for component in path {
        switch component {
        case let .key(key): value = try XCTUnwrap((value as? [String: Any])?[key])
        case let .index(index): value = (try XCTUnwrap(value as? [Any]))[index]
        }
    }
    return value
}

private func recoverySetValue(
    _ value: Any,
    at path: ArraySlice<PlistPathComponent>,
    in root: inout Any
) throws {
    guard let component = path.first else { root = value; return }
    switch component {
    case let .key(key):
        var dictionary = try XCTUnwrap(root as? [String: Any])
        var child = try XCTUnwrap(dictionary[key])
        try recoverySetValue(value, at: path.dropFirst(), in: &child)
        dictionary[key] = child
        root = dictionary
    case let .index(index):
        var array = try XCTUnwrap(root as? [Any])
        var child = array[index]
        try recoverySetValue(value, at: path.dropFirst(), in: &child)
        array[index] = child
        root = array
    }
}
