import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class LockScreenSyncServiceTests: XCTestCase {
    private let aerialID = "com.apple.aerials.sea"

    func testStartPerformsReadOnlyProbeWithoutSelectingDefaultSlot() async throws {
        let fixture = try await LockScreenSyncFixture.make()
        defer { fixture.cleanup() }

        await fixture.service.start()
        await fixture.service.waitForIdle()

        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .readyToConfigure)
        XCTAssertNil(state.selectedAerialID)
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        XCTAssertFalse(fixture.files.exists(fixture.configurationURL))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testExplicitSelectionAndConfirmationEnableFirstInstall() async throws {
        let fixture = try await LockScreenSyncFixture.make()
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.waitForIdle()
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let selectedState = await fixture.service.snapshot()
        XCTAssertEqual(selectedState.selectedAerialID, aerialID)

        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .install(mediaID: media.id, aerialID: aerialID)]
        )
        let configuration = try await fixture.reloadedConfiguration()
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.selectedAerialID, aerialID)
        XCTAssertEqual(configuration.activeTransactionID, fixture.installedTransactionID)
        XCTAssertEqual(configuration.lastSyncedMediaID, media.id)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .synced)
        XCTAssertEqual(state.lastSyncedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSameMediaIsDeduplicatedAgainstConfiguredCommittedTransaction() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .synced)
        XCTAssertEqual(state.activeTransactionID, fixture.existingTransactionID)
        XCTAssertEqual(state.syncedMedia?.id, media.id)
    }

    func testUnavailableMainWallpaperConditionsWaitWithoutRestoreOrInstall() async throws {
        for condition in LockScreenSyncFixture.WaitingCondition.allCases {
            let fixture = try await LockScreenSyncFixture.make(
                configuration: .enabled(
                    aerialID: aerialID,
                    transactionID: LockScreenSyncFixture.existingTransactionID,
                    mediaID: LockScreenSyncFixture.firstMediaID
                ),
                recoveryResults: [.success([.candidate(
                    id: LockScreenSyncFixture.existingTransactionID,
                    phase: .committed,
                    aerialID: aerialID
                )])]
            )
            defer { fixture.cleanup() }
            await fixture.service.apply(input: try fixture.waitingInput(condition))

            await fixture.service.start()
            await fixture.service.waitForIdle()

            let state = await fixture.service.snapshot()
            XCTAssertEqual(state.phase, .waitingForMainWallpaper, "\(condition)")
            XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery], "\(condition)")
            XCTAssertEqual(state.activeTransactionID, fixture.existingTransactionID)
        }
    }

    func testMediaSwitchRestoresBeforeInstallingAndOnlyThenPersistsReplacement() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))

        await fixture.service.start()
        await fixture.service.waitForIdle()
        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .restore(transactionID: fixture.existingTransactionID),
                .install(mediaID: replacement.id, aerialID: aerialID),
            ]
        )
        let configuration = try await fixture.reloadedConfiguration()
        XCTAssertEqual(configuration.activeTransactionID, fixture.installedTransactionID)
        XCTAssertEqual(configuration.lastSyncedMediaID, replacement.id)
    }

    func testFailedInstallRetainsEnabledIntentAndPublishesRetryableError() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            installResults: [.failure(.expected)]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)

        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()

        let configuration = try await fixture.reloadedConfiguration()
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.selectedAerialID, aerialID)
        XCTAssertNil(configuration.activeTransactionID)
        XCTAssertEqual(configuration.lastResult, .failed)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertNotNil(state.lastError)
        XCTAssertTrue(state.capabilities.canRetry)
    }

    func testConfiguredCommittedTransactionIsRetainedDuringStartupAlignment() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.activeTransactionID, fixture.existingTransactionID)
    }

    func testConfiguredIncompleteTransactionsRestoreBeforeReevaluation() async throws {
        for phase in [TransactionPhase.prepared, .writing, .restoring] {
            let fixture = try await LockScreenSyncFixture.make(
                configuration: .enabled(
                    aerialID: aerialID,
                    transactionID: LockScreenSyncFixture.existingTransactionID,
                    mediaID: LockScreenSyncFixture.firstMediaID
                ),
                recoveryResults: [.success([.candidate(
                    id: LockScreenSyncFixture.existingTransactionID,
                    phase: phase,
                    aerialID: aerialID
                )])]
            )
            defer { fixture.cleanup() }
            let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
            await fixture.service.apply(input: fixture.input(media: replacement))

            await fixture.service.start()
            await fixture.service.waitForIdle()

            XCTAssertEqual(
                fixture.client.calls,
                [
                    .probe,
                    .inspectRecovery,
                    .restore(transactionID: fixture.existingTransactionID),
                    .install(mediaID: replacement.id, aerialID: aerialID),
                ],
                "\(phase)"
            )
        }
    }

    func testConfiguredRestoredTransactionResumesCleanupBeforeResynchronizing() async throws {
        let transactionID = LockScreenSyncFixture.existingTransactionID
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: transactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: transactionID,
                phase: .restored,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .restore(transactionID: transactionID),
                .install(mediaID: replacement.id, aerialID: aerialID),
            ]
        )
    }

    func testConfiguredConflictBlocksWrites() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .conflicted,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertTrue(state.capabilities.canDisableAndRestore)
        XCTAssertFalse(state.capabilities.canSelectAerialSlot)
        XCTAssertFalse(state.capabilities.canConfirmEnable)
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
    }

    func testUnsupportedConfiguredConflictAllowsSafeExplicitRecovery() async throws {
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let candidate = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            probeResult: .success(LockScreenSyncFixture.probe(writesPermitted: false)),
            recoveryResults: [.success([candidate])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .inspectRecovery,
                .restore(transactionID: fixture.existingTransactionID),
            ]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, .disabled)
        let state = await fixture.service.snapshot()
        XCTAssertFalse(state.capabilities.canDisableAndRestore)
        XCTAssertEqual(state.phase, .unsupported)
    }

    func testForeignBackupConfiguredConflictCannotExplicitlyRecover() async throws {
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let candidate = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            probeResult: .success(LockScreenSyncFixture.probe(
                foreignBackupNames: ["foreign.backup"]
            )),
            recoveryResults: [.success([candidate])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertFalse(state.capabilities.canDisableAndRestore)
    }

    func testProbeFailureConfiguredTransactionCannotExplicitlyRecover() async throws {
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let candidate = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            probeResult: .failure(.expected),
            recoveryResults: [.success([candidate])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe])
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertFalse(state.capabilities.canDisableAndRestore)
    }

    func testConflictedExplicitDisableFreshlyInspectsAndRetainsRepairWhenConflictPersists() async throws {
        let conflict = RecoveryReport(
            restored: [],
            conflicts: [URL(string: "https://example.test/conflict")!],
            retainedBackups: [URL(string: "https://example.test/backup")!]
        )
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let candidate = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([candidate]), .success([candidate])],
            restoreResults: [.success(conflict)]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .inspectRecovery,
                .restore(transactionID: fixture.existingTransactionID),
            ]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testConflictedExplicitDisableSucceedsAfterExternalConflictResolution() async throws {
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let candidate = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([candidate]), .success([candidate])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .inspectRecovery,
                .restore(transactionID: fixture.existingTransactionID),
            ]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, .disabled)
    }

    func testConflictedExplicitDisableRejectsFreshIncompleteCandidate() async throws {
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let initial = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let incomplete = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .writing,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([initial]), .success([incomplete])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery, .inspectRecovery])
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertFalse(state.capabilities.canDisableAndRestore)
    }

    func testConflictedExplicitDisableRejectsFreshOrphanCandidate() async throws {
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let initial = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let orphan = RecoveryCandidate.candidate(
            id: fixtureID(44),
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([initial]), .success([orphan])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery, .inspectRecovery])
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertFalse(state.capabilities.canDisableAndRestore)
    }

    func testConflictedAlignmentBlocksAutomaticInstallUntilExplicitRecoverySucceeds() async throws {
        let candidate = RecoveryCandidate.candidate(
            id: LockScreenSyncFixture.existingTransactionID,
            phase: .conflicted,
            aerialID: aerialID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([candidate]), .success([candidate])]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.apply(input: fixture.input(media: replacement))
        await fixture.service.waitForIdle()
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()
        await fixture.service.apply(input: fixture.input(media: replacement))
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .inspectRecovery,
                .restore(transactionID: fixture.existingTransactionID),
            ]
        )
        XCTAssertFalse(fixture.client.calls.contains {
            if case .install = $0 { return true }
            return false
        })
    }

    func testProbeFailureDurablyBlocksLaterInputAndConfirmation() async throws {
        let fixture = try await LockScreenSyncFixture.make(probeResult: .failure(.expected))
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")

        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe])
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testMalformedConfigurationRemainsTerminalAfterValidReplacementAndRetry() async throws {
        let fixture = try await LockScreenSyncFixture.make()
        defer { fixture.cleanup() }
        try fixture.files.writeAtomically(Data("not json".utf8), to: fixture.configurationURL)
        await fixture.service.start()
        await fixture.service.waitForIdle()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let replacement = try encoder.encode(LockScreenConfiguration.disabled)
        try fixture.files.writeAtomically(replacement, to: fixture.configurationURL)
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.retry()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [])
        XCTAssertEqual(try fixture.files.read(fixture.configurationURL), replacement)
        XCTAssertFalse(fixture.client.calls.contains {
            if case .install = $0 { return true }
            return false
        })
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testRetryDoesNotAdoptValidExternalConfigurationReplacementAfterInitialLoad() async throws {
        let fixture = try await LockScreenSyncFixture.make()
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()
        let external = LockScreenConfiguration(isEnabled: true, selectedAerialID: aerialID)
        try AtomicJSONStore(files: fixture.files).write(external, to: fixture.configurationURL)
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.retry()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery, .probe, .inspectRecovery])
        XCTAssertFalse(fixture.client.calls.contains { if case .install = $0 { return true }; return false })
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .readyToConfigure)
    }

    func testInstallPreflightRejectsExternalConfigurationChangesBeforeSystemInstall() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let replacements = [
            Data("not json".utf8),
            try encoder.encode(LockScreenConfiguration(isEnabled: true, selectedAerialID: "external-slot")),
        ]

        for replacement in replacements {
            let fixture = try await LockScreenSyncFixture.make(configuration: .enabled(aerialID: aerialID))
            defer { fixture.cleanup() }
            await fixture.service.start()
            await fixture.service.waitForIdle()
            let waitingState = await fixture.service.snapshot()
            XCTAssertEqual(waitingState.phase, .waitingForMainWallpaper)

            try fixture.files.writeAtomically(replacement, to: fixture.configurationURL)
            let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
            await fixture.service.apply(input: fixture.input(media: media))
            await fixture.service.waitForIdle()

            XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
            let state = await fixture.service.snapshot()
            XCTAssertEqual(state.phase, .needsRepair)
        }
    }

    func testMultipleRecoveryCandidatesBlockAllWrites() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(aerialID: aerialID),
            recoveryResults: [.success([
                .candidate(id: fixtureID(1), phase: .committed, aerialID: aerialID),
                .candidate(id: fixtureID(2), phase: .prepared, aerialID: aerialID),
            ])]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
    }

    func testAmbiguousRecoveryAlsoBlocksDisableFromClearingEnabledIntent() async throws {
        let original = LockScreenConfiguration.enabled(aerialID: aerialID)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([
                .candidate(id: fixtureID(20), phase: .committed, aerialID: aerialID),
                .candidate(id: fixtureID(21), phase: .committed, aerialID: aerialID),
            ])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertFalse(state.capabilities.canDisableAndRestore)
    }

    func testUniqueMatchingCommittedOrphanRestoresBeforeResync() async throws {
        let orphanID = fixtureID(3)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(aerialID: aerialID),
            recoveryResults: [.success([.candidate(id: orphanID, phase: .committed, aerialID: aerialID)])]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .restore(transactionID: orphanID),
                .install(mediaID: media.id, aerialID: aerialID),
            ]
        )
    }

    func testUnsupportedProbeRestoresMatchingCommittedOrphanButBlocksNewInstall() async throws {
        let transactionID = fixtureID(40)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(aerialID: aerialID),
            probeResult: .success(LockScreenSyncFixture.probe(writesPermitted: false)),
            recoveryResults: [.success([.candidate(
                id: transactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .restore(transactionID: transactionID)]
        )
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .unsupported)
    }

    func testUnsupportedProbeRecoversConfiguredIncompleteTransactionBeforeBlockingInstall() async throws {
        for phase in [TransactionPhase.prepared, .writing, .restoring] {
            let transactionID = fixtureID(45)
            let original = LockScreenConfiguration.enabled(
                aerialID: aerialID,
                transactionID: transactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            )
            let fixture = try await LockScreenSyncFixture.make(
                configuration: original,
                probeResult: .success(LockScreenSyncFixture.probe(writesPermitted: false)),
                recoveryResults: [.success([.candidate(
                    id: transactionID,
                    phase: phase,
                    aerialID: aerialID
                )])]
            )
            defer { fixture.cleanup() }
            let media = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
            await fixture.service.apply(input: fixture.input(media: media))

            await fixture.service.start()
            await fixture.service.waitForIdle()

            XCTAssertEqual(
                fixture.client.calls,
                [.probe, .inspectRecovery, .restore(transactionID: transactionID)],
                "\(phase)"
            )
            XCTAssertFalse(fixture.client.calls.contains {
                if case .install = $0 { return true }
                return false
            }, "\(phase)")
            let persisted = try await fixture.reloadedConfiguration()
            XCTAssertNil(persisted.activeTransactionID, "\(phase)")
            let state = await fixture.service.snapshot()
            XCTAssertEqual(state.phase, .unsupported, "\(phase)")
        }
    }

    func testUnsupportedProbeAllowsExplicitRestoreAndDisableOfCommittedTransaction() async throws {
        let transactionID = fixtureID(46)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: transactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            probeResult: .success(LockScreenSyncFixture.probe(writesPermitted: false)),
            recoveryResults: [.success([.candidate(
                id: transactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        let unsupported = await fixture.service.snapshot()
        XCTAssertTrue(unsupported.capabilities.canDisableAndRestore)
        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .restore(transactionID: transactionID)]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, .disabled)
    }

    func testForeignBackupBlocksRecoveryWritesEvenWithMatchingOrphan() async throws {
        let transactionID = fixtureID(41)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(aerialID: aerialID),
            probeResult: .success(LockScreenSyncFixture.probe(
                foreignBackupNames: ["foreign.backup"]
            )),
            recoveryResults: [.success([.candidate(
                id: transactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testStartupRetainedBackupDoesNotClearTransactionOrInstall() async throws {
        let retained = RecoveryReport(
            restored: [],
            conflicts: [],
            retainedBackups: [URL(string: "https://example.test/retained")!]
        )
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .writing,
                aerialID: aerialID
            )])],
            restoreResults: [.success(retained)]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .restore(transactionID: fixture.existingTransactionID)]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testOtherUniqueOrphansRequireRepairWithoutWrites() async throws {
        let cases: [(TransactionPhase, String)] = [
            (.committed, "a-different-slot"),
            (.prepared, aerialID),
            (.writing, aerialID),
            (.restoring, aerialID),
            (.conflicted, aerialID),
        ]
        for (phase, candidateAerialID) in cases {
            let fixture = try await LockScreenSyncFixture.make(
                configuration: .enabled(aerialID: aerialID),
                recoveryResults: [.success([.candidate(
                    id: fixtureID(4), phase: phase, aerialID: candidateAerialID
                )])]
            )
            defer { fixture.cleanup() }
            let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
            await fixture.service.apply(input: fixture.input(media: media))

            await fixture.service.start()
            await fixture.service.waitForIdle()

            let state = await fixture.service.snapshot()
            XCTAssertEqual(state.phase, .needsRepair, "\(phase)")
            XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery], "\(phase)")
        }
    }

    func testConflictDuringMediaSwitchRetainsOldConfigurationAndBlocksInstall() async throws {
        let report = RecoveryReport(
            restored: [],
            conflicts: [URL(string: "https://example.test/conflict")!],
            retainedBackups: [URL(string: "https://example.test/backup")!]
        )
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreResults: [.success(report)]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))

        await fixture.service.start()
        await fixture.service.waitForIdle()
        let third = try fixture.makeAvailableMedia(id: fixtureID(43), name: "Third")
        await fixture.service.apply(input: fixture.input(media: third))
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .restore(transactionID: fixture.existingTransactionID)]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testRetainedBackupDuringMediaSwitchBlocksInstallAndLaterInputs() async throws {
        let retained = RecoveryReport(
            restored: [],
            conflicts: [],
            retainedBackups: [URL(string: "https://example.test/retained")!]
        )
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreResults: [.success(retained)]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))
        await fixture.service.start()
        await fixture.service.waitForIdle()

        let third = try fixture.makeAvailableMedia(id: fixtureID(42), name: "Third")
        await fixture.service.apply(input: fixture.input(media: third))
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .restore(transactionID: fixture.existingTransactionID)]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
    }

    func testDisableClearsConfigurationOnlyAfterConflictFreeRestore() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, .disabled)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .readyToConfigure)
        XCTAssertEqual(fixture.client.calls.last, .restore(transactionID: fixture.existingTransactionID))
    }

    func testDisableConflictRetainsEnabledIntentAndActiveTransaction() async throws {
        let conflict = RecoveryReport(
            restored: [],
            conflicts: [URL(string: "https://example.test/conflict")!],
            retainedBackups: [URL(string: "https://example.test/backup")!]
        )
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreResults: [.success(conflict)]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
        XCTAssertEqual(state.activeTransactionID, fixture.existingTransactionID)
    }

    func testDisableRetainedBackupKeepsEnabledIntentAndActiveTransaction() async throws {
        let retained = RecoveryReport(
            restored: [],
            conflicts: [],
            retainedBackups: [URL(string: "https://example.test/retained")!]
        )
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreResults: [.success(retained)]
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.waitForIdle()

        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, original)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testRetryRepeatsProbeAndRecoveryBeforeRetryingFailedInstall() async throws {
        let fixture = try await LockScreenSyncFixture.make(
            installResults: [
                .failure(.expected),
                .success(makeManifest(id: LockScreenSyncFixture.installedTransactionID)),
            ],
            recoveryResults: [.success([]), .success([])]
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()
        let failedState = await fixture.service.snapshot()
        XCTAssertEqual(failedState.phase, .needsRepair)

        await fixture.service.retry()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .install(mediaID: media.id, aerialID: aerialID),
                .probe,
                .inspectRecovery,
                .install(mediaID: media.id, aerialID: aerialID),
            ]
        )
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .synced)
    }

    func testInstallFailureBlocksNewInputUntilExplicitRetry() async throws {
        let fixture = try await LockScreenSyncFixture.make(installResults: [.failure(.expected)])
        defer { fixture.cleanup() }
        let first = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: first))
        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()

        let second = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: second))
        await fixture.service.refreshProbe()
        await fixture.service.confirmEnable()
        await fixture.service.disableAndRestore()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .install(mediaID: first.id, aerialID: aerialID),
                .probe,
            ]
        )
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testDuplicateConfirmAfterSuccessfulEnableIsIdempotent() async throws {
        let fixture = try await LockScreenSyncFixture.make()
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))
        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()
        let callsAfterFirstConfirm = fixture.client.calls

        await fixture.service.confirmEnable()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, callsAfterFirstConfirm)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .synced)
    }

    func testInputsAreAcceptedAndCoalescedToLatestWhileInstallIsInFlight() async throws {
        let gate = BlockingClientGate()
        let firstTransactionID = fixtureID(10)
        let fixture = try await LockScreenSyncFixture.make(
            installResults: [
                .success(makeManifest(id: firstTransactionID)),
                .success(makeManifest(id: LockScreenSyncFixture.installedTransactionID)),
            ],
            installGate: gate
        )
        defer { fixture.cleanup() }
        let first = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        let intermediate = try fixture.makeAvailableMedia(id: fixtureID(11), name: "Intermediate")
        let latest = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Latest")
        let intermediateInput = fixture.input(media: intermediate)
        let latestInput = fixture.input(media: latest)
        let service = fixture.service
        await fixture.service.apply(input: fixture.input(media: first))
        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 2))

        let intermediateAccepted = expectation(description: "intermediate input accepted during install")
        Task {
            await service.apply(input: intermediateInput)
            intermediateAccepted.fulfill()
        }
        await fulfillment(of: [intermediateAccepted], timeout: 1)
        let latestAccepted = expectation(description: "latest input accepted during install")
        Task {
            await service.apply(input: latestInput)
            latestAccepted.fulfill()
        }
        await fulfillment(of: [latestAccepted], timeout: 1)
        gate.release()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .install(mediaID: first.id, aerialID: aerialID),
                .restore(transactionID: firstTransactionID),
                .install(mediaID: latest.id, aerialID: aerialID),
            ]
        )
    }

    func testInputChangeDuringRestoreInstallsOnlyLatestMediaAtSafeEndpoint() async throws {
        let gate = BlockingClientGate()
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: LockScreenSyncFixture.existingTransactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreGate: gate
        )
        defer { fixture.cleanup() }
        let intermediate = try fixture.makeAvailableMedia(id: fixtureID(30), name: "Intermediate")
        let latest = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Latest")
        await fixture.service.apply(input: fixture.input(media: intermediate))
        await fixture.service.start()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 2))

        let accepted = expectation(description: "latest input accepted during restore")
        let service = fixture.service
        let latestInput = fixture.input(media: latest)
        Task {
            await service.apply(input: latestInput)
            accepted.fulfill()
        }
        await fulfillment(of: [accepted], timeout: 1)
        gate.release()
        await fixture.service.waitForIdle()

        XCTAssertEqual(
            fixture.client.calls,
            [
                .probe,
                .inspectRecovery,
                .restore(transactionID: fixture.existingTransactionID),
                .install(mediaID: latest.id, aerialID: aerialID),
            ]
        )
    }

    func testMediaSwitchPersistsRestoreMarkerBeforeTouchingSystemFiles() async throws {
        let gate = BlockingClientGate()
        let original = LockScreenConfiguration.enabled(
            aerialID: aerialID,
            transactionID: LockScreenSyncFixture.existingTransactionID,
            mediaID: LockScreenSyncFixture.firstMediaID
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: original,
            recoveryResults: [.success([.candidate(
                id: LockScreenSyncFixture.existingTransactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreGate: gate
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))
        await fixture.service.start()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 2))

        let persistedDuringRestore = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persistedDuringRestore.activeTransactionID, fixture.existingTransactionID)
        XCTAssertEqual(persistedDuringRestore.lastResult, LockScreenConfigurationResult.restoring)

        gate.release()
        await fixture.service.waitForIdle()
    }

    func testRestartWithRestoreMarkerAndMissingReferencedJournalFailsClosed() async throws {
        let staleReference = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: aerialID,
            activeTransactionID: LockScreenSyncFixture.existingTransactionID,
            lastSyncedMediaID: LockScreenSyncFixture.firstMediaID,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastResult: .restoring
        )
        let fixture = try await LockScreenSyncFixture.make(
            configuration: staleReference,
            recoveryResults: [.success([])]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        XCTAssertFalse(fixture.client.calls.contains { if case .install = $0 { return true }; return false })
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, staleReference)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testRestartWithRestoreMarkerAndUnrelatedJournalFailsClosed() async throws {
        let transactionID = LockScreenSyncFixture.existingTransactionID
        let staleReference = LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: aerialID,
            activeTransactionID: transactionID,
            lastSyncedMediaID: LockScreenSyncFixture.firstMediaID,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastResult: .restoring
        )
        let unrelatedID = fixtureID(88)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: staleReference,
            recoveryResults: [.success([.candidate(
                id: unrelatedID,
                phase: .committed,
                aerialID: aerialID
            )])]
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted, staleReference)
        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .needsRepair)
    }

    func testStopAfterIdleRejectsLaterCommands() async throws {
        let fixture = try await LockScreenSyncFixture.make()
        defer { fixture.cleanup() }
        await fixture.service.start()
        await fixture.service.stopAcceptingNewCommandsAndWait()
        let callsAtStop = fixture.client.calls

        await fixture.service.refreshProbe()
        await fixture.service.retry()
        await fixture.service.apply(input: .empty)
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.client.calls, callsAtStop)
    }

    func testStopWaitsForInProgressOperationButDropsQueuedSystemActions() async throws {
        let gate = BlockingClientGate()
        let firstTransactionID = fixtureID(47)
        let fixture = try await LockScreenSyncFixture.make(
            installResults: [.success(makeManifest(id: firstTransactionID))],
            installGate: gate
        )
        defer { fixture.cleanup() }
        let first = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Replacement")
        await fixture.service.apply(input: fixture.input(media: first))
        await fixture.service.start()
        await fixture.service.selectAerialSlot(aerialID)
        await fixture.service.confirmEnable()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 2))

        await fixture.service.apply(input: fixture.input(media: replacement))
        let queuedRestore = await fixture.service.disableAndRestore()
        XCTAssertNotNil(queuedRestore)
        let service = fixture.service
        let stopped = expectation(description: "termination waits for safe endpoint")
        Task {
            await service.stopAcceptingNewCommandsAndWait()
            stopped.fulfill()
        }
        var admissionClosed = false
        for _ in 0..<100 where !admissionClosed {
            admissionClosed = await fixture.service.refreshProbe() == nil
            if !admissionClosed { await Task.yield() }
        }
        XCTAssertTrue(admissionClosed)

        gate.release()
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .install(mediaID: first.id, aerialID: aerialID)]
        )
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertEqual(persisted.activeTransactionID, firstTransactionID)
        XCTAssertEqual(persisted.lastSyncedMediaID, first.id)
    }

    func testTerminationDuringStartupProbePreventsSubsequentRecoveryMutation() async throws {
        let gate = BlockingClientGate()
        let transactionID = LockScreenSyncFixture.existingTransactionID
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: transactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: transactionID,
                phase: .writing,
                aerialID: aerialID
            )])],
            probeGate: gate
        )
        defer { fixture.cleanup() }
        await fixture.service.start()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 2))

        let service = fixture.service
        let stopped = expectation(description: "termination finishes after probe")
        Task { await service.stopAcceptingNewCommandsAndWait(); stopped.fulfill() }
        var admissionClosed = false
        for _ in 0..<100 where !admissionClosed {
            admissionClosed = await fixture.service.retry() == nil
            if !admissionClosed { await Task.yield() }
        }
        XCTAssertTrue(admissionClosed)
        gate.release()
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertEqual(fixture.client.calls, [.probe])
    }

    func testTerminationAfterMediaSwitchRestorePreventsReplacementInstall() async throws {
        let gate = BlockingClientGate()
        let transactionID = LockScreenSyncFixture.existingTransactionID
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(
                aerialID: aerialID,
                transactionID: transactionID,
                mediaID: LockScreenSyncFixture.firstMediaID
            ),
            recoveryResults: [.success([.candidate(
                id: transactionID,
                phase: .committed,
                aerialID: aerialID
            )])],
            restoreGate: gate
        )
        defer { fixture.cleanup() }
        let replacement = try fixture.makeAvailableMedia(id: fixture.secondMediaID, name: "Second")
        await fixture.service.apply(input: fixture.input(media: replacement))
        await fixture.service.start()
        XCTAssertTrue(gate.waitUntilEntered(timeout: 2))

        let service = fixture.service
        let stopped = expectation(description: "termination waits for restore")
        Task { await service.stopAcceptingNewCommandsAndWait(); stopped.fulfill() }
        var admissionClosed = false
        for _ in 0..<100 where !admissionClosed {
            admissionClosed = await fixture.service.retry() == nil
            if !admissionClosed { await Task.yield() }
        }
        XCTAssertTrue(admissionClosed)
        gate.release()
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertEqual(
            fixture.client.calls,
            [.probe, .inspectRecovery, .restore(transactionID: transactionID)]
        )
        XCTAssertFalse(fixture.client.calls.contains { if case .install = $0 { return true }; return false })
        let persisted = try await fixture.reloadedConfiguration()
        XCTAssertTrue(persisted.isEnabled)
        XCTAssertEqual(persisted.selectedAerialID, aerialID)
        XCTAssertNil(persisted.activeTransactionID)
        XCTAssertNil(persisted.lastSyncedMediaID)
        XCTAssertNil(persisted.lastSyncedAt)
        XCTAssertEqual(persisted.lastResult, .waiting)
    }

    func testUnsupportedProbeStillInspectsRecoveryButBlocksInstall() async throws {
        let probe = LockScreenSyncFixture.probe(writesPermitted: false)
        let fixture = try await LockScreenSyncFixture.make(
            configuration: .enabled(aerialID: aerialID),
            probeResult: .success(probe)
        )
        defer { fixture.cleanup() }
        let media = try fixture.makeAvailableMedia(id: fixture.firstMediaID, name: "First")
        await fixture.service.apply(input: fixture.input(media: media))

        await fixture.service.start()
        await fixture.service.waitForIdle()

        let state = await fixture.service.snapshot()
        XCTAssertEqual(state.phase, .unsupported)
        XCTAssertEqual(fixture.client.calls, [.probe, .inspectRecovery])
    }

    func testFakeSystemClientRecordsCallsWithoutFilesystemPathsOrProcessExecution() throws {
        let probe = LockScreenProbeReport(
            generation: .sequoia,
            writesPermitted: true,
            manifestExists: true,
            indexExists: true,
            availableSlots: [],
            foreignBackupNames: []
        )
        let manifest = makeManifest()
        let candidate = RecoveryCandidate(
            id: manifest.id,
            phase: .committed,
            aerialID: manifest.aerialID,
            createdAt: manifest.createdAt
        )
        let report = RecoveryReport(
            restored: [URL(string: "https://example.test/restored")!],
            conflicts: [],
            retainedBackups: []
        )
        let media = makeMedia()
        let client = FakeLockScreenSystemClient(
            probeResult: .success(probe),
            installResult: .success(manifest),
            recoveryResult: .success([candidate]),
            restoreResult: .success(report)
        )

        XCTAssertEqual(try client.probe(), probe)
        XCTAssertEqual(try client.install(media: media, aerialID: "com.apple.aerials.sea"), manifest)
        XCTAssertEqual(try client.inspectRecovery(), [candidate])
        XCTAssertEqual(try client.restore(transactionID: manifest.id), report)
        XCTAssertEqual(
            client.calls,
            [
                .probe,
                .install(mediaID: media.id, aerialID: "com.apple.aerials.sea"),
                .inspectRecovery,
                .restore(transactionID: manifest.id),
            ]
        )
    }

    func testFakeSystemClientCanThrowAtEveryClientOperation() {
        let media = makeMedia()
        let transactionID = UUID()
        let error = FakeClientError.expected
        let client = FakeLockScreenSystemClient(
            probeResult: .failure(error),
            installResult: .failure(error),
            recoveryResult: .failure(error),
            restoreResult: .failure(error)
        )

        assertThrowsExpectedError { _ = try client.probe() }
        assertThrowsExpectedError { _ = try client.install(media: media, aerialID: "com.apple.aerials.sea") }
        assertThrowsExpectedError { _ = try client.inspectRecovery() }
        assertThrowsExpectedError { _ = try client.restore(transactionID: transactionID) }
    }

    func testProductionClientMapsMediaVariantAndCoverToTransactionRequest() {
        let media = makeMedia()
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 1)

        let request = ProcessLockScreenSystemClient.transactionRequest(
            media: media,
            aerialID: "com.apple.aerials.sea",
            systemVersion: version
        )

        XCTAssertEqual(request.systemVersion.majorVersion, version.majorVersion)
        XCTAssertEqual(request.systemVersion.minorVersion, version.minorVersion)
        XCTAssertEqual(request.systemVersion.patchVersion, version.patchVersion)
        XCTAssertEqual(request.aerialID, "com.apple.aerials.sea")
        XCTAssertEqual(request.optimizedVideo, media.variantURL)
        XCTAssertEqual(request.poster, media.coverURL)
    }

    func testGeneratedUIDProviderParsesDSCLOutputWithoutRunningProcess() throws {
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let provider = ProcessGeneratedUIDProvider { homeDirectory in
            XCTAssertEqual(homeDirectory, URL(fileURLWithPath: "/Users/test", isDirectory: true))
            return "GeneratedUID: USER-UUID\nPrimaryGroupID: 20\n"
        }

        let generatedUID = try provider.generatedUID(for: homeDirectory)

        XCTAssertEqual(generatedUID, "USER-UUID")
    }

    func testGeneratedUIDProviderSurfacesTypedPathCommandAndParseFailures() {
        let malformedProvider = ProcessGeneratedUIDProvider { _ in "PrimaryGroupID: 20\n" }
        let commandFailureProvider = ProcessGeneratedUIDProvider { _ in throw FakeClientError.expected }
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertThrowsError(try malformedProvider.generatedUID(for: homeDirectory)) { error in
            XCTAssertEqual(error as? GeneratedUIDProviderError, .malformedOutput)
        }
        XCTAssertThrowsError(try commandFailureProvider.generatedUID(for: homeDirectory)) { error in
            XCTAssertEqual(error as? GeneratedUIDProviderError, .commandFailed)
        }
        XCTAssertThrowsError(try malformedProvider.generatedUID(for: URL(string: "https://example.test/home")!)) { error in
            XCTAssertEqual(
                error as? GeneratedUIDProviderError,
                .invalidHomeDirectory(URL(string: "https://example.test/home")!)
            )
        }
    }

    func testProductionClientSurfacesGeneratedUIDFailureBeforeInstall() {
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let client = ProcessLockScreenSystemClient(
            homeDirectory: homeDirectory,
            generatedUIDProvider: ThrowingGeneratedUIDProvider(),
            systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertThrowsError(try client.install(media: makeMedia(), aerialID: "com.apple.aerials.sea")) { error in
            XCTAssertEqual(error as? LockScreenSystemClientError, .generatedUID(.commandFailed))
        }
    }

    func testProductionClientSkipsGeneratedUIDLookupWhenNoRecoveryTransactionsExist() throws {
        let provider = RecordingGeneratedUIDProvider()
        let homeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let client = ProcessLockScreenSystemClient(
            homeDirectory: homeDirectory,
            generatedUIDProvider: provider,
            systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertEqual(try client.inspectRecovery(), [])
        XCTAssertEqual(provider.callCount, 0)
    }

    private func assertThrowsExpectedError(_ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? FakeClientError, .expected)
        }
    }
}

