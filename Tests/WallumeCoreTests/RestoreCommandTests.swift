import Foundation
import XCTest
@testable import WallumeCore

final class RestoreCommandTests: XCTestCase {
    func testNoArgumentsPrintsUsageWithoutWriting() {
        let recovery = StubRecoveryService()
        let output = BufferedRestoreOutput()
        let command = RestoreCommand(recovery: recovery, output: output)

        XCTAssertEqual(command.run(arguments: []), 64)

        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(
            output.stderr,
            "usage: wallume-restore status | probe | restore <transaction-uuid> | restore-all\n"
        )
        XCTAssertEqual(recovery.restoredIDs, [])
    }

    func testStatusListsRecoverableTransactionsInOrder() {
        let first = RecoveryCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            phase: .writing,
            aerialID: "AERIAL-ONE",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = RecoveryCandidate(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            phase: .conflicted,
            aerialID: "AERIAL-TWO",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let recovery = StubRecoveryService(candidates: [first, second])
        let output = BufferedRestoreOutput()
        let command = RestoreCommand(recovery: recovery, output: output)

        XCTAssertEqual(command.run(arguments: ["status"]), 0)

        XCTAssertEqual(
            output.stdout,
            """
            00000000-0000-0000-0000-000000000001 writing AERIAL-ONE
            00000000-0000-0000-0000-000000000002 conflicted AERIAL-TWO

            """
        )
        XCTAssertEqual(output.stderr, "")
        XCTAssertEqual(recovery.restoredIDs, [])
    }

    func testRestoreRejectsInvalidUUIDWithoutCallingRecovery() {
        let recovery = StubRecoveryService()
        let output = BufferedRestoreOutput()
        let command = RestoreCommand(recovery: recovery, output: output)

        XCTAssertEqual(command.run(arguments: ["restore", "not-a-uuid"]), 64)

        XCTAssertEqual(recovery.restoredIDs, [])
        XCTAssertEqual(
            output.stderr,
            "usage: wallume-restore status | probe | restore <transaction-uuid> | restore-all\n"
        )
    }

    func testProbePrintsReadOnlyReportWithoutCallingRecovery() {
        let recovery = StubRecoveryService()
        let output = BufferedRestoreOutput()
        let command = RestoreCommand(
            recovery: recovery,
            probe: StubProbeService(report: StubProbeService.fixtureReport),
            output: output
        )

        XCTAssertEqual(command.run(arguments: ["probe"]), 0)

        XCTAssertTrue(output.stdout.contains("generation: tahoe"))
        XCTAssertTrue(output.stdout.contains("writesPermitted: true"))
        XCTAssertTrue(output.stdout.contains("manifestExists: true"))
        XCTAssertTrue(output.stdout.contains("indexExists: false"))
        XCTAssertTrue(output.stdout.contains("slots: AERIAL-ONE"))
        XCTAssertTrue(output.stdout.contains("foreignBackups: AERIAL-ONE.mov.backup"))
        XCTAssertEqual(recovery.restoredIDs, [])
    }

    func testRestoreReturnsConflictExitCodeWhenRecoveryReportsConflicts() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let recovery = StubRecoveryService(reports: [
            id: RecoveryReport(
                restored: [],
                conflicts: [URL(fileURLWithPath: "/conflict")],
                retainedBackups: []
            ),
        ])
        let output = BufferedRestoreOutput()
        let command = RestoreCommand(recovery: recovery, output: output)

        XCTAssertEqual(command.run(arguments: ["restore", id.uuidString]), 2)

        XCTAssertEqual(recovery.restoredIDs, [id])
        XCTAssertEqual(output.stderr, "")
    }

    func testRestoreAllRestoresEveryCandidateAndReturnsConflictExitCodeIfAnyConflictExists() {
        let cleanID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let conflictID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let recovery = StubRecoveryService(
            candidates: [
                RecoveryCandidate(
                    id: cleanID,
                    phase: .writing,
                    aerialID: "AERIAL-ONE",
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                RecoveryCandidate(
                    id: conflictID,
                    phase: .committed,
                    aerialID: "AERIAL-TWO",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ],
            reports: [
                cleanID: RecoveryReport(restored: [], conflicts: [], retainedBackups: []),
                conflictID: RecoveryReport(
                    restored: [],
                    conflicts: [URL(fileURLWithPath: "/conflict")],
                    retainedBackups: []
                ),
            ]
        )
        let output = BufferedRestoreOutput()
        let command = RestoreCommand(recovery: recovery, output: output)

        XCTAssertEqual(command.run(arguments: ["restore-all"]), 2)

        XCTAssertEqual(recovery.restoredIDs, [cleanID, conflictID])
        XCTAssertEqual(output.stderr, "")
    }
}

private final class BufferedRestoreOutput: RestoreOutput {
    private(set) var stdout = ""
    private(set) var stderr = ""

    func writeStdout(_ text: String) {
        stdout += text
    }

    func writeStderr(_ text: String) {
        stderr += text
    }
}

private final class StubRecoveryService: LockScreenRecovering {
    let candidates: [RecoveryCandidate]
    let reports: [UUID: RecoveryReport]
    private(set) var restoredIDs: [UUID] = []

    init(candidates: [RecoveryCandidate] = [], reports: [UUID: RecoveryReport] = [:]) {
        self.candidates = candidates
        self.reports = reports
    }

    func inspect() throws -> [RecoveryCandidate] {
        candidates
    }

    func restore(id: UUID) throws -> RecoveryReport {
        restoredIDs.append(id)
        return reports[id] ?? RecoveryReport(restored: [], conflicts: [], retainedBackups: [])
    }
}

private final class StubProbeService: LockScreenProbing {
    static let fixtureReport = LockScreenProbeReport(
        generation: .tahoe,
        writesPermitted: true,
        manifestExists: true,
        indexExists: false,
        availableSlots: [
            AerialSlot(
                id: "AERIAL-ONE",
                displayName: "Test Coast",
                videoURL: URL(fileURLWithPath: "/videos/AERIAL-ONE.mov")
            ),
        ],
        foreignBackupNames: ["AERIAL-ONE.mov.backup"]
    )

    let report: LockScreenProbeReport

    init(report: LockScreenProbeReport) {
        self.report = report
    }

    func inspect() throws -> LockScreenProbeReport {
        report
    }
}
