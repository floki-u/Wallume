# Application Shell, Gallery, and Import Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a menu-bar Wallume application with a stable SwiftUI sidebar, searchable media gallery, on-demand media details, and a serial background import queue for files and recursively scanned folders.

**Architecture:** Add a testable `WallumeAppSupport` target between `WallumeCore` and the thin `WallumeApp` executable. Core owns scanning and safe single-media import events; AppSupport owns queue and UI state; AppKit owns process, status-item, window, panel, notification, and termination lifecycle while SwiftUI renders pages.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, SwiftUI, AVKit, AVFoundation, UserNotifications, Foundation, XCTest, macOS 14.

## Global Constraints

- Support Apple Silicon and macOS 14 or newer; add no third-party packages or daemon.
- Preserve the existing safe importer order: private staging, validation, exclusive installs, library registration last, and cleanup on cancellation/failure.
- Import at most one media item at a time; normal wallpaper playback remains independent and timer-free.
- Recursively scan folders while ignoring hidden files/directories and package contents.
- Closing the main window must not cancel imports; quitting with work active requires explicit confirmation and cleanup.
- Automated tests use temporary directories and injected adapters; they never access live macOS wallpaper data.
- Preserve the user-owned untracked `.vscode/` directory and exclude it from every commit.
- Keep media preview muted; create it only after explicit play and release it when details close.
- Do not implement display assignment, lock-screen writes, performance/settings feature pages, localization, or volume control in this batch.

---

### Task 1: Scan files and folders into stable import candidates

**Files:**
- Create: `Sources/WallumeCore/Media/ImportScanner.swift`
- Create: `Tests/WallumeCoreTests/ImportScannerTests.swift`

**Interfaces:**
- Produces: `ImportScanResult(candidates:warnings:)`
- Produces: `ImportScanning.scan(_:) -> ImportScanResult`
- Produces: `LocalImportScanner` using injected `ImportDirectoryReading`

- [ ] **Step 1: Write failing recursive/filtering tests**

Create temporary `visible/nested/movie.mov`, `.hidden.mov`, `.hidden/ignored.mp4`, `Bundle.app/inside.mov`, `note.txt`, and a duplicated input URL. Assert candidates contain only the visible movie once. Add an injected reader that throws for one folder and assert a warning plus candidates from the other folder.

```swift
let result = scanner.scan([visibleRoot, visibleMovie])
XCTAssertEqual(result.candidates, [visibleMovie.standardizedFileURL])
XCTAssertEqual(result.warnings.count, 0)
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter ImportScannerTests`

Expected: compilation fails because `LocalImportScanner` does not exist.

- [ ] **Step 3: Implement deterministic scanning**

Define:

```swift
public struct ImportScanWarning: Equatable, Sendable { public let url: URL; public let message: String }
public struct ImportScanResult: Equatable, Sendable { public let candidates: [URL]; public let warnings: [ImportScanWarning] }
public protocol ImportScanning: Sendable { func scan(_ urls: [URL]) -> ImportScanResult }
```

Use resource values `isRegularFile`, `isDirectory`, `isHidden`, and `isPackage`; never descend into a hidden directory or package. Accept case-insensitive `mov`/`mp4`, standardize URLs, deduplicate by path, and localized-standard sort both candidates and traversal entries. Convert per-directory read errors into warnings and continue.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter ImportScannerTests && git diff --check`

```bash
git add Sources/WallumeCore/Media/ImportScanner.swift Tests/WallumeCoreTests/ImportScannerTests.swift
git commit -m "feat: scan media import sources"
```

### Task 2: Expose safe single-item import events and cancellation

**Files:**
- Modify: `Sources/WallumeCore/Media/MediaImporting.swift`
- Modify: `Sources/WallumeCore/Media/AVFoundationMedia.swift`
- Modify: `Tests/WallumeCoreTests/MediaImporterTests.swift`
- Create: `Tests/WallumeCoreTests/MediaImporterProgressTests.swift`

**Interfaces:**
- Produces: `MediaImportStage`
- Produces: `MediaImportEvent.stage(_:progress:)`
- Produces: `MediaImporter.importURL(_:onEvent:) async -> MediaImportResult`
- Preserves: `MediaImporter.importURLs(_:) async throws -> MediaImportReport`

- [ ] **Step 1: Write failing event and cancellation tests**

Assert one successful item reports stages in this order:

```swift
XCTAssertEqual(stages, [.hashing, .inspecting, .transcoding, .artwork, .committing, .cleanup])
```

Start a blocking fake transcoder, cancel the task, release it, and assert `.cancelled`, an empty work root, and no owned installed files. Assert the existing batch API still continues after a cancelled item.

- [ ] **Step 2: Verify red**

Run: `swift test --filter 'MediaImporterProgressTests|MediaImporterTests'`

Expected: compilation fails because the single-item event API does not exist.

- [ ] **Step 3: Implement the single-item boundary**

Define event delivery as an `@Sendable (MediaImportEvent) -> Void` closure. Move the body of `importOne` into public `importURL`; make `importURLs` call the scanner-compatible stable candidates and then `importURL`. Check cancellation before every stage and emit cleanup only after cancellation/failure cleanup completes.

Extend `MediaTranscoding.transcode` with an optional `@Sendable (Double) -> Void` progress closure. The AVFoundation adapter reports `export.progress` using an import-only async polling task at 100 ms, cancels that reporter when export completes, clamps values to `0...1`, and keeps its existing cancellation handler. Fake transcoders report deterministic progress.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'MediaImporterProgressTests|MediaImporterTests|AVFoundationMediaTests'`

