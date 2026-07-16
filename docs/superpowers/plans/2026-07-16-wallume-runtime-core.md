# Wallume runtime core implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a testable runtime core that assigns registered media to stable display sessions, shares playback resources, and pauses safely from environment signals.

**Architecture:** `WallumeCore/Runtime` contains Sendable values, injected catalog and player interfaces, and actor-owned state. `PlayerPool` owns resource reference counts. `RuntimeCoordinator` reconciles complete display snapshots and never exposes platform objects.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, XCTest, macOS 14.

## Global constraints

- Target Apple Silicon and macOS 14 or newer
- Do not add dependencies, windows, screen enumeration, AVFoundation playback, polling, or lock-screen writes
- Automated tests must not access real displays, media files, or wallpaper directories
- Share resources by `MediaItem.id`; verify the item through a catalog before acquiring its managed variant
- A failed media switch preserves the display's current session
- Follow TDD: observe each new test failing before production code, then rerun it green

## File structure

- `Sources/WallumeCore/Runtime/RuntimeModels.swift`: display IDs, assignments, pause reasons, sessions, snapshots, failures, catalog contract
- `Sources/WallumeCore/Runtime/PlayerPool.swift`: player contracts and reference-counted pool
- `Sources/WallumeCore/Runtime/RuntimeCoordinator.swift`: actor that reconciles display, assignment, and environment snapshots
- `Tests/WallumeCoreTests/RuntimeModelsTests.swift`: value-model tests
- `Tests/WallumeCoreTests/PlayerPoolTests.swift`: sharing, release, and pause tests
- `Tests/WallumeCoreTests/RuntimeCoordinatorTests.swift`: lifecycle, safety, failure isolation, and idempotence tests
- `docs/runtime-core.md`: runtime contract
- `docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md`: completion record

---

### Task 1: Define runtime values and the media catalog boundary

**Files:**

- Create: `Sources/WallumeCore/Runtime/RuntimeModels.swift`
- Create: `Tests/WallumeCoreTests/RuntimeModelsTests.swift`

**Interfaces:**

- Produces `DisplayID`, `RuntimeAssignment`, `RuntimePauseReason`, `RuntimeEnvironment`, `RuntimeFailure`, `RuntimeDisplaySession`, `RuntimeSnapshot`, and `MediaCatalog`
- `MediaCatalog` exposes `func item(id: UUID) throws -> MediaItem?`

- [ ] **Step 1: Write the failing tests**

```swift
func testEnvironmentCollectsEveryActivePauseReason() {
    let environment = RuntimeEnvironment(
        userPaused: true, appObscured: false, screenLocked: true,
        lowPowerMode: true, systemSleeping: false
    )

    XCTAssertEqual(environment.pauseReasons, [.user, .screenLocked, .lowPower])
}

func testSnapshotSortsSessionsByDisplayID() {
    let snapshot = RuntimeSnapshot(
        sessions: [
            .init(displayID: DisplayID("B"), mediaID: UUID(), resourceID: UUID()),
            .init(displayID: DisplayID("A"), mediaID: UUID(), resourceID: UUID()),
        ],
        resourceReferenceCounts: [:], pauseReasons: [], failures: [],
        resourceCreationCount: 0
    )

    XCTAssertEqual(snapshot.sessions.map(\.displayID), [DisplayID("A"), DisplayID("B")])
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter RuntimeModelsTests`

Expected: compilation fails because the runtime values do not exist.

- [ ] **Step 3: Implement the minimal value boundary**

```swift
import Foundation

public struct DisplayID: Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum RuntimePauseReason: String, CaseIterable, Hashable, Sendable {
    case user, appObscured, screenLocked, lowPower, systemSleep
}

public struct RuntimeEnvironment: Equatable, Sendable {
    public let pauseReasons: Set<RuntimePauseReason>
    public init(userPaused: Bool, appObscured: Bool, screenLocked: Bool, lowPowerMode: Bool, systemSleeping: Bool) {
        pauseReasons = Set([
            userPaused ? .user : nil, appObscured ? .appObscured : nil,
            screenLocked ? .screenLocked : nil, lowPowerMode ? .lowPower : nil,
            systemSleeping ? .systemSleep : nil,
        ].compactMap { $0 })
    }
    public static let active = RuntimeEnvironment(
        userPaused: false, appObscured: false, screenLocked: false,
        lowPowerMode: false, systemSleeping: false
    )
}

public protocol MediaCatalog: Sendable {
    func item(id: UUID) throws -> MediaItem?
}
```

