import XCTest
@testable import WallumeCore

final class WindowOcclusionTests: XCTestCase {
    func testAdjacentWindowsTogetherCoverDisplay() {
        let display = DesktopScreen(id: DisplayID("one"), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let windows = [
            WindowSnapshot(ownerPID: 10, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 50, height: 100), isOnscreen: true),
            WindowSnapshot(ownerPID: 11, layer: 0, alpha: 1, bounds: CGRect(x: 50, y: 0, width: 50, height: 100), isOnscreen: true),
        ]
        XCTAssertTrue(WindowOcclusionEvaluator().allDisplaysObscured(displays: [display], windows: windows, ownPID: 1))
    }

    func testOneVisibleDisplayKeepsPlaybackActive() {
        let displays = [
            DesktopScreen(id: DisplayID("one"), frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            DesktopScreen(id: DisplayID("two"), frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
        ]
        let window = WindowSnapshot(ownerPID: 10, layer: 0, alpha: 1, bounds: displays[0].frame, isOnscreen: true)
        XCTAssertFalse(WindowOcclusionEvaluator().allDisplaysObscured(displays: displays, windows: [window], ownPID: 1))
    }
}
