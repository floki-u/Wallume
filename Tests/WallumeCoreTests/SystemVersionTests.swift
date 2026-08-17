import XCTest
@testable import WallumeCore

final class SystemVersionTests: XCTestCase {
    func testSupportedMajorVersionsAreExplicit() {
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 14, minorVersion: 7, patchVersion: 0)), .sonoma)
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 15, minorVersion: 6, patchVersion: 0)), .sequoia)
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 26, minorVersion: 5, patchVersion: 2)), .tahoe)
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 13, minorVersion: 7, patchVersion: 0)), .unsupported(13))
        XCTAssertEqual(MacOSGeneration(version: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)), .unsupported(27))
    }

    func testOnlySupportedGenerationsPermitWrites() {
        XCTAssertTrue(MacOSGeneration.sonoma.permitsWrites)
        XCTAssertTrue(MacOSGeneration.sequoia.permitsWrites)
        XCTAssertFalse(MacOSGeneration.tahoe.permitsWrites)
        XCTAssertFalse(MacOSGeneration.unsupported(13).permitsWrites)
    }
}
