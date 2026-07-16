import AppKit
import AVFoundation
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
    func testSurfaceUsesIndependentAspectFillLayerForSharedPlayer() {
        let registry = AVPlayerPresentationRegistry()
        let resourceID = UUID()
        registry.register(AVPlayer(), resourceID: resourceID)
        let first = AppKitDesktopSurface(registry: registry)
        let second = AppKitDesktopSurface(registry: registry)
        let presentation = PlaybackPresentation(resourceID: resourceID)

        first.setPresentation(presentation, fallbackURL: nil)
        second.setPresentation(presentation, fallbackURL: nil)

        XCTAssertEqual(first.videoGravity, .resizeAspectFill)
        XCTAssertEqual(second.videoGravity, .resizeAspectFill)
        XCTAssertNotEqual(first.presentationLayerIdentity, second.presentationLayerIdentity)
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
