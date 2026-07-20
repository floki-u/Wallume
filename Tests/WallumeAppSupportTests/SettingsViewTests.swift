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
        XCTAssertTrue(state.canChooseAnotherDestination)
        XCTAssertEqual(state.exportErrorMessage, "Unable to export diagnostics. Please try again.")
    }

    func testChoosingAnotherDestinationAfterFailureReplacesRetryTargetAndSucceeds() async {
        let firstDestination = URL(fileURLWithPath: "/tmp/first-diagnostics.json")
        let secondDestination = URL(fileURLWithPath: "/tmp/second-diagnostics.json")
        var destinations = [firstDestination, secondDestination]
        var chooserCallCount = 0
        var exportedDestinations: [URL] = []
        let controller = SettingsDiagnosticsExportController(
            chooseExportDestination: {
                chooserCallCount += 1
                return destinations.removeFirst()
            },
            exportDiagnostics: { destination in
                exportedDestinations.append(destination)
                if exportedDestinations.count == 1 {
                    throw SettingsViewExportError.expected
                }
            }
        )

        await controller.exportToSelectedDestination()
        XCTAssertEqual(controller.state, .failed(SettingsViewExportError.expected.localizedDescription))

        await controller.chooseAnotherDestination()

        XCTAssertEqual(chooserCallCount, 2)
        XCTAssertEqual(exportedDestinations, [firstDestination, secondDestination])
        XCTAssertEqual(controller.retryDestination, secondDestination)
        XCTAssertEqual(controller.state, .succeeded)
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

private enum SettingsViewExportError: LocalizedError {
    case expected
    var errorDescription: String? { "expected export failure" }
}
