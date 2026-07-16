import Foundation
import XCTest
@testable import WallumeCore

final class RuntimeEnvironmentMonitorTests: XCTestCase {
    @MainActor
    func testUnlockDoesNotResumeWhileSystemStillSleeps() {
        let sessionCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let processCenter = NotificationCenter()
        let monitor = RuntimeEnvironmentMonitor(
            sessionCenter: sessionCenter,
            workspaceCenter: workspaceCenter,
            processCenter: processCenter,
            powerState: FixedPowerState(isLowPowerModeEnabled: false),
            observesDistributedSession: false
        )
        var environments = [RuntimeEnvironment]()
        monitor.start { environments.append($0) }

        sessionCenter.post(name: RuntimeEnvironmentMonitor.sessionLockedNotification, object: nil)
        workspaceCenter.post(name: RuntimeEnvironmentMonitor.systemWillSleepNotification, object: nil)
        sessionCenter.post(name: RuntimeEnvironmentMonitor.sessionUnlockedNotification, object: nil)

        XCTAssertEqual(environments.last?.pauseReasons, [.systemSleep])
    }
}

private struct FixedPowerState: PowerStateProviding {
    let isLowPowerModeEnabled: Bool
}
