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

    @MainActor
    func testThermalNotificationPausesOnlyForSeriousAndCriticalStates() {
        let processCenter = NotificationCenter()
        let thermal = MutableThermalState(.nominal)
        let monitor = RuntimeEnvironmentMonitor(
            sessionCenter: NotificationCenter(),
            workspaceCenter: NotificationCenter(),
            processCenter: processCenter,
            powerState: FixedPowerState(isLowPowerModeEnabled: false),
            thermalState: thermal,
            observesDistributedSession: false
        )
        var environments = [RuntimeEnvironment]()
        monitor.start { environments.append($0) }

        thermal.value = .serious
        processCenter.post(name: RuntimeEnvironmentMonitor.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(environments.last?.pauseReasons, [.thermalPressure])

        thermal.value = .fair
        processCenter.post(name: RuntimeEnvironmentMonitor.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(environments.last?.pauseReasons, [])
    }

    @MainActor
    func testLowPowerPolicyImmediatelyRemovesAndRestoresReasonWhileHardwareStateRemainsEnabled() {
        let monitor = RuntimeEnvironmentMonitor(
            sessionCenter: NotificationCenter(),
            workspaceCenter: NotificationCenter(),
            processCenter: NotificationCenter(),
            powerState: FixedPowerState(isLowPowerModeEnabled: true),
            observesDistributedSession: false
        )
        var environments = [RuntimeEnvironment]()
        monitor.start { environments.append($0) }

        XCTAssertEqual(environments.last?.pauseReasons, [.lowPower])

        monitor.setLowPowerPauseEnabled(false)
        XCTAssertEqual(environments.last?.pauseReasons, [])

        monitor.setLowPowerPauseEnabled(true)
        XCTAssertEqual(environments.last?.pauseReasons, [.lowPower])
    }
}

private struct FixedPowerState: PowerStateProviding {
    let isLowPowerModeEnabled: Bool
}

private final class MutableThermalState: ThermalStateProviding, @unchecked Sendable {
    var value: ProcessInfo.ThermalState
    init(_ value: ProcessInfo.ThermalState) { self.value = value }
    var thermalState: ProcessInfo.ThermalState { value }
}
