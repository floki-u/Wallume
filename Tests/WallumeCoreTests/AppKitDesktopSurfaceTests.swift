import AppKit
import XCTest
@testable import WallumeCore

final class AppKitDesktopSurfaceTests: XCTestCase {
    func testDesktopConfigurationDoesNotActivateOrReceiveMouseEvents() {
        let configuration = AppKitDesktopSurface.Configuration.desktop

        XCTAssertTrue(configuration.ignoresMouseEvents)
        XCTAssertFalse(configuration.activates)
        XCTAssertTrue(configuration.joinsAllSpaces)
    }

    @MainActor
    func testScreenProviderStopsObservingNotifications() async {
        let center = NotificationCenter()
        let provider = AppKitScreenProvider(notificationCenter: center)
        let changed = expectation(description: "screen change")
        provider.start { changed.fulfill() }

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [changed], timeout: 1)

        provider.stop()
        let stopped = expectation(description: "stopped")
        stopped.isInverted = true
        provider.start { stopped.fulfill() }
        provider.stop()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [stopped], timeout: 0.1)
    }
}
