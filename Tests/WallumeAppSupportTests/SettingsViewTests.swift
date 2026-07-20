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

        XCTAssertEqual(
            state.preferenceControls.map(\.id),
            [
                .launchAtLogin,
                .openGalleryAtLaunch,
                .pauseInLowPowerMode,
            ]
        )
        XCTAssertEqual(
            state.preferenceControls.map(\.title),
            [
                "登录时启动 Wallume",
                "启动时打开图库",
                "低电量模式时暂停播放",
            ]
        )
        XCTAssertEqual(state.dataDirectoryPath, "/tmp/Wallume")
        XCTAssertEqual(state.diagnosticsDirectoryPath, "/tmp/Wallume/Diagnostics")
        XCTAssertEqual(
            state.diagnosticsActions,
            [.init(id: .selectDestination, title: "导出诊断信息", isEnabled: true)]
        )
    }

    func testFailedExportOffersRetryWithoutAccessingNativeSavePanel() {
        let state = SettingsPageViewState(
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            exportState: .failed("Unable to export diagnostics. Please try again.")
        )

        XCTAssertEqual(
            state.diagnosticsActions,
            [
                .init(id: .retry, title: "重试导出", isEnabled: true),
                .init(id: .chooseAnotherDestination, title: "选择其他位置", isEnabled: true),
            ]
        )
        XCTAssertEqual(state.exportErrorMessage, "Unable to export diagnostics. Please try again.")
    }

    func testFailedExportCanRetryTheSameDestinationWithoutOpeningChooserAgain() async {
        let destination = URL(fileURLWithPath: "/tmp/diagnostics.json")
        var chooserCallCount = 0
        var exportedDestinations: [URL] = []
        let controller = SettingsDiagnosticsExportController(
            chooseExportDestination: {
                chooserCallCount += 1
                return destination
            },
            exportDiagnostics: { selectedDestination in
                exportedDestinations.append(selectedDestination)
                if exportedDestinations.count == 1 {
                    throw SettingsViewExportError.expected
                }
            }
        )

        await controller.exportToSelectedDestination()
        XCTAssertEqual(controller.state, .failed(SettingsViewExportError.expected.localizedDescription))

        await controller.retry()

        XCTAssertEqual(chooserCallCount, 1)
        XCTAssertEqual(exportedDestinations, [destination, destination])
        XCTAssertEqual(controller.retryDestination, destination)
        XCTAssertEqual(controller.state, .succeeded)
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

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertEqual(subviewCount(in: host, typeNameContaining: "Checkbox"), 3)
    }

    func testRenderedFailureSurfaceContainsRetryAndChooseAnotherDestinationActions() async {
        let controller = SettingsDiagnosticsExportController(
            chooseExportDestination: { URL(fileURLWithPath: "/tmp/diagnostics.json") },
            exportDiagnostics: { _ in throw SettingsViewExportError.expected }
        )
        await controller.exportToSelectedDestination()
        let store = SettingsStore(defaults: ephemeralDefaults(), loginItem: SettingsViewLoginItem())
        let view = SettingsView(
            store: store,
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            openInFinder: { _ in },
            chooseExportDestination: { nil },
            exportDiagnostics: { _ in },
            exportController: controller
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let failedActionSurfaceCount = subviewCount(in: host, typeNameContaining: "_FocusRingView")

        let readyController = SettingsDiagnosticsExportController(
            chooseExportDestination: { nil },
            exportDiagnostics: { _ in }
        )
        let readyView = SettingsView(
            store: store,
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            openInFinder: { _ in },
            chooseExportDestination: { nil },
            exportDiagnostics: { _ in },
            exportController: readyController
        )
        let readyHost = NSHostingView(rootView: readyView)
        readyHost.frame = NSRect(origin: .zero, size: readyHost.fittingSize)
        readyHost.layoutSubtreeIfNeeded()
        let readyActionSurfaceCount = subviewCount(in: readyHost, typeNameContaining: "_FocusRingView")

        XCTAssertEqual(failedActionSurfaceCount, readyActionSurfaceCount + 1)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let name = "SettingsViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

@MainActor
private func subviewCount(in view: NSView, typeNameContaining fragment: String) -> Int {
    let ownCount = String(describing: type(of: view)).contains(fragment) ? 1 : 0
    return ownCount + view.subviews.reduce(0) {
        $0 + subviewCount(in: $1, typeNameContaining: fragment)
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
