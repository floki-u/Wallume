# Wallume Stabilization and UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabilize the local macOS app for user verification, prevent the known macOS 26 lock-screen black-screen regression, and establish a cohesive modern SwiftUI visual system without changing verified core behavior.

**Architecture:** Treat lock-screen support as a capability with an explicit platform gate: the existing Aerial transaction implementation remains available only on macOS 14/15, while macOS 26 is rendered as unsupported before any system-file write or process refresh. Keep recovery fail-closed: conflicts and ambiguous recovery records require the existing explicit user recovery path. UI work is a presentation layer made of reusable design primitives, then applied to the shell and five feature pages without moving domain logic into views.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Package Manager, XCTest, macOS 14+.

## Global Constraints

- Preserve every unrelated local modification, `.vscode/`, and `.swiftpm/`; never reset or checkout the worktree.
- Do not push any commit until the user has completed local functional verification and explicitly authorizes pushing.
- On macOS 26, Wallume must not modify Aerial cache files, `Index.plist`, lock-screen posters, or restart Wallpaper processes.
- A macOS 26 unsupported state must explain the limitation and provide a safe system-settings action; it must never claim custom dynamic lock-screen support.
- A recovery conflict, ambiguous recovery record, malformed configuration, or failed restore must remain fail-closed and must not be silently cleared.
- Retain the existing menu-bar import activation fix and repaired app-window hosting, but make their AppKit tests pass.
- Keep current functional routes: 图库、显示器、锁屏、性能、设置.
- End the implementation round with `swift test` green; real-device checks are performed by the user before packaging or any remote push.

---

## File structure

| File | Responsibility |
|---|---|
| `Sources/WallumeCore/System/SystemVersion.swift` | Classifies supported legacy lock-screen generations and macOS 26 as unsupported before mutation. |
| `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift` | Keeps reconciliation fail-closed and uses probe capability to surface the platform gate. |
| `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift` | Retains terminal configuration failures until the user supplies an explicit corrective action. |
| `Sources/WallumeAppSupport/UI/LockScreenView.swift` | Presents unsupported macOS 26 safely and uses the shared visual primitives. |
| `Sources/WallumeAppSupport/UI/WallumeDesign.swift` (new) | Colour palette, cards, section headers, empty states, and animation policy. |
| `Sources/WallumeAppSupport/UI/ApplicationShellView.swift` | Applies the app shell’s sidebar/detail visual hierarchy. |
| `Sources/WallumeAppSupport/UI/{GalleryView,DisplaysView,PerformanceView,SettingsView}.swift` | Applies the shared visual hierarchy without changing stores or service calls. |
| `Sources/WallumeAppSupport/AppKit/MainWindowController.swift` | Owns a correctly released `NSHostingController` window root. |
| `Tests/WallumeAppSupportTests/{LockScreenSyncServiceTests,LockScreenViewTests,ApplicationShellViewTests,AppKitShellTests}.swift` | Covers safety, copy/actions, shell availability, and window lifetime. |
| `Tests/WallumeCoreTests/SystemVersionTests.swift` | Covers version classification and no-write platform capability. |

## Task 1: Preserve safe macOS 26 behavior before any lock-screen mutation

**Files:**
- Modify: `Sources/WallumeCore/System/SystemVersion.swift`
- Modify: `Sources/WallumeAppSupport/LockScreen/LockScreenSystemClient.swift`
- Modify: `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift`
- Test: `Tests/WallumeCoreTests/SystemVersionTests.swift`
- Test: `Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift`

**Interfaces:**
- Produces a probe report whose `writesPermitted` is false for macOS 26 and later when using the legacy Aerial implementation.
- Consumes `LockScreenProbeReport.writesPermitted` in `LockScreenSyncService.reconcileStartup()` before `align`, `install`, or `restore` is called.

- [ ] **Step 1: Write failing capability tests**

Add tests equivalent to:

