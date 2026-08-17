import XCTest
@testable import WallumeWallpaperPOC

final class WallpaperExtensionRuntimeProbeTests: XCTestCase {
    func testReportsMissingFrameworkWithoutInspectingClasses() {
        let loader = RecordingLibraryLoader(result: false)
        let probe = WallpaperExtensionRuntimeProbe(
            libraryLoader: loader,
            classIsPresent: { _ in
                XCTFail("Class lookup must not run when the framework cannot load")
                return false
            }
        )

        let report = probe.inspect()

        XCTAssertEqual(loader.paths, [WallpaperExtensionRuntimeProbe.frameworkPath])
        XCTAssertFalse(report.frameworkLoaded)
        XCTAssertEqual(report.availableClasses, [])
        XCTAssertEqual(report.missingClasses, WallpaperExtensionRuntimeProbe.requiredClassNames)
        XCTAssertFalse(report.isCompatible)
    }

    func testReportsOnlyRequiredClassesAndNeverPerformsActivation() {
        let loader = RecordingLibraryLoader(result: true)
        let present = Set([
            "WallpaperRemoteContextXPC",
            "WallpaperIDXPC",
        ])
        let probe = WallpaperExtensionRuntimeProbe(
            libraryLoader: loader,
            classIsPresent: { present.contains($0) }
        )

        let report = probe.inspect()

        XCTAssertEqual(loader.paths, [WallpaperExtensionRuntimeProbe.frameworkPath])
        XCTAssertTrue(report.frameworkLoaded)
        XCTAssertEqual(report.availableClasses, ["WallpaperRemoteContextXPC", "WallpaperIDXPC"])
        XCTAssertEqual(report.missingClasses, [
            "WallpaperSnapshotXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperSettingsViewModelsXPC",
        ])
        XCTAssertFalse(report.isCompatible)
    }

    func testProtocolSurfaceStaysMinimalAndReviewable() {
        XCTAssertEqual(WallpaperExtensionProtocolSurface.hostToProviderSelectors, [
            "acquireWithId:request:reply:",
            "updateWithId:request:reply:",
            "invalidateWithId:reply:",
            "snapshotWithId:reply:",
            "provideSettingsViewModelsWithContentTypes:reply:",
        ])
        XCTAssertEqual(WallpaperExtensionProtocolSurface.providerToHostSelectors, [
            "invalidateSnapshotsWithReply:",
            "updateSettingsViewModels:reply:",
        ])
    }
}

private final class RecordingLibraryLoader: DynamicLibraryLoading, @unchecked Sendable {
    private let result: Bool
    private(set) var paths: [String] = []

    init(result: Bool) {
        self.result = result
    }

    func open(path: String) -> Bool {
        paths.append(path)
        return result
    }
}
