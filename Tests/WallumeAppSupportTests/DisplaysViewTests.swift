import AppKit
import SwiftUI
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class DisplaysViewTests: XCTestCase {
    @MainActor
    func testViewRendersConnectedAndDisconnectedDisplayCards() {
        let store = DisplayFeatureStore(commands: .noop)
        let online = DesktopScreen(id: DisplayID("online"), frame: .zero, name: "Built-in", pixelWidth: 3024, pixelHeight: 1964, isMain: true, identityPersistence: .persistent)
        let offline = PersistedDisplayRecord(displayID: DisplayID("offline"), displayName: "Studio", pixelWidth: 5120, pixelHeight: 2880, wasMain: false, identityPersistence: .persistent, mediaID: nil, presentationMode: .fit)
        store.update(
            catalog: DisplayCatalog.merge(connected: [online], remembered: [offline]),
            assignments: .init(records: [offline], userPaused: false),
            media: [], runtime: nil
        )

        let host = NSHostingView(rootView: DisplaysView(store: store))

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertEqual(store.cards.map(\.connection), [.connected, .disconnected])
    }

    func testPresentationModeLabelsCoverAllModes() {
        XCTAssertEqual(WallpaperPresentationMode.fill.displayTitle, "填充")
        XCTAssertEqual(WallpaperPresentationMode.fit.displayTitle, "完整显示")
        XCTAssertEqual(WallpaperPresentationMode.stretch.displayTitle, "拉伸铺满")
    }
}