private final class FakeLockScreenSystemClient: LockScreenSystemClient, @unchecked Sendable {
    enum Call: Equatable {
        case probe
        case install(mediaID: UUID, aerialID: String)
        case inspectRecovery
        case restore(transactionID: UUID)
    }

    private var probeResults: [Result<LockScreenProbeReport, FakeClientError>]
    private var installResults: [Result<LockScreenTransactionManifest, FakeClientError>]
    private var recoveryResults: [Result<[RecoveryCandidate], FakeClientError>]
    private var restoreResults: [Result<RecoveryReport, FakeClientError>]
    private let lock = NSLock()
    private let installGate: BlockingClientGate?
    private let restoreGate: BlockingClientGate?
    private let probeGate: BlockingClientGate?
    private var recordedCalls: [Call] = []
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    init(
        probeResult: Result<LockScreenProbeReport, FakeClientError>,
        installResult: Result<LockScreenTransactionManifest, FakeClientError>,
        recoveryResult: Result<[RecoveryCandidate], FakeClientError>,
        restoreResult: Result<RecoveryReport, FakeClientError>
    ) {
        probeResults = [probeResult]
        installResults = [installResult]
        recoveryResults = [recoveryResult]
        restoreResults = [restoreResult]
        installGate = nil
        restoreGate = nil
        probeGate = nil
    }