```bash
git add Sources/WallumeCore/Media Tests/WallumeCoreTests/MediaImporterTests.swift Tests/WallumeCoreTests/MediaImporterProgressTests.swift Tests/WallumeCoreTests/AVFoundationMediaTests.swift
git commit -m "feat: report cancellable media import progress"
```

### Task 3: Run a serial, retryable background import queue

**Files:**
- Create: `Sources/WallumeAppSupport/Import/ImportQueueModels.swift`
- Create: `Sources/WallumeAppSupport/Import/ImportQueue.swift`
- Create: `Tests/WallumeAppSupportTests/ImportQueueTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `ImportScanning`, `MediaImporter.importURL(_:onEvent:)`
- Produces: `ImportQueueSnapshot`, `ImportQueueItem`, `ImportAttempt`, `ImportQueueEvent`
- Produces: actor methods `enqueue(_:)`, `cancelCurrent()`, `cancelAll()`, `retry(_:)`, `retryAllFailures()`, `events()`

- [ ] **Step 1: Add targets and write failing queue tests**

Add `WallumeAppSupport` depending on `WallumeCore`, and `WallumeAppSupportTests` depending on both. With an importer spy that blocks each call, assert maximum concurrency is one, failure continues to the next item, cancel-current continues, cancel-all marks waiting items cancelled, and retry-all appends attempts in original path order.

```swift
XCTAssertEqual(await importer.maximumConcurrentCalls, 1)
XCTAssertEqual(snapshot.summary.failed, 1)
XCTAssertEqual(snapshot.summary.imported, 1)
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter ImportQueueTests`

Expected: compilation fails because queue types do not exist.

- [ ] **Step 3: Implement the queue actor**

Use one retained processing `Task`, never start a second while it is non-nil. Represent attempts explicitly so retry history remains visible. Publish snapshots through `AsyncStream<ImportQueueSnapshot>` with immediate current-state delivery. `cancelCurrent` cancels only the current task; `cancelAll` also marks every waiting item cancelled. Do not dequeue the next item until `importURL` has returned after cleanup.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter ImportQueueTests && git diff --check`

```bash
git add Package.swift Sources/WallumeAppSupport/Import Tests/WallumeAppSupportTests/ImportQueueTests.swift
git commit -m "feat: add serial background import queue"
```

### Task 4: Model gallery, deletion guards, launch state, and notifications

**Files:**
- Create: `Sources/WallumeAppSupport/Gallery/GalleryStore.swift`
- Create: `Sources/WallumeAppSupport/Gallery/MediaUsage.swift`
- Create: `Sources/WallumeAppSupport/Application/ApplicationState.swift`
- Create: `Sources/WallumeAppSupport/Import/ImportTaskStore.swift`
- Create: `Tests/WallumeAppSupportTests/GalleryStoreTests.swift`
- Create: `Tests/WallumeAppSupportTests/ApplicationStateTests.swift`

**Interfaces:**
- Produces: `MediaUsageChecking.references(to:) -> [DisplayReference]`
- Produces: `GalleryStore.reload()`, `filteredItems`, `requestDelete(_:)`, `confirmDelete(_:)`
- Produces: `ApplicationState.shouldOpenWindowAtLaunch`, `shouldNotifyOnCompletion`
- Produces: `@MainActor ImportTaskStore` consuming queue snapshots

- [ ] **Step 1: Write failing state tests**

Test case-insensitive name/codec/resolution search, authoritative reload, index error preservation, blocked deletion listing two displays, successful deletion after references clear, first-launch window opening, later menu-only launch, and notification only while window hidden or application inactive.

```swift
XCTAssertEqual(store.deletionBlock?.displays.map(\.name), ["Built-in Display", "Studio Display"])
XCTAssertFalse(ApplicationState(hasLaunchedBefore: true, openGalleryAtLaunch: false).shouldOpenWindowAtLaunch)
```

