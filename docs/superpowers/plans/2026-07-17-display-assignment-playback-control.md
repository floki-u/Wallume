# Display Assignment and Playback Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect Wallume's tested runtime core to the application shell with stable display discovery, persistent multi-display wallpaper assignment, three presentation modes, and global pause/resume.

**Architecture:** `WallumeApp` owns one in-process `WallpaperRuntimeService` that reconciles complete display, assignment, and environment snapshots through the existing runtime coordinator and shared player pool. `WallumeAppSupport` owns a versioned assignment store and observable display/playback models; SwiftUI and the status item submit commands to those models rather than manipulating AppKit runtime objects directly.

**Tech Stack:** Swift 6, macOS 14+, SwiftUI Observation, AppKit, CoreGraphics, AVFoundation, Swift Package Manager, XCTest.

## Global Constraints

- Playback remains muted; this batch adds no volume controls.
- The wallpaper UI uses an in-process runtime; `wallume-runtime` remains a standalone diagnostic and benchmark executable.
- Display assignment supports multiple selected connected displays and Select All.
- Playback pause/resume is global, while presentation mode is independently stored per display.
- Presentation modes are Fill, Fit, and Stretch; Fill is the default.
- Disconnected display assignments are retained and automatically restored on reconnect.
- Closing the main window must not stop wallpaper playback; formal application termination must release runtime resources.
- Corrupt or unsupported assignment data fails closed and is never overwritten automatically.
- Hardware performance certification remains deferred and does not block this batch's engineering completion.

---

## File Structure

### WallumeCore

- `Sources/WallumeCore/Runtime/RuntimeModels.swift`: presentation-mode value and existing runtime snapshot types.
- `Sources/WallumeCore/Runtime/RuntimeCoordinator.swift`: remove stale sessions when assignments disappear and expose ordered shutdown.
- `Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift`: enriched display metadata and presentation-mode-aware surface contract.
- `Sources/WallumeCore/AppKitRuntime/AppKitScreenProvider.swift`: stable CoreGraphics display identity and metadata extraction.
- `Sources/WallumeCore/AppKitRuntime/AppKitDesktopSurface.swift`: map Fill/Fit/Stretch to AVFoundation and Core Animation gravity.
- `Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift`: apply per-display presentation mode and close all surfaces.

### WallumeAppSupport

- `Sources/WallumeAppSupport/Displays/DisplayAssignmentModels.swift`: versioned persisted document, entries, snapshots, and errors.
- `Sources/WallumeAppSupport/Displays/DisplayAssignmentStore.swift`: serialized load and atomic assignment mutations.
- `Sources/WallumeAppSupport/Displays/DisplayCatalog.swift`: join connected screens with remembered records.
- `Sources/WallumeAppSupport/Displays/DisplayFeatureStore.swift`: observable display cards, selection, assignment, removal, mode, pause, and error state.
- `Sources/WallumeAppSupport/Runtime/WallpaperRuntimeService.swift`: application-owned AppKit/runtime orchestration.
- `Sources/WallumeAppSupport/Gallery/PersistedMediaUsageChecker.swift`: read the shared versioned assignment schema.
- `Sources/WallumeAppSupport/UI/DisplaysView.swift`: online/offline display cards and commands.
- `Sources/WallumeAppSupport/UI/DisplaySelectorView.swift`: multi-select assignment sheet.
- `Sources/WallumeAppSupport/UI/MediaDetailView.swift`: Set as Wallpaper action.
- `Sources/WallumeAppSupport/UI/GalleryView.swift`: present the selector and refresh usage state.
- `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`: enable Displays and expose global playback control.
- `Sources/WallumeAppSupport/AppKit/StatusItemController.swift`: merge import and playback state in one menu.

### WallumeApp

- `Sources/WallumeApp/ApplicationController.swift`: production dependency composition, launch, observation, and ordered termination.

---

### Task 1: Runtime assignment removal and presentation contract

