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
}

@MainActor private final class SurfaceFactory: DesktopSurfaceFactory {
    private var surfaces = [DisplayID: Surface]()
    func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface { let value = Surface(); surfaces[screen.id] = value; return value }
    func surface(for id: DisplayID) -> Surface? { surfaces[id] }
}

@MainActor private final class Surface: DesktopSurface {
    var frames = [CGRect](); var closeCount = 0
    func show(frame: CGRect) { frames.append(frame) }
    func close() { closeCount += 1 }
}
