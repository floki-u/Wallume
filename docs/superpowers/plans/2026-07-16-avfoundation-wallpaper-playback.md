# AVFoundation wallpaper playback implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play registered wallpaper variants through a shared, muted, looping AVFoundation resource and present them on per-display AppKit surfaces with notification-driven pause state.

**Architecture:** `PlayerPool` keeps ownership and reference counting while a main-actor presentation registry maps opaque resource IDs to shared `AVPlayer` instances. Desktop surfaces attach independent `AVPlayerLayer` objects to the shared player. A separate environment monitor converts macOS session, sleep, and low-power events into immutable runtime environment updates.

**Tech Stack:** Swift 6, AVFoundation, AppKit, Core Animation, Foundation, XCTest, macOS 14.

## Global constraints

- Playback is muted; this phase does not expose volume controls
- One `AVQueuePlayer` and `AVPlayerLooper` exist per active media ID
- Each display owns a distinct `AVPlayerLayer` configured with `.resizeAspectFill`
- Do not poll, write lock-screen state, or access user media in automated tests
- Keep AVFoundation and AppKit objects on the main actor
- Player creation failures preserve other displays and use the registered cover as fallback
- Minimum-hardware performance approval remains outside this plan

---

### Task 1: Add presentation attachment contracts

**Files:**

- Modify: `Sources/WallumeCore/Runtime/PlayerPool.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift`
- Create: `Tests/WallumeCoreTests/PlaybackPresentationTests.swift`

**Interfaces:**

- Produces `PlaybackPresentation`, `PlaybackPresentationRegistry`, and `DesktopSurface.setPresentation(_:fallbackURL:)`
- A presentation is an opaque Sendable value containing only `resourceID`
- The registry resolves a resource ID to a main-actor presentation object without exposing AVFoundation to the runtime core
- Changes player creation, playback commands, and release to async methods so main-actor AVFoundation implementations satisfy the contracts safely

- [ ] **Step 1: Write the failing attachment test**

```swift
@MainActor
func testSurfaceReceivesOpaquePresentationAndFallback() {
    let surface = RecordingDesktopSurface()
    let presentation = PlaybackPresentation(resourceID: UUID())
    let fallback = URL(fileURLWithPath: "/tmp/cover.jpg")

    surface.setPresentation(presentation, fallbackURL: fallback)

    XCTAssertEqual(surface.presentation, presentation)
    XCTAssertEqual(surface.fallbackURL, fallback)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter PlaybackPresentationTests`

Expected: compilation fails because `PlaybackPresentation` and the surface attachment API do not exist.

- [ ] **Step 3: Implement the minimal contracts**

```swift
public struct PlaybackPresentation: Equatable, Sendable {
    public let resourceID: UUID
    public init(resourceID: UUID) { self.resourceID = resourceID }
}

@MainActor
public protocol PlaybackPresentationRegistry: AnyObject {
    func contains(resourceID: UUID) -> Bool
}

public protocol PlaybackResource: AnyObject, Sendable {
    var resourceID: UUID { get }
    func play() async throws
    func pause() async throws
    func release() async
}

public protocol PlayerFactory: Sendable {
    func makePlayer(for media: MediaItem) async throws -> any PlaybackResource
}

@MainActor
public protocol DesktopSurface: AnyObject {
    func show(frame: CGRect)
    func setPresentation(_ presentation: PlaybackPresentation?, fallbackURL: URL?)
    func close()
}
```

