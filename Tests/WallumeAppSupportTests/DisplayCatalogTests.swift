import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class DisplayCatalogTests: XCTestCase {
    func testMergeKeepsRememberedDisplayOfflineAndRefreshesConnectedMetadata() {
        let connected = screen("studio", name: "Studio New", main: true, width: 5120)
        let remembered = [
            rememberedRecord("studio", name: "Studio Old", width: 3840),
            rememberedRecord("projector", name: "Projector", width: 1920),
        ]

        let result = DisplayCatalog.merge(connected: [connected], remembered: remembered)

        XCTAssertEqual(result.map(\.id), [connected.id, DisplayID("cg-uuid:projector")])
        XCTAssertEqual(result.map(\.connection), [.connected, .disconnected])
        XCTAssertEqual(result.first?.name, "Studio New")
        XCTAssertEqual(result.first?.pixelWidth, 5120)
    }

    func testConnectedDisplaysSortMainFirstThenName() {
        let result = DisplayCatalog.merge(
            connected: [screen("b", name: "Beta"), screen("a", name: "Alpha"), screen("main", name: "Main", main: true)],
            remembered: []
        )
        XCTAssertEqual(result.map(\.name), ["Main", "Alpha", "Beta"])
    }
}

private func screen(_ id: String, name: String, main: Bool = false, width: Int = 1920) -> DesktopScreen {
    .init(id: DisplayID("cg-uuid:\(id)"), frame: .zero, name: name, pixelWidth: width, pixelHeight: 1080, isMain: main, identityPersistence: .persistent)
}

private func rememberedRecord(_ id: String, name: String, width: Int) -> PersistedDisplayRecord {
    .init(displayID: DisplayID("cg-uuid:\(id)"), displayName: name, pixelWidth: width, pixelHeight: 1080, wasMain: false, identityPersistence: .persistent, mediaID: nil, presentationMode: .fill)
}
