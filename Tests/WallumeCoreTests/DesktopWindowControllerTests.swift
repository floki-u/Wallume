import XCTest
@testable import WallumeCore

final class DesktopWindowControllerTests: XCTestCase {
    @MainActor
    func testReconcileCreatesUpdatesAndClosesSurface() {
        let factory = SurfaceFactory()
        let controller = DesktopWindowController(factory: factory)
        let screen = DesktopScreen(id: DisplayID("one"), frame: .init(x: 0, y: 0, width: 100, height: 100))

        XCTAssertEqual(controller.reconcile([screen]), [])
        XCTAssertEqual(factory.surface(for: screen.id)?.frames.count, 1)
        _ = controller.reconcile([.init(id: screen.id, frame: .init(x: 0, y: 0, width: 200, height: 100))])
        XCTAssertEqual(factory.surface(for: screen.id)?.frames.count, 2)
        _ = controller.reconcile([])
        XCTAssertEqual(factory.surface(for: screen.id)?.closeCount, 1)
    }

    @MainActor
    func testFailedSurfaceDoesNotPreventOtherDisplay() {
        let bad = DisplayID("bad")
        let good = DisplayID("good")
        let factory = SurfaceFactory(failingIDs: [bad])
        let controller = DesktopWindowController(factory: factory)

        let failures = controller.reconcile([
            .init(id: bad, frame: .zero),
            .init(id: good, frame: .zero),
        ])

        XCTAssertEqual(failures.map(\.displayID), [bad])
        XCTAssertNotNil(factory.surface(for: good))
    }

    @MainActor
    func testApplyBindsSessionPresentationAndCoverToDisplay() {
        let factory = SurfaceFactory()
        let controller = DesktopWindowController(factory: factory)
        let displayID = DisplayID("one")
        let media = MediaItem.presentationFixture()
        let resourceID = UUID()
        _ = controller.reconcile([.init(id: displayID, frame: .zero)])

        _ = controller.apply(
            snapshot: RuntimeSnapshot(
                sessions: [.init(displayID: displayID, mediaID: media.id, resourceID: resourceID)],
                resourceReferenceCounts: [media.id: 1],
                pauseReasons: [],
                failures: [],
                resourceCreationCount: 1
            ),
            mediaByID: [media.id: media],
            modesByDisplay: [displayID: .fit]
        )

        XCTAssertEqual(factory.surface(for: displayID)?.presentation?.resourceID, resourceID)
        XCTAssertEqual(factory.surface(for: displayID)?.fallbackURL, media.coverURL)
        XCTAssertEqual(factory.surface(for: displayID)?.mode, .fit)
    }

    @MainActor
    func testApplyUsesCoverWhenPlaybackCreationFailedWithoutSession() {
        let factory = SurfaceFactory()
        let controller = DesktopWindowController(factory: factory)
        let displayID = DisplayID("one")
        let media = MediaItem.presentationFixture()
        _ = controller.reconcile([.init(id: displayID, frame: .zero)])

        _ = controller.apply(
            snapshot: RuntimeSnapshot(
                sessions: [], resourceReferenceCounts: [:], pauseReasons: [],
                failures: [.init(displayID: displayID, mediaID: media.id, message: "unplayable")],
                resourceCreationCount: 0
            ),
            mediaByID: [media.id: media],
            modesByDisplay: [displayID: .stretch]
        )

        XCTAssertNil(factory.surface(for: displayID)?.presentation)
        XCTAssertEqual(factory.surface(for: displayID)?.fallbackURL, media.coverURL)
        XCTAssertEqual(factory.surface(for: displayID)?.mode, .stretch)
    }

    @MainActor
    func testUnchangedApplyDoesNotRecreatePresentation() {
        let factory = SurfaceFactory()
        let controller = DesktopWindowController(factory: factory)
        let displayID = DisplayID("one")
        let media = MediaItem.presentationFixture()
        let snapshot = RuntimeSnapshot(
            sessions: [.init(displayID: displayID, mediaID: media.id, resourceID: UUID())],
            resourceReferenceCounts: [media.id: 1], pauseReasons: [], failures: [],
            resourceCreationCount: 1
        )
        _ = controller.reconcile([.init(id: displayID, frame: .zero)])

        _ = controller.apply(snapshot: snapshot, mediaByID: [media.id: media], modesByDisplay: [displayID: .fill])
        _ = controller.apply(snapshot: snapshot, mediaByID: [media.id: media], modesByDisplay: [displayID: .fill])

        XCTAssertEqual(factory.surface(for: displayID)?.presentationCallCount, 1)
    }