```swift
func testTahoeDisablesLegacyAerialWrites() {
    XCTAssertFalse(SystemVersion(major: 26, minor: 0).supportsLegacyAerialLockScreen)
}

func testSequoiaStillAllowsLegacyAerialWrites() {
    XCTAssertTrue(SystemVersion(major: 15, minor: 0).supportsLegacyAerialLockScreen)
}
```

Add a service test with a spy client whose `install` and `restore` increment counters. Start with a macOS 26 probe, submit enabled input, then assert phase `.unsupported`, `installCount == 0`, and `restoreCount == 0`.

- [ ] **Step 2: Run focused tests and confirm they fail**

Run: `swift test --filter 'SystemVersionTests|LockScreenSyncServiceTests'`

Expected: the macOS 26 test fails because the legacy client reports writes as permitted or the service reaches the install path.

- [ ] **Step 3: Implement the platform gate**

Add a single capability predicate to `SystemVersion`:

```swift
public var supportsLegacyAerialLockScreen: Bool {
    majorVersion >= 14 && majorVersion < 26
}
```

Build the `LockScreenProbeReport.writesPermitted` value from that predicate and permissions. In `reconcileStartup()`, publish `.unsupported` immediately after probe success when writes are not permitted; do not inspect recovery, align transactions, refresh WallpaperAgent, install, or restore. Use a user-facing error/guidance that says macOS 26’s new wallpaper provider is not safely supported by the legacy integration.

- [ ] **Step 4: Run focused tests and confirm they pass**

Run: `swift test --filter 'SystemVersionTests|LockScreenSyncServiceTests'`

Expected: PASS; the spy counters are both zero for macOS 26.

- [ ] **Step 5: Commit the atomic change**

Run:

```bash
git add Sources/WallumeCore/System/SystemVersion.swift Sources/WallumeAppSupport/LockScreen/LockScreenSystemClient.swift Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift Tests/WallumeCoreTests/SystemVersionTests.swift Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift
git commit -m "fix: disable unsafe legacy lock screen writes on macos 26"
```

## Task 2: Restore fail-closed reconciliation and explicit recovery

**Files:**
- Modify: `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift`
- Modify: `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift`
- Modify: `Sources/WallumeCore/LockScreen/LockScreenTransaction.swift`
- Test: `Tests/WallumeAppSupportTests/LockScreenConfigurationStoreTests.swift`
- Test: `Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift`

**Interfaces:**
- Consumes `RecoveryCandidate.phase`, `RecoveryReport`, and persisted `LockScreenConfiguration`.
- Produces `.needsRepair` plus an explicit recovery action whenever configuration and recovery material are inconsistent.

- [ ] **Step 1: Re-enable the prior failing safety cases**

Keep and update the existing test names as the contract: `testAmbiguousRecoveryAlsoBlocksDisableFromClearingEnabledIntent`, `testConfiguredConflictBlocksWrites`, `testConflictedAlignmentBlocksAutomaticInstallUntilExplicitRecoverySucceeds`, `testInstallFailureBlocksNewInputUntilExplicitRetry`, `testMalformedConfigurationRemainsTerminalAfterValidReplacementAndRetry`, and `testMultipleRecoveryCandidatesBlockAllWrites`.

For each, assert both the phase (`.needsRepair`) and the absence of new `install` calls before a successful explicit recovery.

- [ ] **Step 2: Run the safety group and confirm current failures**

Run: `swift test --filter LockScreenSyncServiceTests`

Expected: failures demonstrate that the current `reset()`, automatic orphan cleanup, and `forceRecoverAndClear` paths convert unsafe states into writable states.

- [ ] **Step 3: Remove automatic state clearing**

In `reconcileStartup()`, remove the unconditional `configurationStore.reset()` call. In `align`, preserve ambiguous, missing, mismatched, conflicted, and unsupported recovery phases by calling `publishRepair(...)` and returning `false`. Delete `forceRecoverAndClear` and `restoreIgnoringConflict`; make `disable()` accept only a successful `systemClient.restore(transactionID:)` before persisting `.disabled`. Keep diagnostic logging only around operation boundaries, not per file mutation.