    init(
        probeResults: [Result<LockScreenProbeReport, FakeClientError>],
        installResults: [Result<LockScreenTransactionManifest, FakeClientError>],
        recoveryResults: [Result<[RecoveryCandidate], FakeClientError>],
        restoreResults: [Result<RecoveryReport, FakeClientError>],
        probeGate: BlockingClientGate? = nil,
        installGate: BlockingClientGate? = nil,
        restoreGate: BlockingClientGate? = nil
    ) {
        self.probeResults = probeResults
        self.installResults = installResults
        self.recoveryResults = recoveryResults
        self.restoreResults = restoreResults
        self.probeGate = probeGate
        self.installGate = installGate
        self.restoreGate = restoreGate
    }

    func probe() throws -> LockScreenProbeReport {
        lock.lock()
        recordedCalls.append(.probe)
        let result = next(&probeResults)
        lock.unlock()
        probeGate?.enterAndWaitOnce()
        return try result.get()
    }

    func install(media: MediaItem, aerialID: String) throws -> LockScreenTransactionManifest {
        lock.lock()
        recordedCalls.append(.install(mediaID: media.id, aerialID: aerialID))
        lock.unlock()
        installGate?.enterAndWaitOnce()
        lock.lock()
        let result = next(&installResults)
        lock.unlock()
        return try result.get()
    }