    @MainActor
    func testPresentationFailureIsReturnedForAffectedDisplay() {
        let displayID = DisplayID("one")
        let factory = SurfaceFactory(presentationFailingIDs: [displayID])
        let controller = DesktopWindowController(factory: factory)
        let media = MediaItem.presentationFixture()
        _ = controller.reconcile([.init(id: displayID, frame: .zero)])

        let failures = controller.apply(
            snapshot: RuntimeSnapshot(
                sessions: [.init(displayID: displayID, mediaID: media.id, resourceID: UUID())],
                resourceReferenceCounts: [media.id: 1], pauseReasons: [], failures: [],
                resourceCreationCount: 1
            ),
            mediaByID: [media.id: media], modesByDisplay: [displayID: .fill]
        )

        XCTAssertEqual(failures.map(\.displayID), [displayID])
    }

    @MainActor
    func testCloseAllClosesEverySurface() {
        let factory = SurfaceFactory()
        let controller = DesktopWindowController(factory: factory)
        let one = DisplayID("one")
        let two = DisplayID("two")
        _ = controller.reconcile([
            .init(id: one, frame: .zero),
            .init(id: two, frame: .zero),
        ])

        controller.closeAll()

        XCTAssertEqual(factory.surface(for: one)?.closeCount, 1)
        XCTAssertEqual(factory.surface(for: two)?.closeCount, 1)
    }
}

@MainActor private final class SurfaceFactory: DesktopSurfaceFactory {
    private var surfaces = [DisplayID: Surface]()
    private let failingIDs: Set<DisplayID>
    private let presentationFailingIDs: Set<DisplayID>
    init(failingIDs: Set<DisplayID> = [], presentationFailingIDs: Set<DisplayID> = []) {
        self.failingIDs = failingIDs
        self.presentationFailingIDs = presentationFailingIDs
    }
    func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface {
        if failingIDs.contains(screen.id) { throw SurfaceError.creationFailed }
        let value = Surface(failsPresentation: presentationFailingIDs.contains(screen.id))
        surfaces[screen.id] = value
        return value
    }
    func surface(for id: DisplayID) -> Surface? { surfaces[id] }
}

private enum SurfaceError: Error { case creationFailed }

@MainActor private final class Surface: DesktopSurface {
    var frames = [CGRect](); var closeCount = 0
    var presentation: PlaybackPresentation?
    var fallbackURL: URL?
    var mode: WallpaperPresentationMode?
    var presentationCallCount = 0
    let failsPresentation: Bool
    init(failsPresentation: Bool = false) { self.failsPresentation = failsPresentation }
    func show(frame: CGRect) { frames.append(frame) }
    func setPresentation(_ presentation: PlaybackPresentation?, fallbackURL: URL?, mode: WallpaperPresentationMode) throws {
        presentationCallCount += 1
        if failsPresentation { throw SurfaceError.creationFailed }
        self.presentation = presentation
        self.fallbackURL = fallbackURL
        self.mode = mode
    }
    func close() { closeCount += 1 }
}

private extension MediaItem {
    static func presentationFixture() -> MediaItem {
        MediaItem(
            id: UUID(), sourceHash: String(repeating: "a", count: 64),
            sourceURL: URL(fileURLWithPath: "/tmp/source.mov"), displayName: "Presentation",
            sourceByteCount: 1, pixelWidth: 1920, pixelHeight: 1080, frameRate: 30,
            durationSeconds: 1, codec: "hvc1", variantURL: URL(fileURLWithPath: "/tmp/variant.mov"),
            thumbnailURL: URL(fileURLWithPath: "/tmp/thumb.jpg"),
            coverURL: URL(fileURLWithPath: "/tmp/cover.jpg"), createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
