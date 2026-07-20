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
            state.preferenceControls,
            [
                .init(id: "settings.preference.launchAtLogin", title: "登录时启动 Wallume", role: .toggle, isEnabled: true, action: .setPreference(.launchAtLogin)),
                .init(id: "settings.preference.openGalleryAtLaunch", title: "启动时打开图库", role: .toggle, isEnabled: true, action: .setPreference(.openGalleryAtLaunch)),
                .init(id: "settings.preference.pauseInLowPowerMode", title: "低电量模式时暂停播放", role: .toggle, isEnabled: true, action: .setPreference(.pauseInLowPowerMode)),
            ]
        )
        XCTAssertEqual(state.dataDirectoryPath, "/tmp/Wallume")
        XCTAssertEqual(state.diagnosticsDirectoryPath, "/tmp/Wallume/Diagnostics")
        XCTAssertEqual(
            state.diagnosticsControls,
            [.init(id: "settings.diagnostics.selectDestination", title: "导出诊断信息", role: .button, isEnabled: true, action: .diagnostics(.selectDestination))]
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
            state.diagnosticsControls,
            [
                .init(id: "settings.diagnostics.retry", title: "重试导出", role: .button, isEnabled: true, action: .diagnostics(.retry)),
                .init(id: "settings.diagnostics.chooseAnotherDestination", title: "选择其他位置", role: .button, isEnabled: true, action: .diagnostics(.chooseAnotherDestination)),
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

    func testDurabilityUncertainExportSuppressesSameDestinationRetryUntilAnotherDestinationIsChosen() async {
        let original = URL(fileURLWithPath: "/tmp/original-diagnostics.json")
        let replacement = URL(fileURLWithPath: "/tmp/replacement-diagnostics.json")
        var destinations = [original, replacement]
        var exported: [URL] = []
        var contents = [original: Data("old".utf8)]
        let controller = SettingsDiagnosticsExportController(
            chooseExportDestination: { destinations.removeFirst() },
            exportDiagnostics: { destination in
                exported.append(destination)
                contents[destination] = Data("new".utf8)
                if destination == original {
                    throw DiagnosticsExportUserError.destinationMayContainExport
                }
            }
        )

        await controller.exportToSelectedDestination()

        XCTAssertEqual(
            controller.state,
            .destinationMayContainExport(DiagnosticsExportUserError.destinationMayContainExport.localizedDescription)
        )
        await controller.retry()
        XCTAssertEqual(exported, [original])
        XCTAssertEqual(contents[original], Data("new".utf8))
        let uncertainPage = SettingsPageViewState(
            buildInfo: .unavailable,
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            exportState: controller.state
        )
        XCTAssertEqual(
            uncertainPage.diagnosticsControls.map(\.action),
            [.diagnostics(.chooseAnotherDestination)]
        )

        await controller.chooseAnotherDestination()

        XCTAssertEqual(exported, [original, replacement])
        XCTAssertEqual(controller.state, .succeeded)
    }

    func testReadyPagePresentationDescribesActualControlRolesAndActions() {
        let state = SettingsPageViewState(
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            exportState: .ready
        )

        XCTAssertEqual(state.preferenceControls.map(\.role), [.toggle, .toggle, .toggle])
        XCTAssertEqual(
            state.preferenceControls.map(\.action),
            [.setPreference(.launchAtLogin), .setPreference(.openGalleryAtLaunch), .setPreference(.pauseInLowPowerMode)]
        )
        XCTAssertEqual(state.diagnosticsControls.map(\.role), [.button])
        XCTAssertEqual(state.diagnosticsControls.map(\.action), [.diagnostics(.selectDestination)])
    }

    func testFailedPagePresentationExposesTwoEnabledButtonActions() {
        let state = SettingsPageViewState(
            buildInfo: .init(productVersion: "1.2.3", buildNumber: "45"),
            dataDirectory: URL(fileURLWithPath: "/tmp/Wallume"),
            diagnosticsDirectory: URL(fileURLWithPath: "/tmp/Wallume/Diagnostics"),
            exportState: .failed("expected export failure")
        )

        XCTAssertEqual(state.diagnosticsControls.map(\.role), [.button, .button])
        XCTAssertEqual(state.diagnosticsControls.map(\.isEnabled), [true, true])
        XCTAssertEqual(
            state.diagnosticsControls.map(\.action),
            [.diagnostics(.retry), .diagnostics(.chooseAnotherDestination)]
        )
    }

}

private enum SettingsViewExportError: LocalizedError {
    case expected
    var errorDescription: String? { "expected export failure" }
}