    func inspectRecovery() throws -> [RecoveryCandidate] {
        lock.lock()
        recordedCalls.append(.inspectRecovery)
        let result = next(&recoveryResults)
        lock.unlock()
        return try result.get()
    }

    func restore(transactionID: UUID) throws -> RecoveryReport {
        lock.lock()
        recordedCalls.append(.restore(transactionID: transactionID))
        lock.unlock()
        restoreGate?.enterAndWaitOnce()
        lock.lock()
        let result = next(&restoreResults)
        lock.unlock()
        return try result.get()
    }

    private func next<T>(_ results: inout [Result<T, FakeClientError>]) -> Result<T, FakeClientError> {
        precondition(!results.isEmpty, "Missing fake result")
        if results.count == 1 { return results[0] }
        return results.removeFirst()
    }
}

private final class BlockingClientGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var hasBlocked = false

    func enterAndWaitOnce() {
        condition.lock()
        defer { condition.unlock() }
        guard !hasBlocked else { return }
        hasBlocked = true
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
    }

    func waitUntilEntered(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered, condition.wait(until: deadline) {}
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LockScreenSyncFixture {
    static let existingTransactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let installedTransactionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let firstMediaID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let secondMediaID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    enum WaitingCondition: CaseIterable {
        case noMainAssignment
        case offlineMainDisplay
        case missingLibraryItem
        case missingVariant
        case missingCover
    }

    let root: URL
    let configurationURL: URL
    let files: LocalFileStore
    let client: FakeLockScreenSystemClient
    let service: LockScreenSyncService
    var existingTransactionID: UUID { Self.existingTransactionID }
    var installedTransactionID: UUID { Self.installedTransactionID }
    var firstMediaID: UUID { Self.firstMediaID }
    var secondMediaID: UUID { Self.secondMediaID }

    private init(
        root: URL,
        configurationURL: URL,
        files: LocalFileStore,
        client: FakeLockScreenSystemClient,
        service: LockScreenSyncService
    ) {
        self.root = root
        self.configurationURL = configurationURL
        self.files = files
        self.client = client
        self.service = service
    }

    static func make(
        configuration: LockScreenConfiguration = .disabled,
        probeResult: Result<LockScreenProbeReport, FakeClientError> = .success(probe()),
        installResults: [Result<LockScreenTransactionManifest, FakeClientError>] = [
            .success(makeManifest(id: installedTransactionID))
        ],
        recoveryResults: [Result<[RecoveryCandidate], FakeClientError>] = [.success([])],
        restoreResults: [Result<RecoveryReport, FakeClientError>] = [.success(.conflictFree)],
        probeGate: BlockingClientGate? = nil,
        installGate: BlockingClientGate? = nil,
        restoreGate: BlockingClientGate? = nil
    ) async throws -> LockScreenSyncFixture {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private" + temporaryPath : temporaryPath
        let root = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configurationURL = root.appending(path: "lock-screen-configuration.json")
        let files = LocalFileStore()
        if configuration != .disabled {
            let writer = LockScreenConfigurationStore(
                url: configurationURL,
                files: files,
                jsonStore: AtomicJSONStore(files: files)
            )
            _ = try await writer.load()
            try await writer.update(configuration)
        }
        let store = LockScreenConfigurationStore(
            url: configurationURL,
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        let client = FakeLockScreenSystemClient(
            probeResults: [probeResult],
            installResults: installResults,
            recoveryResults: recoveryResults,
            restoreResults: restoreResults,
            probeGate: probeGate,
            installGate: installGate,
            restoreGate: restoreGate
        )
        return LockScreenSyncFixture(
            root: root,
            configurationURL: configurationURL,
            files: files,
            client: client,
            service: LockScreenSyncService(
                configurationStore: store,
                systemClient: client,
                files: files,
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        )
    }

    static func probe(
        writesPermitted: Bool = true,
        foreignBackupNames: [String] = []
    ) -> LockScreenProbeReport {
        LockScreenProbeReport(
            generation: writesPermitted ? .sequoia : .unsupported(99),
            writesPermitted: writesPermitted,
            manifestExists: true,
            indexExists: true,
            availableSlots: [AerialSlot(
                id: "com.apple.aerials.sea",
                displayName: "Sea",
                videoURL: URL(string: "https://example.test/aerial.mov")!
            )],
            foreignBackupNames: foreignBackupNames
        )
    }

    func makeAvailableMedia(id: UUID, name: String) throws -> MediaItem {
        let mediaDirectory = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        let variant = mediaDirectory.appending(path: "variant.mov")
        let cover = mediaDirectory.appending(path: "cover.jpg")
        try files.writeAtomically(Data("variant".utf8), to: variant)
        try files.writeAtomically(Data("cover".utf8), to: cover)
        return makeMedia(id: id, name: name, variantURL: variant, coverURL: cover)
    }

    func input(media: MediaItem) -> LockScreenSyncInput {
        let screen = Self.mainScreen(id: DisplayID("main"))
        let record = Self.record(displayID: screen.id, mediaID: media.id)
        return LockScreenSyncInput(
            assignments: DisplayAssignmentSnapshot(records: [record], userPaused: false),
            screens: [screen],
            mediaByID: [media.id: media]
        )
    }

    func waitingInput(_ condition: WaitingCondition) throws -> LockScreenSyncInput {
        let main = Self.mainScreen(id: DisplayID("main"))
        switch condition {
        case .noMainAssignment:
            return LockScreenSyncInput(assignments: .empty, screens: [main], mediaByID: [:])
        case .offlineMainDisplay:
            let offlineRecord = Self.record(displayID: DisplayID("offline"), mediaID: firstMediaID)
            return LockScreenSyncInput(
                assignments: DisplayAssignmentSnapshot(records: [offlineRecord], userPaused: false),
                screens: [main],
                mediaByID: [:]
            )
        case .missingLibraryItem:
            let record = Self.record(displayID: main.id, mediaID: firstMediaID)
            return LockScreenSyncInput(
                assignments: DisplayAssignmentSnapshot(records: [record], userPaused: false),
                screens: [main],
                mediaByID: [:]
            )
        case .missingVariant:
            let media = try makeAvailableMedia(id: firstMediaID, name: "Missing variant")
            try files.remove(media.variantURL)
            return input(media: media)
        case .missingCover:
            let media = try makeAvailableMedia(id: firstMediaID, name: "Missing cover")
            try files.remove(media.coverURL)
            return input(media: media)
        }
    }

    func reloadedConfiguration() async throws -> LockScreenConfiguration {
        let store = LockScreenConfigurationStore(
            url: configurationURL,
            files: files,
            jsonStore: AtomicJSONStore(files: files)
        )
        return try await store.load()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func mainScreen(id: DisplayID) -> DesktopScreen {
        DesktopScreen(
            id: id,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            name: "Main",
            pixelWidth: 1920,
            pixelHeight: 1080,
            isMain: true,
            identityPersistence: .persistent
        )
    }

    private static func record(displayID: DisplayID, mediaID: UUID) -> PersistedDisplayRecord {
        PersistedDisplayRecord(
            displayID: displayID,
            displayName: "Main",
            pixelWidth: 1920,
            pixelHeight: 1080,
            wasMain: true,
            identityPersistence: .persistent,
            mediaID: mediaID,
            presentationMode: .fill
        )
    }
}

private struct ThrowingGeneratedUIDProvider: GeneratedUIDProviding {
    func generatedUID(for homeDirectory: URL) throws -> String {
        throw GeneratedUIDProviderError.commandFailed
    }
}

private final class RecordingGeneratedUIDProvider: GeneratedUIDProviding, @unchecked Sendable {
    private(set) var callCount = 0

    func generatedUID(for homeDirectory: URL) throws -> String {
        callCount += 1
        return "USER-UUID"
    }
}

private enum FakeClientError: Error, Equatable {
    case expected
}

private func makeMedia() -> MediaItem {
    MediaItem(
        id: UUID(uuidString: "3B3F872A-79E0-4BB7-9F3B-9E91794728CF")!,
        sourceHash: "source-hash",
        sourceURL: URL(string: "https://example.test/source")!,
        displayName: "Example",
        sourceByteCount: 1,
        pixelWidth: 1,
        pixelHeight: 1,
        frameRate: 30,
        durationSeconds: 1,
        codec: "h264",
        variantURL: URL(string: "https://example.test/variant")!,
        thumbnailURL: URL(string: "https://example.test/thumbnail")!,
        coverURL: URL(string: "https://example.test/cover")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeMedia(id: UUID, name: String, variantURL: URL, coverURL: URL) -> MediaItem {
    MediaItem(
        id: id,
        sourceHash: "source-\(id.uuidString)",
        sourceURL: variantURL,
        displayName: name,
        sourceByteCount: 1,
        pixelWidth: 1920,
        pixelHeight: 1080,
        frameRate: 30,
        durationSeconds: 1,
        codec: "hevc",
        variantURL: variantURL,
        thumbnailURL: coverURL,
        coverURL: coverURL,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeManifest(
    id: UUID = UUID(uuidString: "22F12AB3-7C94-44B7-91CD-62B1ED4A4E51")!,
    aerialID: String = "com.apple.aerials.sea"
) -> LockScreenTransactionManifest {
    LockScreenTransactionManifest(
        schemaVersion: 2,
        id: id,
        phase: .committed,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        osMajorVersion: 15,
        aerialID: aerialID,
        video: FileReplacementRecord(
            target: URL(string: "https://example.test/video")!,
            originalHash: "original-video",
            installedHash: "installed-video",
            originalBackup: URL(string: "https://example.test/video.backup")!
        ),
        poster: FileReplacementRecord(
            target: URL(string: "https://example.test/poster")!,
            originalHash: "original-poster",
            installedHash: "installed-poster",
            originalBackup: URL(string: "https://example.test/poster.backup")!
        ),
        indexURL: URL(string: "https://example.test/index")!,
        indexMutations: [],
        primaryBackup: URL(string: "https://example.test/primary.backup")!,
        recoveryBackup: URL(string: "https://example.test/recovery.backup")!
    )
}

private func fixtureID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}

private extension LockScreenConfiguration {
    static func enabled(
        aerialID: String,
        transactionID: UUID? = nil,
        mediaID: UUID? = nil
    ) -> LockScreenConfiguration {
        LockScreenConfiguration(
            isEnabled: true,
            selectedAerialID: aerialID,
            activeTransactionID: transactionID,
            lastSyncedMediaID: mediaID,
            lastSyncedAt: mediaID.map { _ in Date(timeIntervalSince1970: 1_700_000_000) },
            lastResult: mediaID == nil ? nil : .synced
        )
    }
}

private extension RecoveryCandidate {
    static func candidate(
        id: UUID,
        phase: TransactionPhase,
        aerialID: String
    ) -> RecoveryCandidate {
        RecoveryCandidate(
            id: id,
            phase: phase,
            aerialID: aerialID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private extension RecoveryReport {
    static let conflictFree = RecoveryReport(restored: [], conflicts: [], retainedBackups: [])
}