**Files:**
- Modify: `Sources/WallumeCore/Runtime/RuntimeModels.swift`
- Modify: `Sources/WallumeCore/Runtime/RuntimeCoordinator.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/AppKitDesktopSurface.swift`
- Test: `Tests/WallumeCoreTests/RuntimeCoordinatorTests.swift`
- Test: `Tests/WallumeCoreTests/DesktopWindowControllerTests.swift`
- Test: `Tests/WallumeCoreTests/AppKitDesktopSurfaceTests.swift`

**Interfaces:**
- Produces: `WallpaperPresentationMode`, `RuntimeCoordinator.shutdown()`, `DesktopWindowController.closeAll()`, and `DesktopSurface.setPresentation(_:fallbackURL:mode:)`.
- Consumes: existing `RuntimeAssignment`, `RuntimeSnapshot`, `PlaybackPresentation`, and shared `PlayerPool`.

- [ ] **Step 1: Add failing runtime and surface tests**

```swift
func testRemovingAssignmentReleasesSessionWhileDisplayRemains() async {
    _ = await coordinator.reconcile(
        displays: [DisplayID("one")],
        assignments: [RuntimeAssignment(displayID: DisplayID("one"), mediaID: media.id)],
        environment: .active
    )
    let snapshot = await coordinator.reconcile(
        displays: [DisplayID("one")], assignments: [], environment: .active
    )
    XCTAssertTrue(snapshot.sessions.isEmpty)
    XCTAssertTrue(snapshot.resourceReferenceCounts.isEmpty)
}

func testWindowControllerAppliesIndependentPresentationModes() {
    controller.reconcile([screenOne, screenTwo])
    controller.apply(
        snapshot: snapshot,
        mediaByID: [media.id: media],
        modesByDisplay: [screenOne.id: .fit, screenTwo.id: .stretch]
    )
    XCTAssertEqual(factory.surfaces[screenOne.id]?.mode, .fit)
    XCTAssertEqual(factory.surfaces[screenTwo.id]?.mode, .stretch)
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `swift test --filter 'RuntimeCoordinatorTests|DesktopWindowControllerTests|AppKitDesktopSurfaceTests'`

Expected: compilation fails because `WallpaperPresentationMode`, mode-aware presentation, and shutdown APIs do not exist; the stale-assignment assertion also fails on the current coordinator.

- [ ] **Step 3: Implement the runtime contract**

```swift
public enum WallpaperPresentationMode: String, Codable, CaseIterable, Sendable {
    case fill, fit, stretch
}

// Add this case to the existing RuntimePauseReason enum.
case thermalPressure

@MainActor
public protocol DesktopSurface: AnyObject {
    func show(frame: CGRect)
    func setPresentation(
        _ presentation: PlaybackPresentation?,
        fallbackURL: URL?,
        mode: WallpaperPresentationMode
    )
    func close()
}
```

In `RuntimeCoordinator.reconcile`, calculate assigned display IDs and release any session whose display disappeared **or** no longer has one valid assignment. Add `shutdown()` that releases every session and returns an empty snapshot. In `DesktopWindowController`, pass `modesByDisplay[displayID] ?? .fill`, and add `closeAll()`.

Map modes in `AppKitDesktopSurface`:

```swift
private func videoGravity(for mode: WallpaperPresentationMode) -> AVLayerVideoGravity {
    switch mode {
    case .fill: .resizeAspectFill
    case .fit: .resizeAspect
    case .stretch: .resize
    }
}
```

Use matching `CALayerContentsGravity` values for fallback covers.
Extend `RuntimeEnvironment` with thermal pressure while preserving its existing
initializer through a defaulted `thermalPressure: Bool = false` argument.

- [ ] **Step 4: Run focused and full core tests**

Run: `swift test --filter 'RuntimeCoordinatorTests|DesktopWindowControllerTests|AppKitDesktopSurfaceTests'`

Expected: all selected tests pass.

Run: `swift test --filter WallumeCoreTests`

Expected: all core tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore Tests/WallumeCoreTests
git commit -m "feat: support per-display wallpaper presentation"
```

### Task 2: Stable display identity and metadata