Add `RuntimeAssignment(displayID:mediaID:)`, `RuntimeFailure(displayID:mediaID:message:)`, `RuntimeDisplaySession(displayID:mediaID:resourceID:)`, and `RuntimeSnapshot`. Make each `Sendable` and `Equatable`; also make `RuntimeAssignment` `Hashable` because reconciliation accepts a set of assignments. The snapshot initializer sorts sessions and failures by display ID.

- [ ] **Step 4: Verify green**

Run: `swift test --filter RuntimeModelsTests`

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore/Runtime/RuntimeModels.swift Tests/WallumeCoreTests/RuntimeModelsTests.swift
git commit -m "feat: add runtime models"
```

### Task 2: Add the shared playback-resource pool

**Files:**

- Create: `Sources/WallumeCore/Runtime/PlayerPool.swift`
- Create: `Tests/WallumeCoreTests/PlayerPoolTests.swift`

**Interfaces:**

- Produces `PlaybackResource`, `PlayerFactory`, `PlayerLease`, `PlayerPoolSnapshot`, and `PlayerPool`
- `PlayerPool` exposes `acquire(media:)`, `release(mediaID:)`, `setPaused(_:)`, and `snapshot()`

- [ ] **Step 1: Write the failing sharing test**

```swift
func testSameMediaSharesOneResourceUntilLastLeaseReleases() async throws {
    let factory = RecordingPlayerFactory()
    let pool = PlayerPool(factory: factory)
    let media = MediaItem.fixture()

    let first = try await pool.acquire(media: media)
    let second = try await pool.acquire(media: media)
    await pool.release(mediaID: media.id)

    XCTAssertEqual(first.resourceID, second.resourceID)
    XCTAssertEqual(factory.createdIDs.count, 1)
    XCTAssertTrue(factory.releasedIDs.isEmpty)

    await pool.release(mediaID: media.id)
    XCTAssertEqual(factory.releasedIDs, [first.resourceID])
}
```

Make the recording player/factory test doubles `@unchecked Sendable` only after their recorded state is protected by `NSLock`.

- [ ] **Step 2: Verify red**

Run: `swift test --filter PlayerPoolTests/testSameMediaSharesOneResourceUntilLastLeaseReleases`

Expected: compilation fails because `PlayerPool` does not exist.

- [ ] **Step 3: Implement resource ownership**

```swift
public protocol PlaybackResource: AnyObject, Sendable {
    var resourceID: UUID { get }
    func play() throws
    func pause() throws
    func release()
}

public protocol PlayerFactory: Sendable {
    func makePlayer(for media: MediaItem) throws -> any PlaybackResource
}

public struct PlayerLease: Sendable, Equatable {
    public let mediaID: UUID
    public let resourceID: UUID
}

public actor PlayerPool {
    public init(factory: any PlayerFactory)
    public func acquire(media: MediaItem) throws -> PlayerLease
    public func release(mediaID: UUID)
    public func setPaused(_ paused: Bool)
    public func snapshot() -> PlayerPoolSnapshot
}
```

Store each resource with a reference count. A new resource calls `play()` unless paused. `setPaused` invokes `pause()` or `play()` only on a state transition. Failed creation or start must not add a resource.

- [ ] **Step 4: Add pause behavior and verify green**

```swift
func testRepeatedPauseDoesNotRepeatResourceCommands() async throws {
    let factory = RecordingPlayerFactory()
    let pool = PlayerPool(factory: factory)
    _ = try await pool.acquire(media: .fixture())

    await pool.setPaused(true)
    await pool.setPaused(true)
    await pool.setPaused(false)

    XCTAssertEqual(factory.pauseCallCount, 1)
    XCTAssertEqual(factory.playCallCount, 2)
}
```

Run: `swift test --filter PlayerPoolTests`

Expected: all pool tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore/Runtime/PlayerPool.swift Tests/WallumeCoreTests/PlayerPoolTests.swift
git commit -m "feat: share runtime playback resources"
```

