import Foundation
import XCTest
@testable import WallumeWallpaperPOC
@testable import WallumeWallpaperProviderPOC

final class WallpaperProviderExperimentTests: XCTestCase {
    func testProviderExperimentIsHardDisabled() {
        XCTAssertFalse(WallpaperProviderExperimentSafety.acceptsConnections)
        XCTAssertEqual(WallpaperProviderExperimentSafety.prohibitedCapabilities, [
            "AppExtension entry point",
            "ExtensionKit registration",
            "WallpaperAgent XPC connection",
            "remote CAContext creation",
            "wallpaper-store access",
        ])
    }

    func testProviderExperimentUsesTheReviewedProtocolSurface() {
        XCTAssertEqual(
            WallpaperProviderExperimentSafety.declaredHostToProviderSelectors,
            WallpaperExtensionProtocolSurface.hostToProviderSelectors
        )
        XCTAssertEqual(
            WallpaperProviderExperimentSafety.declaredProviderToHostSelectors,
            WallpaperExtensionProtocolSurface.providerToHostSelectors
        )
    }

    @MainActor
    func testConfigurationRejectsAnIncomingConnection() {
        let configuration = WallpaperProviderExperimentConfiguration()
        let connection = NSXPCConnection(machServiceName: "com.wallume.poc.noop", options: [])

        XCTAssertFalse(configuration.accept(connection: connection))
    }
}
