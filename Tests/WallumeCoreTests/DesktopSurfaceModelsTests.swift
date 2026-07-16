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
}
