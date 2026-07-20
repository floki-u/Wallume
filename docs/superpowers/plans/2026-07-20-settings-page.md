# Settings Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-safe Settings page for login launch, launch-gallery and low-power policy preferences, plus local diagnostic export.

**Architecture:** Keep preferences and ServiceManagement behind an app-support `SettingsStore`, which publishes one complete `ApplicationSettings` snapshot to SwiftUI. A separate export service composes only redacted, local summaries from injected settings/lock-screen/performance providers. `ApplicationController` owns the settings composition, applies low-power policy to the runtime environment before assignments/runtime start, and routes the enabled page.

**Tech Stack:** Swift 6, macOS 14+, SwiftUI/Observation, ServiceManagement, XCTest, existing `AtomicJSONStore`, `FileStore`, lock-screen and performance models.

## Global Constraints

- `launchAtLogin` and `openGalleryAtLaunch` default to off; `pauseInLowPowerMode` defaults to on.
- Reuse the stable `openGalleryAtLaunch` UserDefaults key; normal preferences use an injected UserDefaults suite in tests.
- Login-item registration/unregistration failure keeps the previous setting and emits a user-safe error; the observed system state is authoritative.
- The environment monitor always observes low-power state, but it contributes `.lowPower` only when `pauseInLowPowerMode` is enabled; toggling applies immediately.
- Load settings before display assignments and desktop runtime startup; no page lifecycle action may stop the settings store.
- Export is user-selected/local only, includes redacted settings, lock-screen summary, recent transaction summary, latest performance report and build/system information; it contains no media names/content, thumbnails, video/source URLs, backup data, raw home paths, or network traffic.
- Export failure does not change persisted settings or corrupt an earlier export and remains retryable; application termination cancels an incomplete export but does not roll back preferences.
- Keep work local: do not push and do not alter user-owned `.vscode/`.

---

## File Map

| Area | Files |
| --- | --- |
| Settings domain and login adapter | `Sources/WallumeAppSupport/Settings/ApplicationSettings.swift`, `LoginItemController.swift`, `SettingsStore.swift` |
| Redacted diagnostic export | `Sources/WallumeAppSupport/Settings/DiagnosticsExportService.swift` |
| Low-power policy | `Sources/WallumeCore/AppKitRuntime/RuntimeEnvironmentMonitor.swift`, `Sources/WallumeAppSupport/Runtime/WallpaperRuntimeService.swift` |
| Settings UI/composition | `Sources/WallumeAppSupport/UI/SettingsView.swift`, `ApplicationShellView.swift`, `FeatureRegistry.swift`, `Sources/WallumeApp/ApplicationController.swift` |
| Tests | `Tests/WallumeAppSupportTests/SettingsStoreTests.swift`, `DiagnosticsExportServiceTests.swift`, `SettingsViewTests.swift`, `ApplicationShellViewTests.swift`, `ApplicationCompositionTests.swift`, `Tests/WallumeCoreTests/RuntimeEnvironmentMonitorTests.swift` |
| Status | `docs/phase-four-status.md`, `docs/progress-status.md`, this plan |

## Task 1: Settings preferences, system login-item boundary, and low-power policy

