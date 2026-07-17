import Foundation
import XCTest
@testable import WallumeCore

final class RuntimeCoordinatorTests: XCTestCase {
    func testRemovingDisplayReleasesItsOnlyResource() async {
        let item = MediaItem.fixture()
        let factory = NoopFactory()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [item]),
            pool: PlayerPool(factory: factory)
        )
        let display = DisplayID("display-1")

        _ = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: item.id)],
            environment: .active
        )
        let snapshot = await coordinator.reconcile(
            displays: [], assignments: [], environment: .active
        )

        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.resourceReferenceCounts.isEmpty)
        XCTAssertEqual(factory.releaseCount, 1)
    }

    func testRemovingAssignmentReleasesItsOnlyResourceWhileDisplayRemains() async {
        let item = MediaItem.fixture()
        let factory = NoopFactory()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [item]),
            pool: PlayerPool(factory: factory)
        )
        let display = DisplayID("display-1")

        _ = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: item.id)],
            environment: .active
        )
        let snapshot = await coordinator.reconcile(
            displays: [display], assignments: [], environment: .active
        )

        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.resourceReferenceCounts.isEmpty)
        XCTAssertEqual(factory.releaseCount, 1)
    }

    func testShutdownReleasesEverySession() async {
        let item = MediaItem.fixture()
        let factory = NoopFactory()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [item]),
            pool: PlayerPool(factory: factory)
        )

        _ = await coordinator.reconcile(
            displays: [DisplayID("one"), DisplayID("two")],
            assignments: [
                .init(displayID: DisplayID("one"), mediaID: item.id),
                .init(displayID: DisplayID("two"), mediaID: item.id),
            ],
            environment: .active
        )
        let snapshot = await coordinator.shutdown()

        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.resourceReferenceCounts.isEmpty)
        XCTAssertEqual(factory.releaseCount, 1)
    }

    func testDuplicateAssignmentsPreserveExistingSessionAndReportFailure() async {
        let old = MediaItem.fixture()
        let first = MediaItem.fixture()
        let second = MediaItem.fixture()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [old, first, second]),
            pool: PlayerPool(factory: NoopFactory())
        )
        let display = DisplayID("display-1")

        _ = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: old.id)],
            environment: .active
        )
        let snapshot = await coordinator.reconcile(
            displays: [display],
            assignments: [
                .init(displayID: display, mediaID: first.id),
                .init(displayID: display, mediaID: second.id),
            ],
            environment: .active
        )

        XCTAssertEqual(snapshot.sessions.single?.mediaID, old.id)
        XCTAssertEqual(snapshot.failures.map(\.displayID), [display])
    }

    func testUnavailableSwitchPreservesExistingSession() async {
        let old = MediaItem.fixture()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [old]),
            pool: PlayerPool(factory: NoopFactory())
        )
        let display = DisplayID("display-1")

        _ = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: old.id)],
            environment: .active
        )
        let snapshot = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: UUID())],
            environment: .active
        )

        XCTAssertEqual(snapshot.sessions.single?.mediaID, old.id)
        XCTAssertEqual(snapshot.failures.map(\.displayID), [display])
    }

    func testPauseReasonsRemainUntilEverySignalClears() async {
        let item = MediaItem.fixture()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [item]),
            pool: PlayerPool(factory: NoopFactory())
        )
        let display = DisplayID("display-1")

        _ = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: item.id)],
            environment: .init(userPaused: true, appObscured: false, screenLocked: true, lowPowerMode: false, systemSleeping: false)
        )
        let paused = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: item.id)],
            environment: .init(userPaused: false, appObscured: false, screenLocked: true, lowPowerMode: false, systemSleeping: false)
        )
        let resumed = await coordinator.reconcile(
            displays: [display],
            assignments: [.init(displayID: display, mediaID: item.id)],
            environment: .active
        )

        XCTAssertEqual(paused.pauseReasons, [.screenLocked])
        XCTAssertEqual(resumed.pauseReasons, [])
    }

    func testRepeatingSameSnapshotDoesNotCreateAnotherResource() async {
        let item = MediaItem.fixture()
        let coordinator = RuntimeCoordinator(
            catalog: Catalog(items: [item]),
            pool: PlayerPool(factory: NoopFactory())
        )
        let display = DisplayID("display-1")
        let input: Set<RuntimeAssignment> = [.init(displayID: display, mediaID: item.id)]

        let first = await coordinator.reconcile(displays: [display], assignments: input, environment: .active)
        let second = await coordinator.reconcile(displays: [display], assignments: input, environment: .active)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.resourceCreationCount, 1)
    }
}

private extension Array where Element == RuntimeDisplaySession {
    var single: RuntimeDisplaySession? { count == 1 ? first : nil }
}

private struct Catalog: MediaCatalog {
    let items: [MediaItem]
    func item(id: UUID) throws -> MediaItem? { items.first { $0.id == id } }
}

private final class NoopFactory: PlayerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0
    var releaseCount: Int { lock.withLock { releases } }
    func makePlayer(for media: MediaItem) async throws -> any PlaybackResource {
        NoopResource { [weak self] in self?.lock.withLock { self?.releases += 1 } }
    }
}

private final class NoopResource: PlaybackResource, @unchecked Sendable {
    let resourceID = UUID()
    private let didRelease: @Sendable () -> Void
    init(didRelease: @escaping @Sendable () -> Void) { self.didRelease = didRelease }
    func play() async throws {}
    func pause() async throws {}
    func release() async { didRelease() }
}

private extension MediaItem {
    static func fixture() -> MediaItem {
        .init(id: UUID(), sourceHash: String(repeating: "a", count: 64), sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Source", sourceByteCount: 1, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30, durationSeconds: 1, codec: "hvc1", variantURL: URL(fileURLWithPath: "/tmp/variant.mov"), thumbnailURL: URL(fileURLWithPath: "/tmp/thumbnail.jpg"), coverURL: URL(fileURLWithPath: "/tmp/cover.jpg"), createdAt: .init(timeIntervalSince1970: 0))
    }
}
