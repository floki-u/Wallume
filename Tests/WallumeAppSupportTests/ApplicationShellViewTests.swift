import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class ApplicationShellViewTests: XCTestCase {
    func testRegistryHasStableFeatureOrderAndOnlyCompletedFeaturesEnabled() {
        XCTAssertEqual(FeatureRegistry.features.map(\.id), [.gallery, .displays, .lockScreen, .performance, .settings])
        XCTAssertEqual(FeatureRegistry.features.filter(\.isEnabled).map(\.id), [.gallery, .displays, .lockScreen])
        XCTAssertFalse(FeatureRegistry.features.first { $0.id == .performance }?.isEnabled ?? true)
        XCTAssertFalse(FeatureRegistry.features.first { $0.id == .settings }?.isEnabled ?? true)
    }

    func testLockScreenRouteRequiresFeatureStore() {
        XCTAssertEqual(
            ApplicationShellRoute.resolve(
                selection: .lockScreen,
                hasDisplayStore: true,
                hasLockScreenStore: true
            ),
            .lockScreen
        )
        XCTAssertEqual(
            ApplicationShellRoute.resolve(
                selection: .lockScreen,
                hasDisplayStore: true,
                hasLockScreenStore: false
            ),
            .unavailable
        )
    }

    func testNavigationCanOpenDisplaysFromStatusMenu() {
        let navigation = ApplicationNavigation()
        navigation.open(.displays)
        XCTAssertEqual(navigation.selection, .displays)
    }

    func testReplacingWallpaperCarriesOriginatingDisplayIntoGallery() {
        let navigation = ApplicationNavigation(selection: .displays)
        let displayID = DisplayID("cg-uuid:studio")

        navigation.openGalleryForWallpaper(displayID: displayID)

        XCTAssertEqual(navigation.selection, .gallery)
        XCTAssertEqual(navigation.preferredAssignmentDisplayID, displayID)
        navigation.clearWallpaperTarget()
        XCTAssertNil(navigation.preferredAssignmentDisplayID)
    }

    @MainActor
    func testPlaybackToolbarModelExplainsSystemPauseWithoutOfferingResume() {
        let state = PlaybackToolbarState(userPaused: false, pauseReasons: [.thermalPressure])
        XCTAssertEqual(state.statusText, "已因系统状态暂停")
        XCTAssertEqual(state.actionTitle, "暂停播放")

        let userPaused = PlaybackToolbarState(userPaused: true, pauseReasons: [.user, .thermalPressure])
        XCTAssertEqual(userPaused.actionTitle, "继续播放")
    }
}
