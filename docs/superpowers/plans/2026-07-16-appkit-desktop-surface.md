# AppKit desktop surface implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add notification-driven display snapshots and testable desktop surface lifecycle management.

**Architecture:** AppKit stays in a new edge module. Pure values and the controller use injected screen and surface interfaces; production objects wrap NSScreen and NSWindow on the main actor.

**Tech Stack:** Swift 6, AppKit, Foundation, XCTest, macOS 14.

## Global constraints

- Do not create AVPlayer, media assignment, menu-bar UI, polling, or lock-screen writes
- Perform all AppKit work on the main actor
- Tests use fake screens and surfaces, not live displays
- Windows must not activate, receive pointer events, or contain application UI

---

### Task 1: Add display and desktop-surface contracts

**Files:**

- Create: `Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift`
- Create: `Tests/WallumeCoreTests/DesktopSurfaceModelsTests.swift`

**Interfaces:**

- Produces `DesktopScreen`, `DesktopScreenProvider`, `DesktopSurface`, `DesktopSurfaceFactory`, and `DesktopSurfaceFailure`

- [ ] **Step 1: Write the failing value test**

```swift
func testDesktopScreenUsesStableIDAndFrame() {
    let screen = DesktopScreen(id: DisplayID("screen-1"), frame: .init(x: 10, y: 20, width: 1920, height: 1080))
    XCTAssertEqual(screen.id, DisplayID("screen-1"))
    XCTAssertEqual(screen.frame.width, 1920)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter DesktopSurfaceModelsTests`

Expected: compilation fails because the contracts do not exist.

- [ ] **Step 3: Implement the contracts**

```swift
import CoreGraphics
import Foundation

public struct DesktopScreen: Hashable, Sendable {
    public let id: DisplayID
    public let frame: CGRect
}

@MainActor public protocol DesktopScreenProvider: AnyObject {
    var screens: [DesktopScreen] { get }
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor public protocol DesktopSurface: AnyObject {
    func show(frame: CGRect)
    func close()
}

@MainActor public protocol DesktopSurfaceFactory: AnyObject {
    func makeSurface(for screen: DesktopScreen) throws -> any DesktopSurface
}
```

- [ ] **Step 4: Verify green and commit**

Run: `swift test --filter DesktopSurfaceModelsTests`

```bash
git add Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift Tests/WallumeCoreTests/DesktopSurfaceModelsTests.swift
git commit -m "feat: add desktop surface contracts"
```

### Task 2: Implement controller reconciliation

**Files:**

- Create: `Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift`
- Create: `Tests/WallumeCoreTests/DesktopWindowControllerTests.swift`

**Interfaces:**

- Produces `DesktopWindowController.reconcile(_:) -> [DesktopSurfaceFailure]`

- [ ] **Step 1: Write the failing lifecycle test**

```swift
func testReconcileCreatesUpdatesAndClosesSurfaces() throws {
    let factory = RecordingSurfaceFactory()
    let controller = DesktopWindowController(factory: factory)
    let first = DesktopScreen(id: DisplayID("one"), frame: .init(x: 0, y: 0, width: 100, height: 100))

    XCTAssertEqual(controller.reconcile([first]), [])
    XCTAssertEqual(factory.created, [first.id])

    _ = controller.reconcile([.init(id: first.id, frame: .init(x: 0, y: 0, width: 200, height: 100))])
    XCTAssertEqual(factory.surface(for: first.id)?.shownFrames.count, 2)

    _ = controller.reconcile([])
    XCTAssertEqual(factory.surface(for: first.id)?.closeCount, 1)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter DesktopWindowControllerTests/testReconcileCreatesUpdatesAndClosesSurfaces`

Expected: compilation fails because the controller does not exist.

- [ ] **Step 3: Implement the minimal main-actor controller**

```swift
@MainActor
public final class DesktopWindowController {
    public init(factory: any DesktopSurfaceFactory)
    public func reconcile(_ screens: [DesktopScreen]) -> [DesktopSurfaceFailure]
}
```

Create one surface per ID. Call `show(frame:)` on creation and frame changes only. Close and remove surfaces absent from the new snapshot. Sort input by ID. If factory creation throws, append one failure and do not affect any other surface.

- [ ] **Step 4: Add failure and idempotence tests, verify, commit**

```swift
func testFailedSurfaceCreationDoesNotPreventOtherDisplay() {
    let factory = RecordingSurfaceFactory(failingIDs: [DisplayID("bad")])
    let controller = DesktopWindowController(factory: factory)

    let failures = controller.reconcile([
        .init(id: DisplayID("bad"), frame: .zero),
        .init(id: DisplayID("good"), frame: .zero),
    ])

    XCTAssertEqual(failures.map(\.displayID), [DisplayID("bad")])
    XCTAssertEqual(factory.created, [DisplayID("good")])
}
```

Run: `swift test --filter DesktopWindowControllerTests`

```bash
git add Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift Tests/WallumeCoreTests/DesktopWindowControllerTests.swift
git commit -m "feat: manage desktop surface lifecycle"
```

### Task 3: Add AppKit production adapters and acceptance

**Files:**

- Create: `Sources/WallumeCore/AppKitRuntime/AppKitDesktopSurface.swift`
- Create: `Sources/WallumeCore/AppKitRuntime/AppKitScreenProvider.swift`
- Create: `Tests/WallumeCoreTests/AppKitDesktopSurfaceTests.swift`
- Create: `docs/desktop-surfaces.md`

- [ ] **Step 1: Write the failing adapter-configuration test**

```swift
func testDesktopSurfaceConfigurationDoesNotActivateOrReceiveMouseEvents() {
    let configuration = AppKitDesktopSurface.Configuration.desktop
    XCTAssertTrue(configuration.ignoresMouseEvents)
    XCTAssertFalse(configuration.activates)
    XCTAssertTrue(configuration.joinsAllSpaces)
}
```

- [ ] **Step 2: Verify red and implement**

Run: `swift test --filter AppKitDesktopSurfaceTests`

Implement `AppKitDesktopSurface` with a borderless transparent `NSWindow`, empty view content, no shadow, mouse-event ignoring, nonactivation, and all-Spaces behavior. Implement `AppKitScreenProvider` with screen-parameter and application-activation notifications; call its change handler on the main actor and remove observers in `stop()`.

- [ ] **Step 3: Verify final acceptance and commit**

Run: `swift test && swift build -c release && git diff --check`

Create `docs/desktop-surfaces.md` with Scope, Window behavior, Lifecycle, Notification source, Failure isolation, Manual checks, and Next adapter sections.

```bash
git add Sources/WallumeCore/AppKitRuntime Tests/WallumeCoreTests/AppKitDesktopSurfaceTests.swift docs/desktop-surfaces.md
git commit -m "feat: add AppKit desktop surfaces"
```

## Plan self-review

- Tasks 1–3 cover the display snapshot contract, notification boundary, surface lifecycle, window configuration, failure isolation, idempotence, tests, and manual acceptance.
- No task creates an AVPlayer, assigns media, polls, or writes lock-screen state.