- [ ] **Step 2: Verify red**

Run: `swift test --filter 'GalleryStoreTests|ApplicationStateTests'`

Expected: compilation fails because stores do not exist.

- [ ] **Step 3: Implement observable main-thread stores**

Use Swift Observation (`@Observable`, `@MainActor`) for stores. Keep filesystem and queue protocols injected. `requestDelete` calls usage checking first and never calls the library when references exist. `confirmDelete` rechecks usage to close the race before removal. `ImportTaskStore` derives collapsed summary, expanded attempts, completion banner, and menu-bar text without owning queue execution.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'GalleryStoreTests|ApplicationStateTests|ImportQueueTests'`

```bash
git add Sources/WallumeAppSupport/Gallery Sources/WallumeAppSupport/Application Sources/WallumeAppSupport/Import/ImportTaskStore.swift Tests/WallumeAppSupportTests
git commit -m "feat: model gallery and application state"
```

### Task 5: Build the stable SwiftUI shell, gallery, task drawer, and details

**Files:**
- Create: `Sources/WallumeAppSupport/UI/FeatureRegistry.swift`
- Create: `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`
- Create: `Sources/WallumeAppSupport/UI/GalleryView.swift`
- Create: `Sources/WallumeAppSupport/UI/ImportTaskDrawer.swift`
- Create: `Sources/WallumeAppSupport/UI/MediaDetailView.swift`
- Create: `Sources/WallumeAppSupport/UI/MediaPreviewController.swift`
- Create: `Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift`
- Create: `Tests/WallumeAppSupportTests/MediaPreviewControllerTests.swift`

**Interfaces:**
- Produces stable features: `gallery`, `displays`, `lockScreen`, `performance`, `settings`
- Produces `ApplicationShellView` and `GalleryView`
- Produces `MediaPreviewController.play(_:)` and `releasePlayer()`

- [ ] **Step 1: Write failing feature and preview-lifecycle tests**

Assert exact feature IDs/order and only gallery is enabled. Inject a player factory, call play, then release, and assert pause/release happens and the controller retains no player. Render the shell through `NSHostingView` and assert it can create a nonzero fitting size with empty gallery state.

- [ ] **Step 2: Verify red**

Run: `swift test --filter 'ApplicationShellViewTests|MediaPreviewControllerTests'`

Expected: compilation fails because UI types do not exist.

- [ ] **Step 3: Implement the selected A layout**

Build `NavigationSplitView` with fixed feature order. Gallery uses `LazyVGrid`, searchable text, file/folder buttons, drop destination for file URLs, selection-driven details, and a bottom safe-area inset containing the collapsed/expanded task drawer. Details use `VideoPlayer` only after explicit play; set player volume to zero. Disabled features render an honest later-batch page.

The drawer exposes cancel-current, cancel-all, retry-one, and retry-all actions, scan warnings, attempt history, stable summary counts, and an accessibility label for every state.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'ApplicationShellViewTests|MediaPreviewControllerTests|GalleryStoreTests'`

```bash
git add Sources/WallumeAppSupport/UI Tests/WallumeAppSupportTests
git commit -m "feat: build gallery and import task interface"
```

### Task 6: Add AppKit window, status item, file panels, and completion notifications

**Files:**
- Create: `Sources/WallumeAppSupport/AppKit/MainWindowController.swift`
- Create: `Sources/WallumeAppSupport/AppKit/StatusItemController.swift`
- Create: `Sources/WallumeAppSupport/AppKit/ImportPanelController.swift`
- Create: `Sources/WallumeAppSupport/AppKit/CompletionNotifier.swift`
- Create: `Tests/WallumeAppSupportTests/AppKitShellTests.swift`

**Interfaces:**
- Produces main-window `show()`, `closeAndReleaseContent()`, and `isVisible`
- Produces status menu updates from `ImportTaskStore`
- Produces file/folder panels with multiple selection and directory selection kept separate
- Produces injected `CompletionNotifying.notify(_:)`

- [ ] **Step 1: Write failing AppKit adapter tests**

Verify the window releases its hosting content on close while queue/store objects remain retained by the owner. Verify status summary/menu actions for idle, active, failed, and complete snapshots. Verify the file panel accepts multiple `.mov/.mp4` and the folder panel chooses directories. Verify notifier is called only from an eligible `ApplicationState`.

- [ ] **Step 2: Verify red**

Run: `swift test --filter AppKitShellTests`

Expected: compilation fails because AppKit adapters do not exist.

- [ ] **Step 3: Implement adapters**

