import Foundation
import XCTest
@testable import WallumeAppSupport
import WallumeCore

final class WallpaperRuntimeServiceTests: XCTestCase {
    @MainActor
    func testStartReconcilesConnectedAssignmentsAndPresentationModes() async {
        let fixture = RuntimeFixture()
        fixture.screens.value = [fixture.one, fixture.two]
        let assignments = fixture.assignments([fixture.one: .fit, fixture.two: .stretch])

        fixture.service.start(assignments: assignments)
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.runtime.inputs.last?.displays, [fixture.one.id, fixture.two.id])
        XCTAssertEqual(fixture.windows.lastModes, [fixture.one.id: .fit, fixture.two.id: .stretch])
        XCTAssertEqual(fixture.service.latestSnapshot.activeDisplayCount, 2)
    }

    @MainActor
    func testDisconnectClosesRuntimeSessionWithoutChangingSavedAssignments() async {
        let fixture = RuntimeFixture()
        fixture.screens.value = [fixture.one, fixture.two]
        let assignments = fixture.assignments([fixture.one: .fill, fixture.two: .fill])
        fixture.service.start(assignments: assignments)
        await fixture.service.waitForIdle()

        fixture.screens.value = [fixture.one]
        fixture.screens.sendChange()
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.runtime.inputs.last?.displays, [fixture.one.id])
        XCTAssertEqual(fixture.service.assignments, assignments)
    }

    @MainActor
    func testUserPauseComposesWithEnvironmentReasons() async {
        let fixture = RuntimeFixture()
        fixture.screens.value = [fixture.one]
        fixture.service.start(assignments: fixture.assignments([fixture.one: .fill], userPaused: true))
        fixture.environment.send(.init(userPaused: false, appObscured: false, screenLocked: true, lowPowerMode: false, systemSleeping: false))
        await fixture.service.waitForIdle()

        XCTAssertEqual(fixture.runtime.inputs.last?.environment.pauseReasons, [.user, .screenLocked])
    }

    @MainActor
    func testStopUsesOrderedCleanup() async {
        let fixture = RuntimeFixture()
        fixture.service.start(assignments: .empty)
        await fixture.service.waitForIdle()

        await fixture.service.stop()

        XCTAssertEqual(fixture.events.values.suffix(5), ["screens.stop", "environment.stop", "occlusion.stop", "windows.closeAll", "runtime.shutdown"])
    }
}

@MainActor
private final class RuntimeFixture {
    let events = EventRecorder()
    let screens: StubScreens
    let environment: StubEnvironment
    let occlusion: StubOcclusion
    let runtime: StubRuntime
    let windows: StubWindows
    let catalog: StubCatalog
    let service: WallpaperRuntimeService
    let media = runtimeMedia()
    let one = runtimeScreen("one")
    let two = runtimeScreen("two")

    init() {
        screens = StubScreens(events: events)
        environment = StubEnvironment(events: events)
        occlusion = StubOcclusion(events: events)
        runtime = StubRuntime(events: events)
        windows = StubWindows(events: events)
        catalog = StubCatalog()
        catalog.items = [media.id: media]
        service = WallpaperRuntimeService(screens: screens, environmentMonitor: environment, occlusionMonitor: occlusion, runtime: runtime, windows: windows, catalog: catalog)
    }

    func assignments(_ values: [DesktopScreen: WallpaperPresentationMode], userPaused: Bool = false) -> DisplayAssignmentSnapshot {
        .init(records: values.map { screen, mode in
            .init(displayID: screen.id, displayName: screen.name, pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight, wasMain: screen.isMain, identityPersistence: screen.identityPersistence, mediaID: media.id, presentationMode: mode)
        }, userPaused: userPaused)
    }
}

private final class EventRecorder: @unchecked Sendable { var values = [String]() }