**Files:**
- Create: `Sources/WallumeAppSupport/Settings/ApplicationSettings.swift`
- Create: `Sources/WallumeAppSupport/Settings/LoginItemController.swift`
- Create: `Sources/WallumeAppSupport/Settings/SettingsStore.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/RuntimeEnvironmentMonitor.swift`
- Modify: `Tests/WallumeCoreTests/RuntimeEnvironmentMonitorTests.swift`
- Create: `Tests/WallumeAppSupportTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces `ApplicationSettings(launchAtLogin: Bool, openGalleryAtLaunch: Bool, pauseInLowPowerMode: Bool)` and `@MainActor @Observable SettingsStore` with `settings`, `errorMessage`, `setLaunchAtLogin(_:)`, `setOpenGalleryAtLaunch(_:)`, and `setPauseInLowPowerMode(_:)`.
- Produces `LoginItemControlling` with `isEnabled() throws`, `register() throws`, and `unregister() throws`; production implementation wraps `SMAppService.mainApp`.
- Extends `RuntimeEnvironmentMonitor` with `setLowPowerPauseEnabled(_:)` so it always observes hardware state but conditionally emits `.lowPower`.

- [x] **Step 1: Write failing tests** using an isolated defaults suite and fake login controller: assert defaults, legacy `openGalleryAtLaunch` decoding, persistence, system-authoritative login success, rollback/error on register or unregister failure, and immediate low-power reason removal/re-addition while hardware low-power remains true.

```swift
func testRegisterFailureKeepsPreviousLaunchAtLoginValue() {
    let store = SettingsStore(defaults: defaults, loginItem: FailingLoginItem())
    store.setLaunchAtLogin(true)
    XCTAssertFalse(store.settings.launchAtLogin)
    XCTAssertNotNil(store.errorMessage)
}
```

- [x] **Step 2: Run RED:** `swift test --filter SettingsStoreTests && swift test --filter RuntimeEnvironmentMonitorTests` — expected missing Settings symbols and policy API.
- [x] **Step 3: Implement** value-only settings keys, a ServiceManagement adapter that converts platform failures to a closed user-safe message in the store, and monitor policy that rebuilds effective `RuntimeEnvironment` without changing other signals. Keep direct UserDefaults and ServiceManagement out of SwiftUI.
- [x] **Step 4: Run GREEN:** `swift test --filter SettingsStoreTests && swift test --filter RuntimeEnvironmentMonitorTests` — defaults, rollback, legacy key and immediate policy tests pass.
- [x] **Step 5: Commit:** `git commit -m "feat: add settings preferences and low-power policy"`.

## Task 2: Redacted local diagnostic export service

**Files:**
- Create: `Sources/WallumeAppSupport/Settings/DiagnosticsExportService.swift`
- Modify: `Sources/WallumeAppSupport/LockScreen/LockScreenSyncModels.swift` only if a count/status-only summary adapter is needed
- Create: `Tests/WallumeAppSupportTests/DiagnosticsExportServiceTests.swift`

**Interfaces:**
- Consumes `ApplicationSettings`, latest `PerformanceDiagnosticReport?`, a count/status-only lock-screen snapshot, build/system metadata, an injected destination URL and `FileStore`.
- Produces `DiagnosticsExportDocument` and `DiagnosticsExportService.export(to:) async throws`; no output type contains a media ID/name, URL, thumbnail, backup path, transaction path, or user home directory.

- [x] **Step 1: Write failing tests** that export to a temporary directory, decode the document, assert settings/lock-screen/performance/build fields, and reject fixture strings representing media names, `file://` URLs, home paths, thumbnails, and backup data. Add failure-injection proof that a failed write preserves an existing destination and a subsequent retry succeeds.

```swift
func testExportRejectsPrivateFixtureValuesAndKeepsExistingFileOnWriteFailure() async throws {
    let old = try Data("old".utf8)
    try files.write(old, to: destination)
    await XCTAssertThrowsErrorAsync { try await service.export(to: destination) }
    XCTAssertEqual(try files.read(destination), old)
}
```

- [x] **Step 2: Run RED:** `swift test --filter DiagnosticsExportServiceTests` — expected missing service/document compilation failure.
- [x] **Step 3: Implement** a versioned Codable export document with only declared safe fields, `AtomicJSONStore` output, injected snapshot readers and a finite `DiagnosticsExportUserError`. Read latest performance report through the existing report store; represent unavailable sources as safe status/count values, never raw errors or paths.
- [x] **Step 4: Run GREEN:** `swift test --filter DiagnosticsExportServiceTests` — redaction, atomic failure and retry cases pass.
- [x] **Step 5: Commit:** `git commit -m "feat: add redacted diagnostics export"`.

## Task 3: Observable settings page and app composition

**Files:**
- Create: `Sources/WallumeAppSupport/UI/SettingsView.swift`
- Modify: `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`
- Modify: `Sources/WallumeAppSupport/UI/FeatureRegistry.swift`
- Modify: `Sources/WallumeApp/ApplicationController.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift`
- Create: `Tests/WallumeAppSupportTests/SettingsViewTests.swift`