**Files:**
- Modify: `Sources/WallumeCore/AppKitRuntime/DesktopSurfaceModels.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/AppKitScreenProvider.swift`
- Test: `Tests/WallumeCoreTests/DesktopSurfaceModelsTests.swift`
- Test: `Tests/WallumeCoreTests/AppKitDesktopSurfaceTests.swift`

**Interfaces:**
- Produces: enriched `DesktopScreen` and injectable `DisplayIdentityProviding`.
- Consumes: `DisplayID` and CoreGraphics `CGDirectDisplayID` values from `NSScreenNumber`.

- [ ] **Step 1: Write failing identity tests**

```swift
func testDesktopScreenCarriesPersistentDisplayMetadata() {
    let screen = DesktopScreen(
        id: DisplayID("cg:uuid"), frame: .zero, name: "Studio Display",
        pixelWidth: 5120, pixelHeight: 2880, isMain: true,
        identityPersistence: .persistent
    )
    XCTAssertEqual(screen.name, "Studio Display")
    XCTAssertTrue(screen.isMain)
    XCTAssertEqual(screen.identityPersistence, .persistent)
}

func testFallbackIdentityIsNamespacedAndNonpersistent() {
    let identity = DisplayIdentity.fallback(directDisplayID: 42)
    XCTAssertEqual(identity.id, DisplayID("cg-direct:42"))
    XCTAssertEqual(identity.persistence, .connectionOnly)
}
```

- [ ] **Step 2: Run tests and verify compilation failure**

Run: `swift test --filter 'DesktopSurfaceModelsTests|AppKitDesktopSurfaceTests'`

Expected: failure because display metadata and persistence types are absent.

- [ ] **Step 3: Implement identity mapping and screen metadata**

```swift
public enum DisplayIdentityPersistence: String, Codable, Sendable {
    case persistent, connectionOnly
}

public struct DisplayIdentity: Equatable, Sendable {
    public let id: DisplayID
    public let persistence: DisplayIdentityPersistence

    public static func fallback(directDisplayID: UInt32) -> Self {
        .init(id: DisplayID("cg-direct:\(directDisplayID)"), persistence: .connectionOnly)
    }
}
```

Production identity uses `CGDisplayCreateUUIDFromDisplayID`, prefixed with `cg-uuid:`. Populate localized name, backing pixel dimensions, main-display status, and frame. Keep the existing notification-based provider lifecycle and deterministic ID sorting.

- [ ] **Step 4: Run focused tests and `wallume-runtime` build**

Run: `swift test --filter 'DesktopSurfaceModelsTests|AppKitDesktopSurfaceTests'`

Expected: pass.

Run: `swift build -c release --product wallume-runtime`

