import AppKit
import SwiftUI
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class LockScreenViewTests: XCTestCase {
    func testUnconfiguredStateOffersSetupRefresh() {
        let model = LockScreenPageViewState(state: .unconfigured)
        XCTAssertEqual(model.nextAction, .refresh)
        XCTAssertTrue(model.canRefresh)
        XCTAssertTrue(model.isAwaitingDetection)
        XCTAssertFalse(model.showsSystemWallpaperSettings)
        XCTAssertNil(model.slotGuidance)
        XCTAssertFalse(model.canRequestEnable)
    }

    func testReadyStateWithoutSlotsGuidesUserToSystemWallpaperSettings() {
        let model = LockScreenPageViewState(state: state(phase: .readyToConfigure, slots: []))
        XCTAssertEqual(model.nextAction, .openSystemWallpaperSettings)
        XCTAssertFalse(model.isAwaitingDetection)
        XCTAssertTrue(model.showsSystemWallpaperSettings)
        XCTAssertEqual(model.slotGuidance, "请先在系统壁纸设置中下载并选择动态壁纸，然后返回刷新检测。")
    }

    func testSelectedSlotRequiresSeparateRiskConfirmation() {
        let model = LockScreenPageViewState(state: state(phase: .readyToConfigure, selectedAerialID: "sea", slots: [slot("sea")]))
        XCTAssertEqual(model.selectedSlotName, "海岸")
        XCTAssertTrue(model.canRequestEnable)
        XCTAssertTrue(model.showsRiskConfirmation)
        XCTAssertEqual(model.nextAction, .confirmEnable)
    }

    func testWaitingStateExplainsThatMainWallpaperIsRequired() {
        let model = LockScreenPageViewState(state: state(phase: .waitingForMainWallpaper))
        XCTAssertEqual(model.nextAction, .waitingForMainWallpaper)
        XCTAssertTrue(model.statusText.contains("主显示器"))
    }

    func testSyncedStateShowsMediaNameAndTime() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let model = LockScreenPageViewState(state: LockScreenSyncState(
            phase: .synced,
            syncedMedia: .init(id: UUID(), displayName: "Ocean"),
            lastSyncedAt: date,
            lastResult: .synced,
            capabilities: capabilities(disable: true)
        ))
        XCTAssertEqual(model.syncedMediaName, "Ocean")
        XCTAssertEqual(model.syncedAt, date)
        XCTAssertEqual(model.syncTimeText, date.formatted(date: .abbreviated, time: .shortened))
        XCTAssertTrue(model.canRestore)
        XCTAssertTrue(model.canResynchronize)
        XCTAssertTrue(model.canExportDiagnostics)
    }

    func testRepairStateOffersRestoreAndRetry() {
        let model = LockScreenPageViewState(state: LockScreenSyncState(
            phase: .needsRepair,
            lastError: "恢复材料需要检查",
            capabilities: capabilities(disable: true, retry: true)
        ))
        XCTAssertTrue(model.canRestore)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.nextAction, .restore)
    }

    func testUnsupportedStateNeverOffersEnable() {
        let model = LockScreenPageViewState(state: LockScreenSyncState(
            phase: .unsupported,
            probe: .init(
                generation: .tahoe,
                writesPermitted: false,
                manifestExists: true,
                indexExists: true,
                availableSlots: [slot("tahoe-day")],
                foreignBackupNames: []
            ),
            capabilities: capabilities(refresh: true, retry: true)
        ))
        XCTAssertFalse(model.canRequestEnable)
        XCTAssertFalse(model.canRefresh)
        XCTAssertFalse(model.canRetry)
        XCTAssertFalse(model.canResynchronize)
        XCTAssertTrue(model.showsSystemWallpaperSettings)
        XCTAssertEqual(model.nextAction, .openSystemWallpaperSettings)
    }

    func testUnsupportedStateOffersGeneratedStaticFallback() {
        let fallbackURL = URL(fileURLWithPath: "/cover.jpg")
        let model = LockScreenPageViewState(state: LockScreenSyncState(
            phase: .unsupported,
            staticFallback: .init(mediaID: UUID(), displayName: "Ocean", imageURL: fallbackURL)
        ))

        XCTAssertEqual(model.staticFallbackName, "Ocean")
        XCTAssertEqual(model.staticFallbackImageURL, fallbackURL)
    }

    @MainActor
    func testSwiftUIViewHasNonzeroFittingSize() throws {
        let fixture = try LockScreenFeatureStoreFixture()
        defer { fixture.cleanup() }
        let host = NSHostingView(rootView: LockScreenView(store: LockScreenFeatureStore(service: fixture.service)))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}

private func state(
    phase: LockScreenSyncPhase,
    selectedAerialID: String? = nil,
    slots: [AerialSlot] = []
) -> LockScreenSyncState {
    LockScreenSyncState(
        phase: phase,
        selectedAerialID: selectedAerialID,
        probe: .init(generation: .sequoia, writesPermitted: true, manifestExists: true, indexExists: true, availableSlots: slots, foreignBackupNames: []),
        capabilities: capabilities(select: !slots.isEmpty, confirm: selectedAerialID != nil)
    )
}

private func slot(_ id: String) -> AerialSlot {
    .init(id: id, displayName: "海岸", videoURL: URL(fileURLWithPath: "/fixture.mov"))
}

private func capabilities(
    refresh: Bool = true,
    select: Bool = false,
    confirm: Bool = false,
    disable: Bool = false,
    retry: Bool = false
) -> LockScreenSyncCapabilities {
    .init(canRefreshProbe: refresh, canSelectAerialSlot: select, canConfirmEnable: confirm, canDisableAndRestore: disable, canRetry: retry)
}
