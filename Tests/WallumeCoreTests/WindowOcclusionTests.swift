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

    func testIneligibleWindowsNeverObscureDisplay() {
        let display = DesktopScreen(id: DisplayID("one"), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let windows = [
            WindowSnapshot(ownerPID: 1, layer: 0, alpha: 1, bounds: display.frame, isOnscreen: true),
            WindowSnapshot(ownerPID: 2, layer: 1, alpha: 1, bounds: display.frame, isOnscreen: true),
            WindowSnapshot(ownerPID: 3, layer: 0, alpha: 0, bounds: display.frame, isOnscreen: true),
            WindowSnapshot(ownerPID: 4, layer: 0, alpha: 1, bounds: display.frame, isOnscreen: false),
        ]

        XCTAssertFalse(WindowOcclusionEvaluator().allDisplaysObscured(displays: [display], windows: windows, ownPID: 1))
    }

    func testQuartzCoordinatesUsePrimaryDisplayTopForVerticalLayouts() throws {
        let abovePrimary = makeEntry(bounds: CGRect(x: 0, y: -100, width: 100, height: 100))
        let belowPrimary = makeEntry(bounds: CGRect(x: 0, y: 100, width: 100, height: 100))

        let snapshots = try XCTUnwrap(CGWindowSnapshotProvider.normalizedSnapshots(
            from: [abovePrimary, belowPrimary],
            primaryDisplayTop: 100
        ))

        XCTAssertEqual(snapshots.map(\.bounds.origin.y), [100, -100])
    }

    func testIncompleteQuartzEntryFailsOpen() {
        var incomplete = makeEntry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        incomplete.removeValue(forKey: kCGWindowAlpha as String)

        XCTAssertNil(CGWindowSnapshotProvider.normalizedSnapshots(
            from: [incomplete],
            primaryDisplayTop: 100
        ))
    }

    private func makeEntry(bounds: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: 2),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowBounds as String: [
                "X": NSNumber(value: Double(bounds.minX)),
                "Y": NSNumber(value: Double(bounds.minY)),
                "Width": NSNumber(value: Double(bounds.width)),
                "Height": NSNumber(value: Double(bounds.height)),
            ] as NSDictionary,
        ]
    }
}