- [ ] **Step 4: Run the safety group and confirm it passes**

Run: `swift test --filter LockScreenSyncServiceTests`

Expected: PASS; a user must explicitly repair a compatible, uniquely identified transaction before writes resume.

- [ ] **Step 5: Commit the atomic change**

Run:

```bash
git add Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift Sources/WallumeCore/LockScreen/LockScreenTransaction.swift Tests/WallumeAppSupportTests/LockScreenConfigurationStoreTests.swift Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift
git commit -m "fix: keep lock screen recovery fail closed"
```

## Task 3: Make the existing app-window and import fixes testable

**Files:**
- Modify: `Sources/WallumeAppSupport/AppKit/MainWindowController.swift`
- Keep: `Sources/WallumeAppSupport/AppKit/ImportPanelController.swift`
- Test: `Tests/WallumeAppSupportTests/AppKitShellTests.swift`

**Interfaces:**
- `hasContent` reports whether the controller has an attached root view controller, not the AppKit window’s default content container.

- [ ] **Step 1: Tighten the existing window lifetime test**

Replace the content assertion with:

```swift
controller.show()
XCTAssertTrue(controller.hasContent)
controller.closeAndReleaseContent()
XCTAssertFalse(controller.hasContent)
controller.show()
XCTAssertTrue(controller.hasContent)
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter AppKitShellTests.testWindowReleasesHostingContentWhenClosed`

Expected: `hasContent` remains true because `NSWindow.contentView` exists even after its controller is released.

- [ ] **Step 3: Implement controller-owned state**

Implement:

```swift
public var hasContent: Bool { hostingController != nil }
```

Keep `contentViewController = nil` and `hostingController = nil` together in both close paths. Do not change the active-window call in `ImportPanelController`; it is required for a menu-bar accessory application to present the import panel.

- [ ] **Step 4: Run the AppKit group**

Run: `swift test --filter AppKitShellTests`

Expected: PASS.

- [ ] **Step 5: Commit the atomic change**

Run:

```bash
git add Sources/WallumeAppSupport/AppKit/MainWindowController.swift Sources/WallumeAppSupport/AppKit/ImportPanelController.swift Tests/WallumeAppSupportTests/AppKitShellTests.swift
git commit -m "fix: retain and release app window hosting content correctly"
```

## Task 4: Introduce a restrained modern visual system

**Files:**
- Create: `Sources/WallumeAppSupport/UI/WallumeDesign.swift`
- Modify: `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`
- Modify: `Sources/WallumeAppSupport/UI/GalleryView.swift`
- Modify: `Sources/WallumeAppSupport/UI/DisplaysView.swift`
- Modify: `Sources/WallumeAppSupport/UI/LockScreenView.swift`
- Modify: `Sources/WallumeAppSupport/UI/PerformanceView.swift`
- Modify: `Sources/WallumeAppSupport/UI/SettingsView.swift`
- Test: `Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift`
- Test: `Tests/WallumeAppSupportTests/LockScreenViewTests.swift`

**Interfaces:**
- Produces `WallumeCard`, `WallumeSectionHeader`, `WallumeStatusBadge`, and `wallumePageBackground()` as presentation-only SwiftUI primitives.
- Consumes current view state and callbacks unchanged; stores remain the only source of actions and data.

- [ ] **Step 1: Add rendering-contract tests**

Retain tests that create each page with its current store. Add a lock-screen assertion that a macOS 26 unsupported state exposes the system-settings action and no enable action. Add an application-shell rendering test covering all five enabled routes.

- [ ] **Step 2: Run view tests and confirm the new contract fails**

Run: `swift test --filter 'ApplicationShellViewTests|LockScreenViewTests'`

Expected: the unsupported-state action contract fails until Task 1’s state and Task 4’s view rendering are complete.

- [ ] **Step 3: Add the design primitives and apply them consistently**

