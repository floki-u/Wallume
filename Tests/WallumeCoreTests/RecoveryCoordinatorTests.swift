import Foundation
import XCTest
@testable import WallumeCore

final class RecoveryCoordinatorTests: XCTestCase {
    func testRestoreRejectsSymlinkJournalBeforeReadingItsExternalManifest() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let external = fixture.root.appending(path: "external-journal.json")
        try fixture.files.copy(fixture.journalURL, to: external)
        try fixture.files.remove(fixture.journalURL)
        try FileManager.default.createSymbolicLink(at: fixture.journalURL, withDestinationURL: external)
        let installed = try fixture.files.read(fixture.manifest.video.target)

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id)) {
            XCTAssertEqual($0 as? RecoveryCoordinatorError, .invalidJournalFile(fixture.journalURL))
        }
        XCTAssertEqual(try fixture.files.read(fixture.manifest.video.target), installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testInspectFailsClosedForSymlinkJournal() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let external = fixture.root.appending(path: "inspect-external-journal.json")
        try fixture.files.copy(fixture.journalURL, to: external)
        try fixture.files.remove(fixture.journalURL)
        try FileManager.default.createSymbolicLink(at: fixture.journalURL, withDestinationURL: external)

        XCTAssertThrowsError(try fixture.recovery.inspect()) {
            guard case let .invalidJournalFile(url) = $0 as? RecoveryCoordinatorError else {
                return XCTFail("unexpected error: \($0)")
            }
            XCTAssertEqual(url.lastPathComponent, fixture.journalURL.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testRestoreRejectsSymlinkedTransactionsDirectory() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let directory = fixture.paths.transactionsDirectory
        let sentinel = fixture.root.appending(path: "external-transactions")
        try FileManager.default.moveItem(at: directory, to: sentinel)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: sentinel)
        let installed = try fixture.files.read(fixture.manifest.video.target)

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id)) {
            XCTAssertEqual($0 as? RecoveryCoordinatorError, .invalidJournalFile(fixture.journalURL))
        }
        XCTAssertEqual(try fixture.files.read(fixture.manifest.video.target), installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testVideoRestoreSymlinkIsConflictAndNeverInstalled() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        try FileManager.default.createSymbolicLink(
            at: artifact,
            withDestinationURL: fixture.manifest.primaryBackup
        )
        let backupBefore = try fixture.files.read(fixture.manifest.primaryBackup)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.installedHash
        )
        XCTAssertEqual(try fixture.files.read(fixture.manifest.primaryBackup), backupBefore)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testIndexRestoreSymlinkIsConflictAndReferentIsUntouched() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let installed = try fixture.files.read(fixture.manifest.indexURL)
        let restored = try WallpaperIndexPatcher().restore(
            fixture.manifest.indexMutations,
            in: installed
        ).data
        let sentinel = fixture.root.appending(path: "external-index-stage")
        try fixture.files.writeAtomically(restored, to: sentinel)
        let artifact = fixture.artifact(for: fixture.manifest.indexURL, role: "restore")
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: sentinel)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.indexURL), installed)
        XCTAssertEqual(try fixture.files.read(sentinel), restored)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testPosterRestoreSymlinkIsConflictAndBackupReferentIsUntouched() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let posterBackup = try XCTUnwrap(fixture.manifest.poster.originalBackup)
        let backupBefore = try fixture.files.read(posterBackup)
        let artifact = fixture.artifact(for: fixture.manifest.poster.target, role: "restore")
        try fixture.files.createSymbolicLink(at: artifact, withDestinationURL: posterBackup)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.poster.target))
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.poster.target),
            fixture.manifest.poster.installedHash
        )
        XCTAssertEqual(try fixture.files.read(posterBackup), backupBefore)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }
    func testRejectsManifestPointingAtUntrustedTargetBeforeMutation() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let sentinel = fixture.root.appending(path: "sensitive-sentinel")
        try fixture.files.writeAtomically(Data("keep".utf8), to: sentinel)
        let malicious = FileReplacementRecord(
            target: sentinel,
            originalHash: fixture.manifest.video.originalHash,
            installedHash: fixture.manifest.video.installedHash,
            originalBackup: fixture.manifest.video.originalBackup
        )
        try fixture.writeManifest(fixture.manifestWith(video: malicious))

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id)) {
            XCTAssertEqual($0 as? RecoveryCoordinatorError, .invalidManifest(fixture.manifest.id))
        }
        XCTAssertEqual(try fixture.files.read(sentinel), Data("keep".utf8))
        XCTAssertEqual(fixture.refresher.refreshCount, 0)
    }

    func testRejectsSymlinkedAllowedDirectoryBeforeTouchingSentinelTree() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let videos = fixture.paths.videosDirectory
        let sentinel = fixture.root.appending(path: "sentinel-videos")
        try FileManager.default.moveItem(at: videos, to: sentinel)
        try FileManager.default.createSymbolicLink(at: videos, withDestinationURL: sentinel)
        let sentinelVideo = sentinel.appending(path: fixture.manifest.video.target.lastPathComponent)
        let before = try Data(contentsOf: sentinelVideo)

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id)) {
            XCTAssertEqual($0 as? RecoveryCoordinatorError, .invalidManifest(fixture.manifest.id))
        }
        XCTAssertEqual(try Data(contentsOf: sentinelVideo), before)
        XCTAssertEqual(fixture.refresher.refreshCount, 0)
    }

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

    func testChangedRedundantBackupIsRetainedAndBlocksCleanup() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.writeAtomically(
            Data("external-backup".utf8),
            to: fixture.manifest.recoveryBackup
        )

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.recoveryBackup))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.recoveryBackup), Data("external-backup".utf8))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testRestartAfterAuthorizedPartialBackupCleanupConverges() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.setCrashState(
            phase: .restoring,
            videoInstalled: false,
            indexInstalled: false,
            posterInstalled: false
        )
        var manifest = try fixture.loadManifest()
        manifest.schemaVersion = 2
        manifest.backupCleanupAuthorized = true
        try fixture.writeManifest(manifest)
        try fixture.files.remove(fixture.manifest.recoveryBackup)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
        XCTAssertTrue(fixture.allBackups.allSatisfy { !fixture.files.exists($0) })
    }

    func testRestartFinishesOwnedBackupAlreadyMovedIntoCleanupCapture() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.setCrashState(
            phase: .restoring,
            videoInstalled: false,
            indexInstalled: false,
            posterInstalled: false
        )
        var manifest = try fixture.loadManifest()
        manifest.schemaVersion = 2
        manifest.backupCleanupAuthorized = true
        try fixture.writeManifest(manifest)
        let backup = fixture.manifest.recoveryBackup
        let directory = backup.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(manifest.id.uuidString)"
        )
        let capture = directory.appending(path: backup.lastPathComponent)
        try fixture.files.createPrivateDirectory(directory)
        try fixture.files.installExclusively(capture, from: backup)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertFalse(fixture.files.exists(capture))
        XCTAssertFalse(fixture.files.exists(directory))
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
    }

    func testUnownedBackupCleanupCaptureIsRetainedAndReported() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.setCrashState(
            phase: .restoring,
            videoInstalled: false,
            indexInstalled: false,
            posterInstalled: false
        )
        var manifest = try fixture.loadManifest()
        manifest.schemaVersion = 2
        manifest.backupCleanupAuthorized = true
        try fixture.writeManifest(manifest)
        let backup = fixture.manifest.recoveryBackup
        let directory = backup.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(manifest.id.uuidString)"
        )
        let capture = directory.appending(path: backup.lastPathComponent)
        try fixture.files.createPrivateDirectory(directory)
        try fixture.files.remove(backup)
        try fixture.files.writeExclusively(Data("unowned".utf8), to: capture)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(capture))
        XCTAssertTrue(report.retainedBackups.contains(capture))
        XCTAssertEqual(try fixture.files.read(capture), Data("unowned".utf8))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testAmbiguousFirstBackupPreventsDeletionOfEntireBackupGroup() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let backup = fixture.manifest.primaryBackup
        let directory = backup.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(fixture.manifest.id.uuidString)"
        )
        let capture = directory.appending(path: backup.lastPathComponent)
        try fixture.files.createPrivateDirectory(directory)
        try fixture.files.copy(backup, to: capture)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertTrue(fixture.files.exists(capture))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testRestartRemovesEmptyManifestCleanupDirectory() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.setCrashState(
            phase: .restoring,
            videoInstalled: false,
            indexInstalled: false,
            posterInstalled: false
        )
        var manifest = try fixture.loadManifest()
        manifest.schemaVersion = 2
        try fixture.writeManifest(manifest)
        let directory = fixture.manifest.indexURL.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(fixture.manifest.id.uuidString)"
        )
        try fixture.files.createPrivateDirectory(directory)

        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertFalse(fixture.files.exists(directory))
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
    }

    func testUnknownCleanupEntryIsRetainedAndConflictsItsTarget() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let directory = fixture.manifest.video.target.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(fixture.manifest.id.uuidString)"
        )
        let unknown = directory.appending(path: "unknown-entry")
        try fixture.files.createPrivateDirectory(directory)
        try fixture.files.writeExclusively(Data("external".utf8), to: unknown)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertTrue(fixture.files.exists(unknown))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
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
        let phases: [TransactionPhase] = [
            .conflicted, .restored, .committed, .prepared, .writing, .restoring,
        ]
        for (offset, phase) in phases.enumerated() {
            var manifest = fixture.manifestWith(
                schemaVersion: phase == .restoring ? 2 : 1,
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset + 1))!,
                phase: phase,
                createdAt: Date(timeIntervalSince1970: Double(100 - offset))
            )
            manifest.phase = phase
            try fixture.writeManifest(manifest)
        }

        let candidates = try fixture.recovery.inspect()

        XCTAssertEqual(
            candidates.map(\.phase),
            [.restoring, .writing, .prepared, .committed, .conflicted]
        )
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

    func testSchemaOneJournalCannotClaimSchemaTwoRestoringPhase() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.writeManifest(
            fixture.manifestWith(schemaVersion: 1, phase: .restoring)
        )

        XCTAssertThrowsError(try fixture.recovery.inspect()) {
            XCTAssertEqual(
                $0 as? RecoveryCoordinatorError,
                .invalidManifest(fixture.manifest.id)
            )
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

    func testRestartReconcilesExistingFileArtifactAfterExchange() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        try fixture.files.copy(fixture.manifest.video.target, to: artifact)
        try fixture.files.copy(fixture.manifest.primaryBackup, to: fixture.manifest.video.target)
        try fixture.writeManifest(fixture.manifestWith(schemaVersion: 2, phase: .restoring))

        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
        XCTAssertFalse(fixture.files.exists(artifact))
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
    }

    func testRestartReconcilesArtifactAlreadyMovedIntoCleanupCapture() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        let cleanupDirectory = artifact.deletingLastPathComponent().appending(
            path: ".wallume-cleanup-\(fixture.manifest.id.uuidString)"
        )
        try fixture.files.createPrivateDirectory(cleanupDirectory)
        let cleanup = cleanupDirectory.appending(path: artifact.lastPathComponent)
        try fixture.files.copy(fixture.manifest.video.target, to: cleanup)
        try fixture.files.copy(fixture.manifest.primaryBackup, to: fixture.manifest.video.target)
        try fixture.writeManifest(fixture.manifestWith(schemaVersion: 2, phase: .restoring))

        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertFalse(fixture.files.exists(artifact))
        XCTAssertFalse(fixture.files.exists(cleanup))
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
    }

    func testRestartContinuesFromExistingPreparedArtifactWithoutOverwritingIt() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        try fixture.files.copy(fixture.manifest.primaryBackup, to: artifact)

        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.originalHash
        )
        XCTAssertFalse(fixture.files.exists(artifact))
    }

    func testRestartCompletesOriginallyAbsentQuarantine() throws {
        let fixture = try RecoveryFixture.installed(originalPosterExists: false)
        defer { fixture.remove() }
        let quarantine = fixture.artifact(for: fixture.manifest.poster.target, role: "quarantine")
        try fixture.files.installExclusively(quarantine, from: fixture.manifest.poster.target)
        try fixture.writeManifest(fixture.manifestWith(schemaVersion: 2, phase: .restoring))

        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertFalse(fixture.files.exists(fixture.manifest.poster.target))
        XCTAssertFalse(fixture.files.exists(quarantine))
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
    }

    func testUnexplainedArtifactAndTargetCombinationFailsClosed() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        try fixture.files.writeAtomically(Data("unknown-artifact".utf8), to: artifact)
        try fixture.files.writeAtomically(Data("external-target".utf8), to: fixture.manifest.video.target)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.files.read(artifact), Data("unknown-artifact".utf8))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.video.target), Data("external-target".utf8))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testExternalIndexArtifactMatchingExternalTargetIsRetained() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.externallyChangeIndex()
        let artifact = fixture.artifact(for: fixture.manifest.indexURL, role: "restore")
        let external = try fixture.files.read(fixture.manifest.indexURL)
        try fixture.files.writeAtomically(external, to: artifact)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.indexURL), external)
        XCTAssertEqual(try fixture.files.read(artifact), external)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testArtifactCreatedDuringExclusiveStageInstallIsNeverOverwritten() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        fixture.files.raceCopyDestination = artifact

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.files.read(artifact), Data("external-artifact".utf8))
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.installedHash
        )
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testArtifactChangedAtCleanupIsAtomicallyRetainedAsConflict() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        fixture.files.raceRemoveTarget = artifact

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.files.read(artifact), Data("external-artifact".utf8))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
    }

    func testLastInstantCleanupCaptureReplacementIsNeverUnlinked() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        fixture.files.replaceCaptureBeforeGuardedRemove = artifact.lastPathComponent

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        let capture = artifact.deletingLastPathComponent()
            .appending(path: ".wallume-cleanup-\(fixture.manifest.id.uuidString)")
            .appending(path: artifact.lastPathComponent)
        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.files.read(capture), Data("last-instant-external".utf8))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testArtifactChangedImmediatelyBeforeExchangeIsSwappedBackAndRetained() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.video.target, role: "restore")
        fixture.files.racePreparedExchangeTarget = fixture.manifest.video.target

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(
            try fixture.digest.sha256(of: fixture.manifest.video.target),
            fixture.manifest.video.installedHash
        )
        XCTAssertEqual(try fixture.files.read(artifact), Data("external-artifact".utf8))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testLateTargetChangeIsIncludedInRecoveryReportConflicts() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        fixture.files.mutateTargetAfterCleanup = fixture.manifest.video.target

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testLateIndexWriteAfterRefreshIsAConflictAndRetainsBackups() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        fixture.refresher.onRefresh = { try fixture.externallyChangeIndex() }

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testRestartReconcilesIndexArtifactAfterExchange() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        let artifact = fixture.artifact(for: fixture.manifest.indexURL, role: "restore")
        let installed = try fixture.files.read(fixture.manifest.indexURL)
        let restored = try WallpaperIndexPatcher().restore(
            fixture.manifest.indexMutations,
            in: installed
        ).data
        try fixture.files.writeAtomically(installed, to: artifact)
        try fixture.files.writeAtomically(restored, to: fixture.manifest.indexURL)
        try fixture.writeManifest(fixture.manifestWith(schemaVersion: 2, phase: .restoring))

        _ = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertFalse(fixture.files.exists(artifact))
        XCTAssertEqual(try fixture.files.read(fixture.manifest.indexURL), restored)
        XCTAssertEqual(fixture.refresher.refreshCount, 1)
    }

    func testRestartReconcilesPartiallyRestoredIndexArtifactAfterExchange() throws {
        let fixture = try RecoveryFixture.installed(indexOriginal: recoveryIndexWithTwoChoices())
        defer { fixture.remove() }
        let mutation = fixture.manifest.indexMutations[0]
        let externalFragment = try PropertyListSerialization.data(
            fromPropertyList: ["selectedID": "EXTERNAL", "showAsScreenSaver": false],
            format: .binary,
            options: 0
        )
        let snapshot = try recoveryReplacingValue(
            externalFragment,
            at: mutation.path,
            in: fixture.files.read(fixture.manifest.indexURL)
        )
        let outcome = try WallpaperIndexPatcher().restore(
            fixture.manifest.indexMutations,
            in: snapshot
        )
        let artifact = fixture.artifact(for: fixture.manifest.indexURL, role: "restore")
        try fixture.files.writeAtomically(snapshot, to: artifact)
        try fixture.files.writeAtomically(outcome.data, to: fixture.manifest.indexURL)
        try fixture.writeManifest(fixture.manifestWith(schemaVersion: 2, phase: .restoring))

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.indexURL))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertEqual(try fixture.files.read(fixture.manifest.indexURL), outcome.data)
        XCTAssertFalse(fixture.files.exists(artifact))
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
    }

    func testRefreshFailureRetainsRestoringJournalBackupsAndArtifactsThenRetries() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        fixture.refresher.remainingFailures = 1

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id))

        XCTAssertEqual(try fixture.loadManifest().phase, .restoring)
        XCTAssertEqual(try fixture.loadManifest().schemaVersion, 2)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
        XCTAssertTrue(fixture.restoreArtifacts.contains(where: fixture.files.exists))

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertEqual(try fixture.loadManifest().phase, .restored)
        XCTAssertEqual(try fixture.loadManifest().schemaVersion, 2)
        XCTAssertEqual(fixture.refresher.refreshCount, 2)
        XCTAssertTrue(fixture.restoreArtifacts.allSatisfy { !fixture.files.exists($0) })
        XCTAssertTrue(fixture.allBackups.allSatisfy { !fixture.files.exists($0) })
    }

    func testRefreshRetryFinishesConflictedAndRetainsBackupsAfterPartialRestore() throws {
        let fixture = try RecoveryFixture.installed()
        defer { fixture.remove() }
        try fixture.files.writeAtomically(
            Data("external-video".utf8),
            to: fixture.manifest.video.target
        )
        fixture.refresher.remainingFailures = 1

        XCTAssertThrowsError(try fixture.recovery.restore(id: fixture.manifest.id))
        XCTAssertEqual(try fixture.loadManifest().phase, .restoring)

        let report = try fixture.recovery.restore(id: fixture.manifest.id)

        XCTAssertTrue(report.conflicts.contains(fixture.manifest.video.target))
        XCTAssertEqual(try fixture.loadManifest().phase, .conflicted)
        XCTAssertEqual(fixture.refresher.refreshCount, 2)
        XCTAssertTrue(fixture.allBackups.allSatisfy(fixture.files.exists))
        XCTAssertTrue(fixture.restoreArtifacts.allSatisfy { !fixture.files.exists($0) })
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

    var restoreArtifacts: [URL] {
        [artifact(for: manifest.video.target, role: "restore"),
         artifact(for: manifest.poster.target, role: "restore"),
         artifact(for: manifest.poster.target, role: "quarantine"),
         artifact(for: manifest.indexURL, role: "restore")]
    }

    func artifact(for target: URL, role: String) -> URL {
        target.deletingLastPathComponent().appending(
            path: ".\(target.lastPathComponent).wallume.\(manifest.id.uuidString).\(role)"
        )
    }

    static func installed(
        originalPosterExists: Bool = true,
        indexOriginal: Data? = nil
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "Wallume-RecoveryTests-\(UUID().uuidString)")
        let paths = AerialPaths(homeDirectory: root, userGeneratedID: "TEST")
        let files = RecoveryTestFileStore(root: root)
        let digest = RecoveryTestDigester(files: files)
        let journals = AtomicJSONStore(files: files)
        let refresher = RecoveryTestRefresher()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let fixtureDirectory = root.appending(path: "fixture")
        let video = paths.videosDirectory.appending(path: "AERIAL-ONE.mov")
        let poster = paths.lockScreenPoster
        let index = paths.wallpaperIndex
        let videoBackup = video.deletingLastPathComponent().appending(
            path: video.lastPathComponent + WallumeBuildInfo.backupMarker
        )
        let recoveryBackup = paths.systemBackupsDirectory.appending(
            path: "\(id.uuidString)-\(video.lastPathComponent).original"
        )
        let posterBackup = paths.systemBackupsDirectory.appending(
            path: "\(id.uuidString)-lockscreen.png.original"
        )

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
        video: FileReplacementRecord? = nil,
        poster: FileReplacementRecord? = nil
    ) -> LockScreenTransactionManifest {
        let selectedID = id ?? manifest.id
        let adjustedPoster: FileReplacementRecord
        if let poster {
            adjustedPoster = poster
        } else if id != nil {
            adjustedPoster = FileReplacementRecord(
                target: manifest.poster.target,
                originalHash: manifest.poster.originalHash,
                installedHash: manifest.poster.installedHash,
                originalBackup: manifest.poster.originalHash == nil ? nil : paths.systemBackupsDirectory.appending(
                    path: "\(selectedID.uuidString)-lockscreen.png.original"
                )
            )
        } else {
            adjustedPoster = manifest.poster
        }
        return LockScreenTransactionManifest(
            schemaVersion: schemaVersion,
            id: selectedID,
            phase: phase ?? manifest.phase,
            createdAt: createdAt ?? manifest.createdAt,
            osMajorVersion: manifest.osMajorVersion,
            aerialID: manifest.aerialID,
            video: video ?? manifest.video,
            poster: adjustedPoster,
            indexURL: manifest.indexURL,
            indexMutations: manifest.indexMutations,
            primaryBackup: manifest.primaryBackup,
            recoveryBackup: paths.systemBackupsDirectory.appending(
                path: "\(selectedID.uuidString)-\(manifest.video.target.lastPathComponent).original"
            )
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
    private let root: URL
    private let lock = NSLock()
    var raceTarget: URL?
    var failRollbackTarget: URL?
    var raceQuarantineSource: URL?
    var failPreparedReadNumber: Int?
    var raceCopyDestination: URL?
    var raceRemoveTarget: URL?
    var racePreparedExchangeTarget: URL?
    var mutateTargetAfterCleanup: URL?
    var replaceCaptureBeforeGuardedRemove: String?
    private var exchangeCounts: [URL: Int] = [:]
    private var preparedReadCount = 0

    init(root: URL) { self.root = root }

    private func mapped(_ url: URL) -> URL {
        guard url.path.hasPrefix("/Library/") else { return url }
        return root.appending(path: "Synthetic-System-Library")
            .appending(path: String(url.path.dropFirst("/Library/".count)))
    }

    func createSymbolicLink(at url: URL, withDestinationURL destination: URL) throws {
        try FileManager.default.createSymbolicLink(
            at: mapped(url),
            withDestinationURL: mapped(destination)
        )
    }

    func exists(_ url: URL) -> Bool { local.exists(mapped(url)) }
    func read(_ url: URL) throws -> Data {
        if url.lastPathComponent.hasSuffix(".restore") {
            preparedReadCount += 1
            if failPreparedReadNumber == preparedReadCount {
                throw RecoveryFixtureError.injected
            }
        }
        return try local.read(mapped(url))
    }
    func contents(_ directory: URL) throws -> [URL] { try local.contents(mapped(directory)) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(mapped(url)) }
    func createPrivateDirectory(_ url: URL) throws {
        try local.createPrivateDirectory(canonicalTestPath(mapped(url)))
    }
    func identity(of url: URL) throws -> FileIdentity {
        try local.identity(of: canonicalTestPath(mapped(url)))
    }
    func hasNoSymlinkComponents(_ url: URL) throws -> Bool {
        let checked = canonicalTestPath(mapped(url))
        return try local.hasNoSymlinkComponents(checked)
    }

    private func canonicalTestPath(_ url: URL) -> URL {
        guard url.path.hasPrefix("/var/") else { return url }
        return URL(fileURLWithPath: "/private" + url.path)
    }
    func writeAtomically(_ data: Data, to target: URL) throws {
        try local.writeAtomically(data, to: mapped(target))
    }
    func writeExclusively(_ data: Data, to target: URL) throws {
        try local.writeExclusively(data, to: mapped(target))
    }
    func copy(_ source: URL, to destination: URL) throws {
        if raceCopyDestination == destination {
            raceCopyDestination = nil
            try local.writeAtomically(Data("external-artifact".utf8), to: mapped(destination))
        }
        try local.copy(mapped(source), to: mapped(destination))
    }
    func copyExclusively(_ source: URL, to destination: URL) throws {
        if raceCopyDestination == destination {
            raceCopyDestination = nil
            try local.writeAtomically(Data("external-artifact".utf8), to: mapped(destination))
        }
        try local.copyExclusively(mapped(source), to: mapped(destination))
    }
    func replace(_ target: URL, with preparedFile: URL) throws {
        try local.replace(mapped(target), with: mapped(preparedFile))
    }
    func exchange(_ target: URL, with preparedFile: URL) throws {
        let count = lock.withLock { () -> Int in
            exchangeCounts[target, default: 0] += 1
            return exchangeCounts[target]!
        }
        if raceTarget == target, count == 1 {
            try local.writeAtomically(Data("external-race".utf8), to: mapped(target))
        }
        if racePreparedExchangeTarget == target, count == 1 {
            racePreparedExchangeTarget = nil
            try local.writeAtomically(Data("external-artifact".utf8), to: mapped(preparedFile))
        }
        if failRollbackTarget == target, count == 2 {
            throw RecoveryFixtureError.injected
        }
        try local.exchange(mapped(target), with: mapped(preparedFile))
    }
    func installExclusively(_ target: URL, from preparedFile: URL) throws {
        if raceRemoveTarget == preparedFile,
           target.deletingLastPathComponent().lastPathComponent.hasPrefix(".wallume-cleanup-") {
            raceRemoveTarget = nil
            try local.writeAtomically(Data("external-artifact".utf8), to: mapped(preparedFile))
        }
        if raceQuarantineSource == preparedFile {
            raceQuarantineSource = nil
            try local.writeAtomically(Data("external-race".utf8), to: mapped(preparedFile))
        }
        try local.installExclusively(mapped(target), from: mapped(preparedFile))
    }
    func remove(_ url: URL) throws {
        try local.remove(mapped(url))
    }

    func removeDurably(_ url: URL, ifIdentityMatches identity: FileIdentity) throws -> Bool {
        if url.lastPathComponent == replaceCaptureBeforeGuardedRemove,
           url.deletingLastPathComponent().lastPathComponent.hasPrefix(".wallume-cleanup-") {
            replaceCaptureBeforeGuardedRemove = nil
            try local.remove(mapped(url))
            try local.writeAtomically(Data("last-instant-external".utf8), to: mapped(url))
        }
        let removed = try local.removeDurably(
            canonicalTestPath(mapped(url)),
            ifIdentityMatches: identity
        )
        if removed,
           url.deletingLastPathComponent().lastPathComponent.hasPrefix(".wallume-cleanup-"),
           let target = mutateTargetAfterCleanup,
           url.lastPathComponent.contains(target.lastPathComponent) {
            mutateTargetAfterCleanup = nil
            try local.writeAtomically(Data("late-external-target".utf8), to: mapped(target))
        }
        return removed
    }
}

private final class RecoveryTestRefresher: WallpaperRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var remainingFailures = 0
    var onRefresh: (() throws -> Void)?
    var refreshCount: Int { lock.withLock { count } }
    func refresh() throws {
        let shouldFail = lock.withLock { () -> Bool in
            count += 1
            if remainingFailures > 0 {
                remainingFailures -= 1
                return true
            }
            return false
        }
        if shouldFail { throw RecoveryFixtureError.injected }
        try onRefresh?()
    }
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