@MainActor private final class StubScreens: DesktopScreenProvider {
    var value = [DesktopScreen](); var callback: (() -> Void)?; let events: EventRecorder
    init(events: EventRecorder) { self.events = events }
    var screens: [DesktopScreen] { value }
    func start(onChange: @escaping @MainActor () -> Void) { callback = onChange }
    func stop() { events.values.append("screens.stop"); callback = nil }
    func sendChange() { callback?() }
}

@MainActor private final class StubEnvironment: RuntimeEnvironmentMonitoring {
    var callback: ((RuntimeEnvironment) -> Void)?; let events: EventRecorder
    init(events: EventRecorder) { self.events = events }
    func start(onChange: @escaping @MainActor (RuntimeEnvironment) -> Void) { callback = onChange; onChange(.active) }
    func stop() { events.values.append("environment.stop"); callback = nil }
    func send(_ value: RuntimeEnvironment) { callback?(value) }
}

@MainActor private final class StubOcclusion: RuntimeOcclusionMonitoring {
    var callback: ((Bool) -> Void)?; let events: EventRecorder
    init(events: EventRecorder) { self.events = events }
    func start(displays: [DesktopScreen], onChange: @escaping @MainActor (Bool) -> Void) { callback = onChange; onChange(false) }
    func updateDisplays(_ displays: [DesktopScreen]) {}
    func stop() { events.values.append("occlusion.stop"); callback = nil }
}

private final class StubRuntime: RuntimeCoordinating, @unchecked Sendable {
    struct Input { let displays: Set<DisplayID>; let assignments: Set<RuntimeAssignment>; let environment: RuntimeEnvironment }
    var inputs = [Input](); let events: EventRecorder
    init(events: EventRecorder) { self.events = events }
    func reconcile(displays: Set<DisplayID>, assignments: Set<RuntimeAssignment>, environment: RuntimeEnvironment) async -> RuntimeSnapshot {
        inputs.append(.init(displays: displays, assignments: assignments, environment: environment))
        return .init(sessions: assignments.map { .init(displayID: $0.displayID, mediaID: $0.mediaID, resourceID: UUID()) }, resourceReferenceCounts: [:], pauseReasons: environment.pauseReasons, failures: [], resourceCreationCount: assignments.isEmpty ? 0 : 1)
    }
    func shutdown() async -> RuntimeSnapshot { events.values.append("runtime.shutdown"); return .init(sessions: [], resourceReferenceCounts: [:], pauseReasons: [], failures: [], resourceCreationCount: 0) }
}

@MainActor private final class StubWindows: DesktopWindowControlling {
    let events: EventRecorder; var lastModes = [DisplayID: WallpaperPresentationMode]()
    init(events: EventRecorder) { self.events = events }
    func reconcile(_ screens: [DesktopScreen]) -> [DesktopSurfaceFailure] { [] }
    func apply(snapshot: RuntimeSnapshot, mediaByID: [UUID: MediaItem], modesByDisplay: [DisplayID: WallpaperPresentationMode]) { lastModes = modesByDisplay }
    func closeAll() { events.values.append("windows.closeAll") }
}

private final class StubCatalog: MediaCatalog, @unchecked Sendable { var items = [UUID: MediaItem](); func item(id: UUID) throws -> MediaItem? { items[id] } }
private func runtimeScreen(_ id: String) -> DesktopScreen { .init(id: DisplayID("cg-uuid:\(id)"), frame: .zero, name: id, pixelWidth: 1920, pixelHeight: 1080, isMain: id == "one", identityPersistence: .persistent) }
private func runtimeMedia() -> MediaItem { .init(id: UUID(), sourceHash: "hash", sourceURL: URL(fileURLWithPath: "/source.mov"), displayName: "Ocean", sourceByteCount: 1, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30, durationSeconds: 1, codec: "hvc1", variantURL: URL(fileURLWithPath: "/variant.mov"), thumbnailURL: URL(fileURLWithPath: "/thumb.jpg"), coverURL: URL(fileURLWithPath: "/cover.jpg"), createdAt: .distantPast) }