### Task 3: Reconcile display sessions safely

**Files:**

- Create: `Sources/WallumeCore/Runtime/RuntimeCoordinator.swift`
- Create: `Tests/WallumeCoreTests/RuntimeCoordinatorTests.swift`

**Interfaces:**

- Consumes `MediaCatalog`, `PlayerPool`, `DisplayID`, `RuntimeAssignment`, and `RuntimeEnvironment`
- Produces `RuntimeCoordinator.reconcile(displays:assignments:environment:) async -> RuntimeSnapshot`

- [ ] **Step 1: Write the failing lifecycle test**

```swift
func testRemovingDisplayReleasesItsOnlyResource() async throws {
    let fixture = RuntimeFixture(items: [.fixture()])
    let display = DisplayID("display-1")

    _ = await fixture.coordinator.reconcile(
        displays: [display],
        assignments: [.init(displayID: display, mediaID: fixture.item.id)],
        environment: .active
    )
    let snapshot = await fixture.coordinator.reconcile(
        displays: [], assignments: [], environment: .active
    )

    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertTrue(snapshot.resourceReferenceCounts.isEmpty)
    XCTAssertEqual(fixture.factory.releasedIDs.count, 1)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter RuntimeCoordinatorTests/testRemovingDisplayReleasesItsOnlyResource`

Expected: compilation fails because `RuntimeCoordinator` does not exist.

- [ ] **Step 3: Implement safe reconciliation**

```swift
public actor RuntimeCoordinator {
    public init(catalog: any MediaCatalog, pool: PlayerPool)

    public func reconcile(
        displays: Set<DisplayID>,
        assignments: Set<RuntimeAssignment>,
        environment: RuntimeEnvironment
    ) async -> RuntimeSnapshot
}
```

Remove sessions whose display no longer exists. Process assignments in `DisplayID` order. For a changed assignment, look up its item and acquire its new lease before replacing the old session. If lookup returns nil or acquire throws, append `RuntimeFailure` and leave the old session untouched. On success, store the new session and then release the old media lease. Ignore absent-display assignments; return a failure for duplicate assignments targeting one display.

- [ ] **Step 4: Add isolation and sharing tests**

```swift
func testFailedSwitchPreservesItsSessionAndOtherDisplays() async throws {
    let fixture = RuntimeFixture(items: [.fixture(named: "old"), .fixture(named: "other")])
    let first = DisplayID("first")
    let second = DisplayID("second")
    await fixture.assign(first, fixture.items[0].id)
    await fixture.assign(second, fixture.items[1].id)

    let snapshot = await fixture.assign(first, UUID())

    XCTAssertEqual(snapshot.sessions.first { $0.displayID == first }?.mediaID, fixture.items[0].id)
    XCTAssertEqual(snapshot.sessions.first { $0.displayID == second }?.mediaID, fixture.items[1].id)
    XCTAssertEqual(snapshot.failures.map(\.displayID), [first])
}
```

Run: `swift test --filter RuntimeCoordinatorTests`