**Interfaces:**
- `ApplicationShellView` gains optional injected `SettingsStore`; `.settings` resolves only when it is supplied.
- `SettingsView` receives `SettingsStore`, directory/build info and injected `openInFinder(URL)` / export destination chooser; it invokes store/export commands but performs no direct UserDefaults, ServiceManagement, filesystem or runtime sampling.
- `ApplicationController` constructs one settings store/export service, loads settings before `startDisplayRuntime()`, passes `openGalleryAtLaunch` into `ApplicationState`, applies low-power policy to the environment monitor/runtime and cancels export during termination.

- [x] **Step 1: Write failing tests** that assert Settings becomes enabled/routable only with an injected store, view renders all three controls/directory/export state, page disappearance does not stop the store, controller startup loads settings before runtime start, and a low-power toggle triggers an immediate runtime environment recomputation.

```swift
func testSettingsRouteRequiresInjectedStore() {
    XCTAssertEqual(ApplicationShellRoute.resolve(selection: .settings,
        hasDisplayStore: true, hasLockScreenStore: true, hasPerformanceStore: true,
        hasSettingsStore: false), .unavailable)
}
```

- [x] **Step 2: Run RED:** `swift test --filter SettingsViewTests && swift test --filter ApplicationShellViewTests && swift test --filter ApplicationCompositionTests` — expected missing route/store/view wiring.
- [x] **Step 3: Implement** a Settings page with login/open-gallery/low-power toggles, app version, Wallume data and diagnostics directories, Finder buttons, export selection/error/retry state. Inject all side-effect closures. Enable Settings in `FeatureRegistry`; retain existing gallery/display/lock/performance routes and no new wallpaper-control behavior.
- [x] **Step 4: Run GREEN:** `swift test --filter SettingsViewTests && swift test --filter ApplicationShellViewTests && swift test --filter ApplicationCompositionTests` — routing, rendering, launch ordering and policy propagation pass.
- [x] **Step 5: Commit:** `git commit -m "feat: add settings page"`.

## Task 4: Lifecycle completion, documentation, and release verification

**Files:**
- Modify: `Sources/WallumeApp/ApplicationController.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift`
- Modify: `docs/phase-four-status.md`
- Modify: `docs/progress-status.md`
- Modify: `docs/superpowers/plans/2026-07-20-performance-diagnostics.md`
- Modify: this plan

**Interfaces:**
- Application termination cancels/awaits incomplete settings exports without undoing persisted preferences, while retaining the established lock-screen → diagnostics → runtime shutdown order.

- [x] **Step 1: Write failing tests** for cancellation of an in-flight export on termination, preserved preference values after cancellation, and unchanged service shutdown order.
- [x] **Step 2: Run RED:** `swift test --filter ApplicationCompositionTests` — expected termination composition failure.
- [x] **Step 3: Implement** explicit settings-export termination ownership in the controller/composition seam; no cancellation path changes login registration or saved ordinary preferences.
- [x] **Step 4: Run release gates:** `swift test`; `swift build -c release --product WallumeApp`; `swift build -c release --product wallume-runtime`; `swift build -c release --product wallume-media`; `swift build -c release --product wallume-restore`; `git diff --check`.
- [x] **Step 5: Update docs and checkboxes** with the exact automated evidence, mark Performance as locally merged, and state remaining phase-four manual UI/localization/state-restoration acceptance without claiming it passed.
- [x] **Step 6: Commit:** `git commit -m "docs: record settings verification"`.

## Acceptance Checklist

- [x] Defaults, legacy gallery key, persistence and login-item failure rollback are covered.
- [x] Low-power policy toggles immediately while monitoring always remains active.
- [x] Export is local, atomic, redacted and retryable.
- [x] Settings page has no direct system/filesystem/runtime side effects and does not stop its store on navigation.
- [x] Settings loads before display/runtime startup; termination cancels export without reversing preferences or shutdown order.
- [x] Full tests, all release products and diff check pass; no remote push occurs.

Final local verification on 2026-07-20: the focused Settings/composition/export/low-power suites passed 39 tests; full `swift test` passed 405 tests with zero failures; Release-configuration builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` completed; and `git diff --check` passed. Manual Settings/whole-app UI acceptance, localization, application state restoration, and real-system Lock Screen installation/lock/unlock/restoration remain pending; no release or remote integration is claimed.