Use `NSWindow` + `NSHostingView`, `NSStatusItem`, `NSPopover`, `NSOpenPanel`, and `UNUserNotificationCenter`. Main-window close clears the hosting view and store references owned by that view, not process-level queue state. Status popover never loads the full media library; it renders only derived task summary and commands. Ask notification permission lazily before the first background completion notification.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'AppKitShellTests|ApplicationStateTests'`

```bash
git add Sources/WallumeAppSupport/AppKit Tests/WallumeAppSupportTests/AppKitShellTests.swift
git commit -m "feat: add application window and menu bar shell"
```

### Task 7: Compose the Wallume application executable and safe termination

**Files:**
- Modify: `Package.swift`
- Create: `Sources/WallumeApp/main.swift`
- Create: `Sources/WallumeApp/ApplicationController.swift`
- Create: `Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift`

**Interfaces:**
- Produces executable product `WallumeApp`
- Composes production `MediaLibrary`, `MediaImporter`, `ImportQueue`, stores, panels, notifier, window, and status item
- Implements first-launch and active-import termination policy

- [ ] **Step 1: Write failing composition-policy tests**

Extract a testable `TerminationCoordinator`. Assert idle termination returns immediately; active termination with “keep running” cancels termination; active termination with confirmation awaits `cancelAllAndWait()` before allowing exit. Assert the production composition shares exactly one queue between status and window controllers.

- [ ] **Step 2: Verify red**

Run: `swift test --filter ApplicationCompositionTests`

Expected: compilation fails because composition types do not exist.

- [ ] **Step 3: Implement the executable**

Add `.executable(name: "WallumeApp", targets: ["WallumeApp"])` and an executable target depending on Core/AppSupport. Set `.accessory` activation policy, construct paths from `HOME`/`XDG_CACHE_HOME`, run `NSApplication`, mark first launch only after controllers initialize, and show the gallery according to application state. Implement `applicationShouldTerminate` with `.terminateLater` while queue cancellation cleanup completes, then call `reply(toApplicationShouldTerminate:)` on the main actor.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter ApplicationCompositionTests && swift build --product WallumeApp`

```bash
git add Package.swift Sources/WallumeApp Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift
git commit -m "feat: launch Wallume menu bar application"
```

### Task 8: Document, integrate real media, review, and complete the batch

**Files:**
- Create: `docs/application-shell-gallery.md`
- Create: `docs/phase-four-status.md`
- Modify: `docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md`

**Interfaces:**
- Documents supported UI behavior, background imports, cancellation/retry semantics, and remaining fourth-phase batches

- [ ] **Step 1: Add user/developer documentation**

Document first-launch/menu-only behavior, file/folder buttons, recursive drag/drop rules, selected bottom drawer, background continuation, notification conditions, detail preview lifetime, guarded deletion, and the exact remaining batches. Do not claim display/lock-screen/settings UI is implemented.

- [ ] **Step 2: Run isolated real-media acceptance**

Generate two disposable small `.mov/.mp4` sources under a temporary realpath HOME using AVFoundation test fixtures or `/usr/bin/avconvert` if available. Launch the queue through a small test harness or integration test, close/recreate the gallery state while it runs, cancel one item, retry it, and verify source hashes are unchanged, library variants are readable `hvc1` MOV files, and work directories are empty.

- [ ] **Step 3: Run final automated gates**

Run:

```bash
swift test
swift build -c release --product WallumeApp
swift build -c release --product wallume-runtime
swift build -c release --product wallume-media
swift build -c release --product wallume-restore
git diff --check
```

Expected: every test passes, all products build, and whitespace check exits zero.

- [ ] **Step 4: Request completion review and fix all Critical/Important findings**

Review the range from the design-plan base to HEAD for spec alignment, serial/cancellation safety, UI lifetime, deletion guards, accessibility, and test evidence. Add regression tests before fixes. Repeat focused and full gates after fixes.

- [ ] **Step 5: Commit batch status**

```bash
git add docs
git commit -m "docs: complete phase four gallery batch"
```

## Plan self-review

- Spec coverage: scanning, serial queue, progress, both cancellation actions, failure continuation, retry, background window lifetime, notification policy, A-layout drawer, gallery search/details, muted on-demand preview, guarded deletion, first-launch behavior, stable sidebar, and later-batch boundaries each map to an explicit task.
- Type flow: Task 1 scanner and Task 2 single importer feed Task 3 queue; Task 3 snapshots feed Task 4 stores; Task 4 stores feed Task 5 views and Task 6 adapters; Task 7 owns every process-level object.
- Scope: display assignment and functional lock-screen/performance/settings pages remain excluded; only their stable navigation entries and media-usage boundary are created.
- No placeholders or implicit “similar” implementation steps remain.
