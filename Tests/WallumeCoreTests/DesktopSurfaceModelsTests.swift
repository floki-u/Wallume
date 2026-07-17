import CoreGraphics
import XCTest
@testable import WallumeCore

final class DesktopSurfaceModelsTests: XCTestCase {
    func testDesktopScreenUsesStableIDAndFrame() {
        let screen = DesktopScreen(
            id: DisplayID("screen-1"),
            frame: .init(x: 10, y: 20, width: 1920, height: 1080)
        )

        XCTAssertEqual(screen.id, DisplayID("screen-1"))
        XCTAssertEqual(screen.frame.width, 1920)
    }

    func testDesktopScreenCarriesPersistentDisplayMetadata() {
        let screen = DesktopScreen(
            id: DisplayID("cg-uuid:studio"),
            frame: .zero,
            name: "Studio Display",
            pixelWidth: 5120,
            pixelHeight: 2880,
            isMain: true,
            identityPersistence: .persistent
        )

        XCTAssertEqual(screen.name, "Studio Display")
        XCTAssertEqual(screen.pixelWidth, 5120)
        XCTAssertEqual(screen.pixelHeight, 2880)
        XCTAssertTrue(screen.isMain)
        XCTAssertEqual(screen.identityPersistence, .persistent)
    }

    func testFallbackIdentityIsNamespacedAndConnectionOnly() {
        let identity = DisplayIdentity.fallback(directDisplayID: 42)

        XCTAssertEqual(identity.id, DisplayID("cg-direct:42"))
        XCTAssertEqual(identity.persistence, .connectionOnly)
    }

    func testUUIDIdentityIsNormalizedAndPersistent() {
        let identity = DisplayIdentity.uuid("AABBCCDD-0000-1111-2222-334455667788")

        XCTAssertEqual(identity.id, DisplayID("cg-uuid:aabbccdd-0000-1111-2222-334455667788"))
        XCTAssertEqual(identity.persistence, .persistent)
    }
}