Expected: release build succeeds with the enriched `DesktopScreen` initializer updated in the runtime entry point and tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeCore Tests/WallumeCoreTests Sources/WallumeRuntime/main.swift
git commit -m "feat: identify displays across reconnects"
```

### Task 3: Versioned assignment persistence and migration

**Files:**
- Create: `Sources/WallumeAppSupport/Displays/DisplayAssignmentModels.swift`
- Create: `Sources/WallumeAppSupport/Displays/DisplayAssignmentStore.swift`
- Modify: `Sources/WallumeAppSupport/Gallery/PersistedMediaUsageChecker.swift`
- Test: `Tests/WallumeAppSupportTests/DisplayAssignmentStoreTests.swift`
- Modify: `Tests/WallumeAppSupportTests/GalleryStoreTests.swift`

**Interfaces:**
- Produces: `DisplayAssignmentDocument`, `PersistedDisplayRecord`, `DisplayAssignmentSnapshot`, and actor `DisplayAssignmentStore`.
- Consumes: `AtomicJSONStore`, `FileStore`, `MediaLibraryManaging`, `WallpaperPresentationMode`, and enriched `DesktopScreen`.

- [ ] **Step 1: Add failing document/store tests**

```swift
func testMigratesVersionOneAssignmentsToFillMode() async throws {
    files.seed(url, json: #"{"schemaVersion":1,"assignments":[{"displayID":"one","displayName":"Studio","mediaID":"00000000-0000-0000-0000-000000000001"}]}"#)
    let snapshot = try await store.load()
    XCTAssertEqual(snapshot.records.first?.presentationMode, .fill)
    XCTAssertFalse(snapshot.userPaused)
}

func testBatchAssignmentIsOneAtomicMutation() async throws {
    try await store.assign(mediaID: media.id, to: [screenOne, screenTwo])
    let snapshot = await store.snapshot()
    XCTAssertEqual(Set(snapshot.records.compactMap(\.mediaID)), [media.id])
    XCTAssertEqual(files.atomicWriteCount, 1)
}

func testWriteFailurePreservesPriorSnapshot() async throws {
    try await store.assign(mediaID: first.id, to: [screenOne])
    files.failNextAtomicWrite()
    await XCTAssertThrowsErrorAsync { try await store.assign(mediaID: second.id, to: [screenOne]) }
    XCTAssertEqual(await store.snapshot().records.first?.mediaID, first.id)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter DisplayAssignmentStoreTests`

Expected: compilation fails because the models and store do not exist.

- [ ] **Step 3: Implement the versioned store**

```swift
public struct PersistedDisplayRecord: Codable, Equatable, Sendable {
    public var displayID: String
    public var displayName: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var wasMain: Bool
    public var identityPersistence: DisplayIdentityPersistence
    public var mediaID: UUID?
    public var presentationMode: WallpaperPresentationMode
}

public struct DisplayAssignmentDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var userPaused: Bool
    public var displays: [PersistedDisplayRecord]
}

public actor DisplayAssignmentStore {
    public func load() throws -> DisplayAssignmentSnapshot
    public func snapshot() -> DisplayAssignmentSnapshot
    public func assign(mediaID: UUID, to screens: [DesktopScreen]) throws
    public func removeAssignment(displayID: DisplayID) throws
    public func clearRememberedDisplay(displayID: DisplayID) throws
    public func setPresentationMode(_ mode: WallpaperPresentationMode, displayID: DisplayID) throws
    public func setUserPaused(_ paused: Bool) throws
    public func events() -> AsyncStream<DisplayAssignmentSnapshot>
}
```

Decode schema 1 through a private legacy document type and convert each entry to a persistent record with zero unknown dimensions, `wasMain == false`, `.fill`, and `userPaused == false`. Reject unsupported schema versions and malformed data without writing. Build the candidate snapshot in memory, write it atomically, then publish it only after the write succeeds. Validate nonempty unique targets. A connection-only identity may run during the current application session, but it is excluded from the durable document and is never joined to a remembered persistent record after relaunch.

Update `PersistedMediaUsageChecker` to decode both schema versions through the shared loader and return a configuration-error reference on any failure.

- [ ] **Step 4: Run assignment and gallery tests**

Run: `swift test --filter 'DisplayAssignmentStoreTests|GalleryStoreTests'`

Expected: migration, atomic mutation, corruption, and deletion-reference tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeAppSupport/Displays Sources/WallumeAppSupport/Gallery/PersistedMediaUsageChecker.swift Tests/WallumeAppSupportTests
git commit -m "feat: persist display wallpaper assignments"
```

### Task 4: Display catalog and observable feature state

**Files:**
- Create: `Sources/WallumeAppSupport/Displays/DisplayCatalog.swift`
- Create: `Sources/WallumeAppSupport/Displays/DisplayFeatureStore.swift`
- Test: `Tests/WallumeAppSupportTests/DisplayCatalogTests.swift`
- Test: `Tests/WallumeAppSupportTests/DisplayFeatureStoreTests.swift`

**Interfaces:**
- Produces: `DisplayRecord`, `DisplayCatalog.merge(connected:remembered:)`, `DisplayCardState`, and `DisplayFeatureStore`.
- Consumes: assignment-store snapshots, current `DesktopScreen` values, media library items, and runtime result snapshots supplied later by `WallpaperRuntimeService`.

- [ ] **Step 1: Add failing catalog and command-state tests**

```swift
func testCatalogRetainsOfflineRecordAndRestoresConnectedMetadata() {
    let records = DisplayCatalog.merge(connected: [currentStudio], remembered: [rememberedStudio, rememberedProjector])
    XCTAssertEqual(records.map(\.connection), [.connected, .disconnected])
    XCTAssertEqual(records.first?.pixelWidth, currentStudio.pixelWidth)
}

@MainActor
func testFeatureStoreExposesOnlyConnectedAssignmentTargets() {
    store.update(catalog: [online, offline], assignments: snapshot, media: [ocean])
    XCTAssertEqual(store.assignmentTargets.map(\.id), [online.id])
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter 'DisplayCatalogTests|DisplayFeatureStoreTests'`

Expected: compilation fails because catalog and feature-store types are absent.

- [ ] **Step 3: Implement pure merge and observable state**

```swift
public enum DisplayConnection: Sendable { case connected, disconnected }

public struct DisplayRecord: Identifiable, Equatable, Sendable {
    public let id: DisplayID
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool
    public let identityPersistence: DisplayIdentityPersistence
    public let connection: DisplayConnection
}

@MainActor @Observable
public final class DisplayFeatureStore {
    public private(set) var cards: [DisplayCardState] = []
    public private(set) var assignmentTargets: [DisplayRecord] = []
    public private(set) var userPaused = false
    public private(set) var effectivePauseReasons: Set<RuntimePauseReason> = []
    public private(set) var pageError: String?
    public var selectedMediaForAssignment: MediaItem?

    public func assign(mediaID: UUID, displayIDs: Set<DisplayID>)
    public func removeAssignment(displayID: DisplayID)
    public func clearRememberedDisplay(displayID: DisplayID)
    public func setPresentationMode(_ mode: WallpaperPresentationMode, displayID: DisplayID)
    public func setUserPaused(_ paused: Bool)
    public func retry(displayID: DisplayID)
}
```

Inject narrow async command closures for assign, remove, clear, set mode, set pause, and retry. Keep all joining and sorting deterministic: connected before disconnected, main display first within connected records, then localized name and ID. A failed command stores an actionable card or page error and leaves the prior snapshot visible.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter 'DisplayCatalogTests|DisplayFeatureStoreTests'`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeAppSupport/Displays Tests/WallumeAppSupportTests/DisplayCatalogTests.swift Tests/WallumeAppSupportTests/DisplayFeatureStoreTests.swift
git commit -m "feat: model connected and remembered displays"
```

### Task 5: In-process wallpaper runtime service

**Files:**
- Create: `Sources/WallumeAppSupport/Runtime/WallpaperRuntimeService.swift`
- Test: `Tests/WallumeAppSupportTests/WallpaperRuntimeServiceTests.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift`

**Interfaces:**
- Produces: `WallpaperRuntimeService.start(assignments:)`, `apply(assignments:)`, `retry()`, `stop()`, and `events()`.
- Consumes: `DesktopScreenProvider`, `RuntimeEnvironmentMonitor`, `WindowOcclusionMonitor`, `RuntimeCoordinator`, `DesktopWindowController`, media catalog, and assignment snapshots.

- [ ] **Step 1: Add failing lifecycle and reconcile tests**

```swift
@MainActor
func testStartRestoresAssignmentsAndSharedPlayer() async {
    service.start(assignments: twoDisplaysOneMedia)
    await service.waitForIdle()
    XCTAssertEqual(runtime.latest.sessions.count, 2)
    XCTAssertEqual(runtime.latest.resourceCreationCount, 1)
}

@MainActor
func testDisconnectedDisplayClosesSurfaceWithoutDeletingAssignment() async {
    screens.value = [screenOne]
    screens.sendChange()
    await service.waitForIdle()
    XCTAssertEqual(windows.openDisplayIDs, [screenOne.id])
    XCTAssertEqual(service.assignments.records.count, 2)
}

@MainActor
func testStopOrdersObserversWindowsAndPlayers() async {
    await service.stop()
    XCTAssertEqual(recorder.events, ["screens.stop", "environment.stop", "occlusion.stop", "windows.closeAll", "runtime.shutdown"])
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter WallpaperRuntimeServiceTests`

Expected: compilation fails because the service is absent.

- [ ] **Step 3: Implement coalesced application-owned reconciliation**

```swift
@MainActor
public final class WallpaperRuntimeService {
    public func start(assignments: DisplayAssignmentSnapshot)
    public func apply(assignments: DisplayAssignmentSnapshot)
    public func retry()
    public func stop() async
    public func events() -> AsyncStream<WallpaperRuntimeSnapshot>
    public func waitForIdle() async
}
```

Keep the latest complete assignment and environment snapshots. Coalesce notifications into one main-actor task, derive connected display IDs and valid assignments, fetch referenced media, call `windows.reconcile`, `runtime.reconcile`, and `windows.apply` with per-display modes, then publish merged runtime/window failures. Preserve the `.user` reason while replacing transient environment reasons. `stop()` prevents new scheduling before ordered cleanup.

Extend `RuntimeEnvironmentMonitor` to observe `ProcessInfo.thermalState` changes.
Treat `.serious` and `.critical` as `.thermalPressure`; treat `.nominal` and
`.fair` as active playback. Add monitor tests that post
`.NSProcessInfoThermalStateDidChange` through the injected notification center.

- [ ] **Step 4: Run runtime-service and core runtime tests**

Run: `swift test --filter 'WallpaperRuntimeServiceTests|RuntimeCoordinatorTests|DesktopWindowControllerTests'`

Expected: all selected tests pass, including failure isolation and idempotent retry.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeAppSupport/Runtime Sources/WallumeCore/AppKitRuntime/DesktopWindowController.swift Tests/WallumeAppSupportTests/WallpaperRuntimeServiceTests.swift
git commit -m "feat: run wallpapers inside the application"
```

### Task 6: Displays page and presentation controls

**Files:**
- Create: `Sources/WallumeAppSupport/UI/DisplaysView.swift`
- Modify: `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`
- Modify: `Sources/WallumeAppSupport/UI/FeatureRegistry.swift`
- Test: `Tests/WallumeAppSupportTests/DisplaysViewTests.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift`

**Interfaces:**
- Produces: `DisplaysView` and enabled `.displays` shell route.
- Consumes: `DisplayFeatureStore.cards` and its remove, clear, mode, retry, and pause commands.

- [ ] **Step 1: Write failing UI state and render tests**

```swift
func testDisplaysFeatureIsEnabled() {
    XCTAssertTrue(FeatureRegistry.features.first { $0.id == .displays }?.isEnabled == true)
}

@MainActor
func testDisplaysViewRendersOnlineAndOfflineCards() {
    let store = DisplayFeatureStore.fixture(cards: [.onlineAssigned, .offlineAssigned])
    let host = NSHostingView(rootView: DisplaysView(store: store))
    XCTAssertGreaterThan(host.fittingSize.height, 0)
    XCTAssertEqual(store.cards.map(\.connection), [.connected, .disconnected])
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter 'DisplaysViewTests|ApplicationShellViewTests'`

Expected: compilation fails because `DisplaysView` is absent and the Displays feature is disabled.

- [ ] **Step 3: Implement display cards and shell route**

Create a scrollable `LazyVStack` of cards. Each card renders name, online/offline badge, main-display badge, resolution, assigned thumbnail/name or unassigned state, Replace, Remove, mode `Picker`, and a card error with Retry. Disable runtime controls offline and show Clear Saved Configuration. Add a page-level error alert.

Update the shell initializer to accept `DisplayFeatureStore`; route `.displays` to `DisplaysView`, keep the other future modules unavailable, and place the shared pause button in the toolbar:

```swift
.toolbar {
    ToolbarItem {
        Button(store.userPaused ? "继续播放" : "暂停播放") {
            store.setUserPaused(!store.userPaused)
        }
    }
}
```

If only a system pause reason is active, show the reason and do not label the action as a successful resume.

- [ ] **Step 4: Run UI tests**

Run: `swift test --filter 'DisplaysViewTests|ApplicationShellViewTests'`

Expected: render and state tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeAppSupport/UI Tests/WallumeAppSupportTests/DisplaysViewTests.swift Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift
git commit -m "feat: add display wallpaper controls"
```

### Task 7: Gallery multi-display assignment sheet

**Files:**
- Create: `Sources/WallumeAppSupport/UI/DisplaySelectorView.swift`
- Modify: `Sources/WallumeAppSupport/UI/MediaDetailView.swift`
- Modify: `Sources/WallumeAppSupport/UI/GalleryView.swift`
- Modify: `Sources/WallumeAppSupport/Gallery/GalleryStore.swift`
- Test: `Tests/WallumeAppSupportTests/DisplaySelectorViewTests.swift`
- Modify: `Tests/WallumeAppSupportTests/AppKitShellTests.swift`
- Modify: `Tests/WallumeAppSupportTests/GalleryStoreTests.swift`

**Interfaces:**
- Produces: `DisplaySelectorModel`, `DisplaySelectorView`, and the media-detail Set as Wallpaper action.
- Consumes: connected `DisplayRecord` targets and `DisplayFeatureStore.assign(mediaID:displayIDs:)`.

- [ ] **Step 1: Add failing selector behavior tests**

```swift
func testSelectAllTargetsOnlyConnectedDisplays() {
    var model = DisplaySelectorModel(targets: [onlineOne, onlineTwo])
    model.selectAll()
    XCTAssertEqual(model.selectedIDs, [onlineOne.id, onlineTwo.id])
    XCTAssertTrue(model.canConfirm)
    XCTAssertEqual(model.summary, "将应用到 2 台显示器")
}

func testEmptySelectionCannotConfirm() {
    XCTAssertFalse(DisplaySelectorModel(targets: [onlineOne]).canConfirm)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter 'DisplaySelectorViewTests|AppKitShellTests|GalleryStoreTests'`

Expected: compilation fails because selector types and the detail action do not exist.

- [ ] **Step 3: Implement selector and gallery wiring**

```swift
public struct DisplaySelectorModel: Equatable {
    public let targets: [DisplayRecord]
    public var selectedIDs: Set<DisplayID> = []
    public var canConfirm: Bool { !selectedIDs.isEmpty }
    public var summary: String { "将应用到 \(selectedIDs.count) 台显示器" }
    public mutating func selectAll() { selectedIDs = Set(targets.map(\.id)) }
}
```

The sheet lists current assignment context, individual toggles, Select All/Clear All, target summary, Cancel, and a disabled-until-valid Confirm button. Add `onSetWallpaper` to `MediaDetailView`; `GalleryView` presents the selector for the selected media and calls the feature-store batch assignment command. Keep the media detail sheet open when selector validation fails and display the command error.

After an assignment snapshot commits, make `GalleryStore` refresh deletion usage before another delete attempt; do not cache display references.

- [ ] **Step 4: Run selector, gallery, and UI smoke tests**

Run: `swift test --filter 'DisplaySelectorViewTests|AppKitShellTests|GalleryStoreTests'`

Expected: selection, confirmation, render, and deletion-guard tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeAppSupport/UI Sources/WallumeAppSupport/Gallery Tests/WallumeAppSupportTests
git commit -m "feat: assign gallery media to multiple displays"
```

### Task 8: Status menu, production composition, and lifecycle

**Files:**
- Modify: `Sources/WallumeAppSupport/AppKit/StatusItemController.swift`
- Modify: `Sources/WallumeApp/ApplicationController.swift`
- Modify: `Tests/WallumeAppSupportTests/AppKitShellTests.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift`

**Interfaces:**
- Produces: combined `StatusItemState` and production startup/termination wiring.
- Consumes: import queue snapshots, display feature state, assignment store events, and `WallpaperRuntimeService` events.

- [ ] **Step 1: Add failing combined-state and lifecycle tests**

```swift
func testStatusTitleIncludesPausedWallpaperCountWhenImportIdle() {
    let state = StatusItemState(imports: .idle, activeDisplayCount: 2, pauseReasons: [.user])
    XCTAssertEqual(StatusItemController.title(for: state), "已暂停 · 2 台显示器")
}

func testClosingMainWindowDoesNotRequestRuntimeStop() {
    let lifecycle = ApplicationLifecycleRecorder()
    lifecycle.windowDidClose()
    XCTAssertEqual(lifecycle.runtimeStopCalls, 0)
}

func testTerminationStopsRuntimeAfterImportDecision() async {
    await lifecycle.prepareForTermination()
    XCTAssertEqual(lifecycle.events, ["imports.finished", "runtime.stopped"])
}
```

- [ ] **Step 2: Run tests and verify failure**

Run: `swift test --filter 'AppKitShellTests|ApplicationCompositionTests'`

Expected: compilation fails because combined status and runtime lifecycle integration are absent.

- [ ] **Step 3: Compose production services and menu state**

Construct one `AtomicJSONStore`, `DisplayAssignmentStore`, `DisplayFeatureStore`, CoreGraphics-backed `AppKitScreenProvider`, `AVPlayerPresentationRegistry`, `PlayerPool`, `RuntimeCoordinator`, `DesktopWindowController`, environment/occlusion monitors, and `WallpaperRuntimeService` in `ApplicationController`.

Launch order is assignment load, gallery load, runtime start, event observation, then optional main-window presentation. On load failure, publish the page error and start the runtime with no assignments. Do not rewrite the corrupt file.

Extend the status menu with playback state, active display count, Pause/Resume when user-controllable, Open Displays, existing import actions, and Quit. Preserve import progress as the button title while imports are active; otherwise show the wallpaper state.

Formal termination first completes or cancels imports using the existing decision flow, then awaits `runtime.stop()`. Main-window close continues to release only its SwiftUI hosting content.

- [ ] **Step 4: Run app-support tests and release build**

Run: `swift test --filter WallumeAppSupportTests`

Expected: all app-support tests pass.

Run: `swift build -c release --product WallumeApp`

Expected: application release build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/WallumeApp Sources/WallumeAppSupport Tests/WallumeAppSupportTests
git commit -m "feat: integrate display runtime with Wallume app"
```

### Task 9: Documentation and completion gates

**Files:**
- Modify: `docs/application-shell-gallery.md`
- Modify: `docs/phase-four-status.md`
- Modify: `docs/progress-status.md`
- Test: full package and release products.

**Interfaces:**
- Produces: accurate phase-four batch-two status and verification record.
- Consumes: all implementation and test outcomes from Tasks 1-8.

- [ ] **Step 1: Update product and phase documentation**

Document the Displays page, gallery multi-display assignment, offline restoration, three presentation modes, global persisted pause, menu-bar controls, in-process runtime ownership, muted-audio constraint, and deferred hardware performance certification. Mark only batch two engineering work complete; do not mark the whole of phase four complete.

- [ ] **Step 2: Run the complete test suite**

Run: `swift test`

Expected: every test passes with zero failures.

- [ ] **Step 3: Build every release product**

Run: `swift build -c release --product WallumeApp`

Run: `swift build -c release --product wallume-runtime`

Run: `swift build -c release --product wallume-media`

Run: `swift build -c release --product wallume-restore`

Expected: all four commands exit successfully.

- [ ] **Step 4: Run repository hygiene and scope checks**

Run: `git diff --check`

Expected: no output.

Run: `git status --short`

Expected: only planned phase-four files are modified; the user's untracked `.vscode/` remains untouched.

- [ ] **Step 5: Request completion review and resolve findings**

Review the complete branch against `docs/superpowers/specs/2026-07-17-display-assignment-playback-control-design.md`. Any critical or important finding receives a failing regression test, a focused fix, and a rerun of the affected and full gates before completion.

- [ ] **Step 6: Commit final documentation**

```bash
git add docs/application-shell-gallery.md docs/phase-four-status.md docs/progress-status.md
git commit -m "docs: complete display assignment batch"
```

Do not push. Merge locally into `main` only after all completion gates and review findings pass, preserving the user's requested workflow of pushing after the full phase is complete.
