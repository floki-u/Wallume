import XCTest
@testable import WallumeAppSupport

final class ApplicationShellViewTests: XCTestCase {
    func testRegistryHasStableFeatureOrderAndDisplaysEnabled() {
        XCTAssertEqual(FeatureRegistry.features.map(\.id), [.gallery, .displays, .lockScreen, .performance, .settings])
        XCTAssertEqual(FeatureRegistry.features.filter(\.isEnabled).map(\.id), [.gallery, .displays])
    }
}
