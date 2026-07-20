import AppKit
import SwiftUI
import XCTest
@testable import WallumeAppSupport

@MainActor
final class SettingsViewTests: XCTestCase {
    func testPageStateRendersAllPreferenceControlsDirectoriesAndReadyExport() {
        let state = SettingsPageViewState(
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            exportState: .ready
        )

        XCTAssertTrue(state.showsLaunchAtLoginControl)
        XCTAssertTrue(state.showsOpenGalleryAtLaunchControl)
        XCTAssertTrue(state.showsLowPowerPauseControl)
        XCTAssertEqual(state.dataDirectoryPath, "/tmp/Wallume")
        XCTAssertEqual(state.diagnosticsDirectoryPath, "/tmp/Wallume/Diagnostics")
        XCTAssertEqual(state.exportActionTitle, "导出诊断信息")
    }

    func testFailedExportOffersRetryWithoutAccessingNativeSavePanel() {
        let state = SettingsPageViewState(
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            exportState: .failed("Unable to export diagnostics. Please try again.")
        )

        XCTAssertTrue(state.canRetryExport)
        XCTAssertEqual(state.exportErrorMessage, "Unable to export diagnostics. Please try again.")
    }

    func testViewHasNonzeroFittingSizeWithInjectedSideEffectCommands() {
        let store = SettingsStore(defaults: ephemeralDefaults(), loginItem: SettingsViewLoginItem())
        let view = SettingsView(
            store: store,
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            openInFinder: { _ in },
            chooseExportDestination: { nil },
            exportDiagnostics: { _ in }
        )

        XCTAssertGreaterThan(NSHostingView(rootView: view).fittingSize.width, 0)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let name = "SettingsViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

private struct SettingsViewLoginItem: LoginItemControlling {
    func isEnabled() throws -> Bool { false }
    func register() throws {}
    func unregister() throws {}
}
