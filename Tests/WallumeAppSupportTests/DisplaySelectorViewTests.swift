import AppKit
import SwiftUI
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class DisplaySelectorViewTests: XCTestCase {
    func testSelectAllAndClearAllControlConfirmationAndSummary() {
        var model = DisplaySelectorModel(targets: [target("one"), target("two")])
        XCTAssertFalse(model.canConfirm)

        model.selectAll()
        XCTAssertEqual(model.selectedIDs, [DisplayID("one"), DisplayID("two")])
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(model.summary, "将应用到 2 台显示器")

        model.clearAll()
        XCTAssertFalse(model.canConfirm)
    }

    func testToggleSelectsIndividualDisplay() {
        var model = DisplaySelectorModel(targets: [target("one")])
        model.toggle(DisplayID("one"))
        XCTAssertEqual(model.selectedIDs, [DisplayID("one")])
        model.toggle(DisplayID("one"))
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }

    @MainActor
    func testSelectorRendersTargets() {
        let host = NSHostingView(rootView: DisplaySelectorView(
            mediaName: "Ocean", targets: [target("one")], currentAssignments: [:],
            onCancel: {}, onConfirm: { _ in }
        ))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}

private func target(_ id: String) -> DisplayRecord {
    DisplayRecord(screen: DesktopScreen(id: DisplayID(id), frame: .zero, name: id, pixelWidth: 1920, pixelHeight: 1080, isMain: id == "one", identityPersistence: .persistent))
}