Update `PlayerPool.acquire`, `release`, and `setPaused` to await these operations. Update existing player and surface test doubles. Add `PlayerLease.presentation`, derived from its resource ID.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'PlaybackPresentationTests|PlayerPoolTests|DesktopWindowControllerTests'`

```bash
git add Sources/WallumeCore/Runtime/PlayerPool.swift Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift Tests/WallumeCoreTests
git commit -m "feat: add playback presentation contracts"
```

### Task 2: Implement muted looping AVFoundation resources

**Files:**

- Create: `Sources/WallumeCore/Runtime/AVFoundationPlayback.swift`
- Create: `Tests/WallumeCoreTests/AVFoundationPlaybackTests.swift`

**Interfaces:**

- Produces `AVFoundationPlayerFactory`, `AVPlayerPlaybackResource`, and `AVPlayerPresentationRegistry`
- The factory conforms to `PlayerFactory`
- The registry resolves shared players for AppKit presentation on the main actor

- [ ] **Step 1: Write failing factory tests**

```swift
@MainActor
func testFactoryCreatesMutedLoopingResourceRegisteredByID() async throws {
    let registry = AVPlayerPresentationRegistry()
    let factory = AVFoundationPlayerFactory(registry: registry)
    let media = MediaItem.fixture(variantURL: syntheticMovieURL)

    let resource = try await factory.makePlayer(for: media)

    XCTAssertTrue(registry.contains(resourceID: resource.resourceID))
    XCTAssertTrue(registry.player(resourceID: resource.resourceID)?.isMuted == true)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter AVFoundationPlaybackTests`

Expected: compilation fails because AVFoundation playback types do not exist.

- [ ] **Step 3: Implement player ownership**

Use one `AVQueuePlayer`, one template `AVPlayerItem`, and one retained `AVPlayerLooper` per resource. Set `isMuted = true`, `actionAtItemEnd = .advance`, and prevent external playback. `play()` starts playback, `pause()` pauses, and `release()` pauses, removes all items, invalidates the looper, and unregisters the resource.

If the variant URL is missing, not a regular file, or has no playable video track, throw before registry insertion. Use an injected validation closure in unit tests and a real AVAsset validator in production.

- [ ] **Step 4: Add cleanup and pool-sharing tests**

```swift
@MainActor
func testFinalPoolReleaseUnregistersSharedPlayer() async throws {
    let fixture = PlaybackFixture()
    let first = try await fixture.pool.acquire(media: fixture.media)
    _ = try await fixture.pool.acquire(media: fixture.media)

    await fixture.pool.release(mediaID: fixture.media.id)
    XCTAssertTrue(fixture.registry.contains(resourceID: first.resourceID))

    await fixture.pool.release(mediaID: fixture.media.id)
    XCTAssertFalse(fixture.registry.contains(resourceID: first.resourceID))
}
```

Run: `swift test --filter AVFoundationPlaybackTests && swift test --filter PlayerPoolTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore/Runtime/AVFoundationPlayback.swift Tests/WallumeCoreTests/AVFoundationPlaybackTests.swift
git commit -m "feat: add shared AVFoundation playback"
```

### Task 3: Bind shared players to desktop surfaces

**Files:**

- Modify: `Sources/WallumeCore/AppKitRuntime/AppKitDesktopSurface.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift`
- Modify: `Tests/WallumeCoreTests/AppKitDesktopSurfaceTests.swift`
- Modify: `Tests/WallumeCoreTests/DesktopWindowControllerTests.swift`

**Interfaces:**

- `AppKitDesktopSurface` consumes `PlaybackPresentationRegistry`
- `DesktopWindowController.apply(snapshot:mediaByID:)` binds each runtime session to its surface and registered cover URL

- [ ] **Step 1: Write the failing layer-binding test**

```swift
@MainActor
func testSurfaceUsesIndependentAspectFillLayerForSharedPlayer() {
    let registry = RecordingPresentationRegistry()
    let first = AppKitDesktopSurface(registry: registry)
    let second = AppKitDesktopSurface(registry: registry)
    let presentation = PlaybackPresentation(resourceID: registry.resourceID)

    first.setPresentation(presentation, fallbackURL: nil)
    second.setPresentation(presentation, fallbackURL: nil)

    XCTAssertEqual(first.videoGravity, .resizeAspectFill)
    XCTAssertEqual(second.videoGravity, .resizeAspectFill)
    XCTAssertNotEqual(first.presentationLayerIdentity, second.presentationLayerIdentity)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter AppKitDesktopSurfaceTests/testSurfaceUsesIndependentAspectFillLayerForSharedPlayer`

Expected: FAIL because the surface does not create or expose presentation-layer state.

- [ ] **Step 3: Implement binding and fallback**

Create one `AVPlayerLayer` per surface, attach the registry player, size it with the content view, and set `videoGravity = .resizeAspectFill`. On nil or unresolved presentation, remove the player and display the cover URL through an aspect-fill image layer when readable; otherwise keep the transparent empty surface. Closing a surface detaches both layers.

Add controller binding that matches `RuntimeSnapshot.sessions` by display ID, converts resource IDs to `PlaybackPresentation`, and supplies each media item's `coverURL`.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'AppKitDesktopSurfaceTests|DesktopWindowControllerTests'`

```bash
git add Sources/WallumeCore/AppKitRuntime Tests/WallumeCoreTests/AppKitDesktopSurfaceTests.swift Tests/WallumeCoreTests/DesktopWindowControllerTests.swift
git commit -m "feat: present shared players on desktop surfaces"
```

### Task 4: Monitor lock, sleep, and low-power pause causes

**Files:**

- Create: `Sources/WallumeCore/AppKitRuntime/RuntimeEnvironmentMonitor.swift`
- Create: `Tests/WallumeCoreTests/RuntimeEnvironmentMonitorTests.swift`

**Interfaces:**

- Produces `RuntimeEnvironmentMonitor`, `PowerStateProviding`, and `RuntimeEnvironmentSignals`
- Emits a complete `RuntimeEnvironment` after each state change

- [ ] **Step 1: Write the failing combined-reasons test**

```swift
@MainActor
func testUnlockDoesNotResumeWhileSystemStillSleeps() {
    let fixture = EnvironmentMonitorFixture()
    fixture.monitor.start { fixture.environments.append($0) }

    fixture.postLock()
    fixture.postSleep()
    fixture.postUnlock()

    XCTAssertEqual(fixture.environments.last?.pauseReasons, [.systemSleep])
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter RuntimeEnvironmentMonitorTests`

Expected: compilation fails because the monitor does not exist.

- [ ] **Step 3: Implement notification-driven signals**

Observe distributed session lock/unlock notifications, workspace sleep/wake notifications, and `NSProcessInfoPowerStateDidChange`. Read low-power state from injected `PowerStateProviding`. Maintain independent booleans and emit a complete environment after every actual transition. `stop()` removes all observers and emits nothing afterward.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter RuntimeEnvironmentMonitorTests`

```bash
git add Sources/WallumeCore/AppKitRuntime/RuntimeEnvironmentMonitor.swift Tests/WallumeCoreTests/RuntimeEnvironmentMonitorTests.swift
git commit -m "feat: monitor wallpaper pause signals"
```

### Task 5: Add isolated runtime verification and acceptance

**Files:**

- Modify: `Package.swift`
- Create: `Sources/WallumeRuntime/main.swift`
- Create: `docs/wallpaper-playback.md`
- Modify: `docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md`

**Interfaces:**

- Produces executable `wallume-runtime`
- Accepts `wallume-runtime <media-uuid>`, loads only the registered media item, creates desktop surfaces, and exits cleanly on SIGINT

- [ ] **Step 1: Add executable wiring**

Add a `wallume-runtime` executable target linked to `WallumeCore`. Its main actor constructs `MediaLibrary`, `AVPlayerPresentationRegistry`, `AVFoundationPlayerFactory`, `PlayerPool`, `RuntimeCoordinator`, `AppKitScreenProvider`, `DesktopWindowController`, and `RuntimeEnvironmentMonitor`.

Reject malformed or unregistered UUIDs before opening windows. Reconcile screen notifications and environment changes without polling. Keep playback muted and print structured failures to stderr.

- [ ] **Step 2: Document manual and performance acceptance**

Create sections: Scope, Muted looping playback, Shared-player presentation, Pause signals, Verification command, Manual matrix, Development-machine metrics, and Remaining phase-three gates.

Record actual test counts and state that foreground-obscuration pause plus base M1/macOS 14 performance approval remain.

- [ ] **Step 3: Run final verification**

Run: `swift test && swift build -c release --product wallume-runtime && swift build -c release --product wallume-media && swift build -c release --product wallume-restore && git diff --check`

Expected: all tests pass; all three executables build; whitespace check exits 0.

- [ ] **Step 4: Commit acceptance**

```bash
git add Package.swift Sources/WallumeRuntime docs
git commit -m "docs: complete wallpaper playback acceptance"
```

## Plan self-review

- Tasks 1–3 cover opaque presentation contracts, one muted looping player per media, independent aspect-fill layers, detach, and cover fallback.
- Task 4 covers lock, sleep, and low-power causes without polling.
- Task 5 supplies isolated runtime verification, documentation, and release builds.
- Volume UI, foreground obscuration, minimum-hardware approval, and remote push remain outside this plan.
