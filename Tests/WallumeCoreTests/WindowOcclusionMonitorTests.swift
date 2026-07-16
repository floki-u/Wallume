import AppKit
import XCTest
@testable import WallumeCore

final class WindowOcclusionMonitorTests: XCTestCase {
    @MainActor
    func testActivationEventReevaluatesOcclusion() {
        let center = NotificationCenter()
        let provider = MutableWindowProvider()
        let display = DesktopScreen(id: DisplayID("one"), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let monitor = WindowOcclusionMonitor(snapshotProvider: provider, workspaceCenter: center, applicationCenter: center, ownPID: 1)
        var values = [Bool]()
        monitor.start(displays: [display]) { values.append($0) }

        provider.value = [WindowSnapshot(ownerPID: 2, layer: 0, alpha: 1, bounds: display.frame, isOnscreen: true)]
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)

        XCTAssertEqual(values.last, true)
    }

    @MainActor
    func testNilSnapshotFailsOpenAndTransitionsAreDeduplicated() {
        let center = NotificationCenter()
        let provider = MutableWindowProvider()
        let display = DesktopScreen(id: DisplayID("one"), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let monitor = WindowOcclusionMonitor(snapshotProvider: provider, workspaceCenter: center, applicationCenter: center, ownPID: 1)
        var values = [Bool]()
        monitor.start(displays: [display]) { values.append($0) }

        provider.value = [WindowSnapshot(ownerPID: 2, layer: 0, alpha: 1, bounds: display.frame, isOnscreen: true)]
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        provider.value = nil
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)

        XCTAssertEqual(values, [false, true, false])
    }

    @MainActor
    func testStopRemovesEventObservers() {
        let center = NotificationCenter()
        let provider = MutableWindowProvider()
        let display = DesktopScreen(id: DisplayID("one"), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let monitor = WindowOcclusionMonitor(snapshotProvider: provider, workspaceCenter: center, applicationCenter: center, ownPID: 1)
        var values = [Bool]()
        monitor.start(displays: [display]) { values.append($0) }
        monitor.stop()
        provider.value = [WindowSnapshot(ownerPID: 2, layer: 0, alpha: 1, bounds: display.frame, isOnscreen: true)]

        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)

        XCTAssertEqual(values, [false])
    }
}

private final class MutableWindowProvider: WindowSnapshotProviding, @unchecked Sendable {
    var value: [WindowSnapshot]? = []
    func snapshots() -> [WindowSnapshot]? { value }
}