Use semantic system colours so light/dark appearances remain readable. Implement cards with `.thinMaterial`, 16-point corner radius, a subtle stroke, consistent 16–20 point internal spacing, and no hard-coded black/white backgrounds. Use one accent colour (`.tint`) and status-specific semantic colours. Apply `.contentTransition(.opacity)` and a short ease-in-out animation only to value/status changes; do not animate navigation, destructive actions, or task progress values.

Replace repeated local `.background(.background.secondary, in: RoundedRectangle(...))` in feature views with `WallumeCard`. Give the shell a title/summary header and selected-sidebar treatment; keep `NavigationSplitView` and every existing callback unchanged.

- [ ] **Step 4: Run the view group**

Run: `swift test --filter 'ApplicationShellViewTests|GalleryStoreTests|DisplaysViewTests|LockScreenViewTests|PerformanceViewTests|SettingsViewTests'`

Expected: PASS.

- [ ] **Step 5: Commit the atomic change**

Run:

```bash
git add Sources/WallumeAppSupport/UI/WallumeDesign.swift Sources/WallumeAppSupport/UI/ApplicationShellView.swift Sources/WallumeAppSupport/UI/GalleryView.swift Sources/WallumeAppSupport/UI/DisplaysView.swift Sources/WallumeAppSupport/UI/LockScreenView.swift Sources/WallumeAppSupport/UI/PerformanceView.swift Sources/WallumeAppSupport/UI/SettingsView.swift Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift Tests/WallumeAppSupportTests/LockScreenViewTests.swift
git commit -m "feat: apply modern visual system to application shell"
```

## Task 5: Verify and hand off local functional validation

**Files:**
- Modify: `docs/macos-26-lock-screen-investigation.md`
- Create: `docs/local-verification-checklist.md`

- [ ] **Step 1: Record the supported behavior precisely**

Update the macOS 26 investigation status to “legacy integration safely disabled.” State that macOS 26 custom dynamic lock-screen support is not implemented, and list the non-negotiable safety condition: no writes or Wallpaper process restart on that OS.

- [ ] **Step 2: Create a human verification checklist**

Create a checklist with these exact checks:

```markdown
- [ ] Launch the `.app`; main content renders instead of a blank window.
- [ ] Use both “导入文件” and “导入文件夹”; the file picker appears in front of other apps.
- [ ] Import a folder containing nested media; confirm queue progress, failure continuation, retry, cancellation, and completed-item retention.
- [ ] Assign, preview, pause, resume, and remove wallpapers across attached displays.
- [ ] On macOS 26, open 锁屏: it states that custom dynamic lock-screen sync is unavailable; it offers System Settings; no enable control or file mutation occurs.
- [ ] Lock and unlock twice after using the app; the system lock screen is never blackened by Wallume.
- [ ] Check light and dark appearance on every navigation page.
```

- [ ] **Step 3: Run complete automated verification**

Run: `swift test && git diff --check`

Expected: all tests pass and no whitespace errors are reported.

- [ ] **Step 4: Commit verification documents**

Run:

```bash
git add docs/macos-26-lock-screen-investigation.md docs/local-verification-checklist.md
git commit -m "docs: add local verification checklist"
```

## Deferred work after user verification

1. Address only reproduced bugs from the user’s local validation, with a regression test per bug.
2. When the user confirms all functional flows, create the signed/reproducible app packaging and release workflow.
3. After local release validation, push authorized commits to the remote.
4. Then prepare a minimal open-source repository surface: keep source, tests, CI, license, security/contribution essentials; remove internal plans and private investigation artifacts from the public history only after review.
5. Write the final README and promotional Markdown articles from the verified feature set and actual installation/release path.

## Self-review

- macOS 26 black-screen prevention is covered by Tasks 1, 4, and 5; it deliberately does not make an unsupported claim of dynamic lock-screen compatibility.
- UI modernization is isolated to Task 4 and preserves stores, routes, and feature callbacks.
- Current dirty window/import changes are tested in Task 3 rather than discarded.
- All current lock-screen safety-test regressions are explicitly restored in Task 2.
- No task pushes, packages, removes files, or modifies remote state before user validation.