Expected: lifecycle, shared-media, failed-switch, and duplicate-assignment tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore/Runtime/RuntimeCoordinator.swift Tests/WallumeCoreTests/RuntimeCoordinatorTests.swift
git commit -m "feat: reconcile runtime display sessions"
```

### Task 4: Apply pause causes and prove idempotence

**Files:**

- Modify: `Sources/WallumeCore/Runtime/RuntimeCoordinator.swift`
- Modify: `Tests/WallumeCoreTests/RuntimeCoordinatorTests.swift`

**Interfaces:**

- Snapshots report pause causes, resource counts, session count, creation count, and failures
- `reconcile` performs no player calls for an identical input snapshot

- [ ] **Step 1: Write the failing policy tests**

```swift
func testPauseRequiresEveryReasonToClearBeforeResume() async throws {
    let fixture = RuntimeFixture(items: [.fixture()])
    let display = DisplayID("display-1")
    await fixture.assign(
        display, fixture.item.id,
        environment: .init(userPaused: true, appObscured: false, screenLocked: true, lowPowerMode: false, systemSleeping: false)
    )

    let paused = await fixture.snapshot(
        environment: .init(userPaused: false, appObscured: false, screenLocked: true, lowPowerMode: false, systemSleeping: false)
    )
    let resumed = await fixture.snapshot(environment: .active)

    XCTAssertEqual(paused.pauseReasons, [.screenLocked])
    XCTAssertEqual(fixture.factory.pauseCallCount, 1)
    XCTAssertEqual(resumed.pauseReasons, [])
    XCTAssertEqual(fixture.factory.playCallCount, 2)
}

func testRepeatingSameSnapshotCreatesNoResourceOrPlayerCommands() async throws {
    let fixture = RuntimeFixture(items: [.fixture()])
    let first = await fixture.assign(DisplayID("display-1"), fixture.item.id)
    let second = await fixture.assign(DisplayID("display-1"), fixture.item.id)

    XCTAssertEqual(first, second)
    XCTAssertEqual(fixture.factory.createdIDs.count, 1)
    XCTAssertEqual(fixture.factory.playCallCount, 1)
}
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter RuntimeCoordinatorTests/testPauseRequiresEveryReasonToClearBeforeResume`

Expected: FAIL because the coordinator does not yet forward the environment state to the pool.

- [ ] **Step 3: Implement pause propagation**

After session changes, call `await pool.setPaused(!environment.pauseReasons.isEmpty)`. Build each snapshot from sorted sessions, `await pool.snapshot()`, current reasons, and failures sorted by display ID. Do not call the pool when an existing display keeps the same media ID.

- [ ] **Step 4: Verify focused and full suites**

Run: `swift test --filter RuntimeCoordinatorTests && swift test && swift build -c release && git diff --check`

Expected: all runtime and existing tests pass, release build completes without warnings, and the whitespace check exits 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore/Runtime/RuntimeCoordinator.swift Tests/WallumeCoreTests/RuntimeCoordinatorTests.swift
git commit -m "feat: add runtime pause policy"
```

### Task 5: Document the runtime contract and acceptance

**Files:**

- Create: `docs/runtime-core.md`
- Modify: `docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md`

**Interfaces:**

- Documents input snapshots, sharing, pause reasons, failure isolation, platform boundary, and performance handoff

- [ ] **Step 1: Document the implemented contract**

Create `docs/runtime-core.md` with sections named `Scope`, `Inputs and outputs`, `Resource sharing`, `Pause policy`, `Failure behavior`, `Platform adapter boundary`, and `Performance measurement handoff`. State that runtime-core tests do not open windows, enumerate live displays, or play real media.

- [ ] **Step 2: Record phase-three progress**

Add a completed runtime-core entry and the final `swift test` count to the progress document. State that AppKit windows, actual screen observation, AVFoundation adapters, and M1/macOS 14 performance measurements remain the next batch.

- [ ] **Step 3: Run final acceptance**

Run: `swift test && swift build -c release --product wallume-media && swift build -c release --product wallume-restore && git diff --check`

Expected: all tests pass, both executable products build, and the whitespace check exits 0.

- [ ] **Step 4: Commit**

```bash
git add docs/runtime-core.md docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md
git commit -m "docs: complete runtime core acceptance"
```

## Plan self-review

- Spec coverage: Tasks 1–4 implement stable display sessions, catalog validation, shared resources, pause causes, failure isolation, idempotence, and observable metrics. Task 5 records platform and performance limits.
- Placeholder scan: no unresolved requirements remain; each production step has exact files, interfaces, behavior, a red command, and a green command.
- Type consistency: models precede their consumers. The pool returns `PlayerLease`; sessions retain its `resourceID` and release by `mediaID`.
