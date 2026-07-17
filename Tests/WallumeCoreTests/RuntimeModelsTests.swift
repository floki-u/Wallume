import Foundation
import XCTest
@testable import WallumeCore

final class RuntimeModelsTests: XCTestCase {
    func testEnvironmentCollectsEveryActivePauseReason() {
        let environment = RuntimeEnvironment(
            userPaused: true,
            appObscured: false,
            screenLocked: true,
            lowPowerMode: true,
            systemSleeping: false,
            thermalPressure: true
        )

        XCTAssertEqual(environment.pauseReasons, [.user, .screenLocked, .lowPower, .thermalPressure])
    }

    func testSnapshotSortsSessionsByDisplayID() {
        let snapshot = RuntimeSnapshot(
            sessions: [
                .init(displayID: DisplayID("B"), mediaID: UUID(), resourceID: UUID()),
                .init(displayID: DisplayID("A"), mediaID: UUID(), resourceID: UUID()),
            ],
            resourceReferenceCounts: [:],
            pauseReasons: [],
            failures: [],
            resourceCreationCount: 0
        )

        XCTAssertEqual(snapshot.sessions.map(\.displayID), [DisplayID("A"), DisplayID("B")])
    }
}
