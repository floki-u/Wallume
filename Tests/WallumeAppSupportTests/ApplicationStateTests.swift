import XCTest
@testable import WallumeAppSupport

final class ApplicationStateTests: XCTestCase {
    func testFirstLaunchOpensWindowAndLaterDefaultDoesNot() {
        XCTAssertTrue(ApplicationState(hasLaunchedBefore: false, openGalleryAtLaunch: false).shouldOpenWindowAtLaunch)
        XCTAssertFalse(ApplicationState(hasLaunchedBefore: true, openGalleryAtLaunch: false).shouldOpenWindowAtLaunch)
        XCTAssertTrue(ApplicationState(hasLaunchedBefore: true, openGalleryAtLaunch: true).shouldOpenWindowAtLaunch)
    }

    func testCompletionNotificationOnlyWhenWindowHiddenOrApplicationInactive() {
        XCTAssertFalse(ApplicationState.shouldNotifyOnCompletion(windowVisible: true, applicationActive: true))
        XCTAssertTrue(ApplicationState.shouldNotifyOnCompletion(windowVisible: false, applicationActive: true))
        XCTAssertTrue(ApplicationState.shouldNotifyOnCompletion(windowVisible: true, applicationActive: false))
    }
}
