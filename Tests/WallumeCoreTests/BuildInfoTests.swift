import XCTest
@testable import WallumeCore

final class BuildInfoTests: XCTestCase {
    func testStableProductIdentity() {
        XCTAssertEqual(WallumeBuildInfo.productName, "Wallume")
        XCTAssertEqual(WallumeBuildInfo.bundleIdentifier, "app.wallume.Wallume")
    }
}
