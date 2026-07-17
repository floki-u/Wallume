# Lock Screen Application Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely expose Wallume's existing transactional lock-screen wallpaper capability in the macOS app, with explicit first-time Aerial-slot selection, automatic main-display synchronization, conservative recovery, and a usable Lock Screen page.

**Architecture:** Keep `LockScreenTransactionManifest` and `RecoveryCoordinator` as the authority for any system-file mutation. Add a versioned app-support configuration document that holds user intent and only references the current transaction. An actor serializes all probe/install/restore commands; a main-actor feature store maps its immutable snapshots into SwiftUI. `ApplicationController` supplies display-assignment/media updates to the actor without coupling the desktop runtime to lock-screen failure.

**Tech Stack:** Swift 6, Swift Package Manager, macOS 14+, SwiftUI/Observation, AppKit, existing `WallumeCore` lock-screen transaction and recovery services, XCTest.

## Global Constraints

- Never write system wallpaper files before a user explicitly selects and confirms one Aerial slot.
- Use only `variantURL` and `coverURL` from an imported `MediaItem`; preserve the existing silent-media policy.
- A new media target must always use **restore old transaction, then install new transaction**. Never attempt a second install over an active Wallume backup.
- A failed probe, corrupted lock-screen configuration, unknown macOS generation, external sidecar, recovery conflict, or ambiguous journals must fail closed: retain all recovery material and block new writes.
- No lock-screen error may change desktop assignments, stop desktop playback, or mutate the media library.
- Unit tests must use temporary fixtures and injected adapters only. They must never read or write `/Library/Application Support/com.apple.wallpaper`, `/Library/Caches/Desktop Pictures`, or the developer's actual home directory.
- Keep `.vscode/` untracked and untouched. Do not push to the remote.

---

## File Map

| Area | Files |
| --- | --- |
| Core adapter boundary | `Sources/WallumeAppSupport/LockScreen/LockScreenSystemClient.swift`, `Sources/WallumeAppSupport/LockScreen/ProcessGeneratedUIDProvider.swift` |
| Persistent intent | `Sources/WallumeAppSupport/LockScreen/LockScreenConfiguration.swift`, `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift` |
| Serialized policy | `Sources/WallumeAppSupport/LockScreen/LockScreenSyncModels.swift`, `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift` |
| Presentation model/UI | `Sources/WallumeAppSupport/LockScreen/LockScreenFeatureStore.swift`, `Sources/WallumeAppSupport/UI/LockScreenView.swift` |
| App composition | `Sources/WallumeApp/ApplicationController.swift`, `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`, `Sources/WallumeAppSupport/UI/FeatureRegistry.swift` |
| Tests | `Tests/WallumeAppSupportTests/LockScreenConfigurationStoreTests.swift`, `Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift`, `Tests/WallumeAppSupportTests/LockScreenFeatureStoreTests.swift`, `Tests/WallumeAppSupportTests/LockScreenViewTests.swift`, plus existing shell/composition tests |

## Task 1: Define serializable configuration and fail-closed storage

**Files:**
- Create: `Sources/WallumeAppSupport/LockScreen/LockScreenConfiguration.swift`
- Create: `Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift`
- Create: `Tests/WallumeAppSupportTests/LockScreenConfigurationStoreTests.swift`

- [ ] **Step 1: Write failing configuration-store tests.** Cover a missing file returning a disabled, unselected configuration; an atomic round trip; unsupported schema; malformed JSON; mutation before `load`; and mutation after a read failure. Assert failed loads preserve the invalid file bytes and that no `write` is attempted in either disallowed state.

- [ ] **Step 2: Run the focused test command and confirm it fails for the missing types.**

  Run: `swift test --filter LockScreenConfigurationStoreTests`

  Expected: compilation fails because the lock-screen configuration/store symbols do not exist.

- [ ] **Step 3: Implement `LockScreenConfiguration` and document.** Define a `Codable`, `Equatable`, `Sendable` document with `schemaVersion`, `isEnabled`, `selectedAerialID`, `activeTransactionID`, `lastSyncedMediaID`, `lastSyncedAt`, and a compact, non-sensitive last-result enum/message. Require a selected Aerial ID whenever enabled; persist no target hashes, backup paths, or media file paths. Use a single current schema constant and give disabled default configuration nil selection/transaction/media fields.

- [ ] **Step 4: Implement `LockScreenConfigurationStore` as an actor.** Match `DisplayAssignmentStore`'s load-state discipline: missing file loads the default; a successful validated document becomes mutable; malformed/unsupported data leaves the store in failed state and all future mutations throw a dedicated unavailable-after-load-failure error. Persist only through `AtomicJSONStore.write`, publish immutable snapshots through `AsyncStream`, and validate all enabled/transaction combinations before every commit.

- [ ] **Step 5: Re-run focused tests.**

  Run: `swift test --filter LockScreenConfigurationStoreTests`

  Expected: PASS.

- [ ] **Step 6: Commit the completed storage layer.**

  ```bash
  git add Sources/WallumeAppSupport/LockScreen/LockScreenConfiguration.swift Sources/WallumeAppSupport/LockScreen/LockScreenConfigurationStore.swift Tests/WallumeAppSupportTests/LockScreenConfigurationStoreTests.swift
  git commit -m "feat: persist lock screen sync configuration"
  ```

## Task 2: Add a production-only system client behind a narrow interface

**Files:**
- Create: `Sources/WallumeAppSupport/LockScreen/LockScreenSystemClient.swift`
- Create: `Sources/WallumeAppSupport/LockScreen/ProcessGeneratedUIDProvider.swift`
- Create: `Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift`

- [ ] **Step 1: Write failing client-adapter tests using fakes.** Establish a fake `LockScreenSystemClient` that records probe, install, inspect, and restore calls, returns controlled manifests/reports, and can throw at each call site. Test that service tests can construct the fake without filesystem paths or `Process` execution.

- [ ] **Step 2: Run the focused tests and confirm missing protocol errors.**

  Run: `swift test --filter LockScreenSyncServiceTests`

  Expected: compilation fails because `LockScreenSystemClient` and the service do not exist.

- [ ] **Step 3: Implement `LockScreenSystemClient`.** Define a `Sendable` protocol with `probe()`, `install(media:aerialID:)`, `inspectRecovery()`, and `restore(transactionID:)`. Its production implementation must construct the existing `LockScreenProbe`, `LockScreenTransaction`, and `RecoveryCoordinator` with `LocalFileStore`, `AtomicJSONStore`, `SHA256Digester`, `AerialDiscovery`, `WallpaperIndexPatcher`, and `ProcessWallpaperRefresher`.

- [ ] **Step 4: Implement `ProcessGeneratedUIDProvider` and use it only in the production client factory.** Port the already-tested `dscl . -read <home> GeneratedUID` parsing behavior from `WallumeRestore/main.swift` into an injectable `GeneratedUIDProviding` protocol. On command, parse, or path failure, surface a typed client error and perform no system write. Do not modify the restore executable in this task.

- [ ] **Step 5: Re-run focused tests.**

  Run: `swift test --filter LockScreenSyncServiceTests`

  Expected: tests compile and the adapter fake is usable; behavioural tests remain red until Task 3.

- [ ] **Step 6: Commit the adapter boundary.**

  ```bash
  git add Sources/WallumeAppSupport/LockScreen/LockScreenSystemClient.swift Sources/WallumeAppSupport/LockScreen/ProcessGeneratedUIDProvider.swift Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift
  git commit -m "feat: add lock screen system client boundary"
  ```

## Task 3: Implement serial synchronization policy and startup reconciliation

**Files:**
- Create: `Sources/WallumeAppSupport/LockScreen/LockScreenSyncModels.swift`
- Create: `Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift`
- Modify: `Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift`

- [ ] **Step 1: Add failing policy tests.** Use the Task 2 fake client plus real temporary configuration storage. Cover: read-only initial probe; no default slot selection; explicit selection plus risk confirmation; same-media deduplication; no main assignment, offline main display, missing library item, and missing variant/cover entering wait with no client install/restore call; selected media switch issuing restore then install; and a failed install retaining enabled intent plus retryable error.

- [ ] **Step 2: Add failing recovery-reconciliation tests.** Cover: configured committed transaction retained; `prepared`, `writing`, or `restoring` transaction restored before re-evaluation; config-linked `conflicted` transaction blocks writes; multiple active/ambiguous candidates block writes; unique orphan committed candidate matching the selected slot restores before re-sync; and all other orphan cases require user repair. Verify every blocked state makes zero install calls.

- [ ] **Step 3: Run the focused test command.**

  Run: `swift test --filter LockScreenSyncServiceTests`

  Expected: failures for missing service state/actions and policy behavior.

- [ ] **Step 4: Implement the immutable state/action model.** Define `LockScreenSyncState` with the user-visible cases `unconfigured`, `probing`, `readyToConfigure`, `waitingForMainWallpaper`, `syncing`, `synced`, `restoring`, `needsRepair`, and `unsupported`. Include selected slot, probe summary, active transaction reference, synced media summary, last result/error, and explicit capability flags. Define `LockScreenSyncInput` from a `DisplayAssignmentSnapshot`, `[DesktopScreen]`, and media lookup rather than giving the service direct UI access.

- [ ] **Step 5: Implement `LockScreenSyncService` as an actor with one command channel.** It must expose `start()`, `apply(input:)`, `refreshProbe()`, `selectAerialSlot(_:)`, `confirmEnable()`, `disableAndRestore()`, `retry()`, `events()`, and `stopAcceptingNewCommandsAndWait()`. Serialize every action through actor state; coalesce repeated inputs while an operation is active and evaluate the latest one after reaching a safe endpoint. The service must not create files or call the transaction before `confirmEnable()`.

- [ ] **Step 6: Implement startup alignment before automatic writes.** Load configuration, inspect journals, then apply the exact reconciliation matrix from the approved design. `committed` matching config is current; incomplete phases restore first; conflicts/multiple unknown candidates fail closed; the narrowly allowed unique matching orphan committed journal is restored then re-evaluated. Persist configuration only after the related recovery/install operation reaches its verified endpoint.

- [ ] **Step 7: Implement source resolution and conservative transitions.** Select only the connected `DesktopScreen.isMain` record and its assigned media. Require existing regular `variantURL` and `coverURL`. On the same `lastSyncedMediaID`, publish synced without writing. On a changed media ID with active transaction, call restore and require an empty conflict report before clearing its reference and calling install. If source is unavailable, publish waiting and leave an active transaction untouched.

- [ ] **Step 8: Implement disable and retry semantics.** Disable always restores the active transaction. Only after a no-conflict report is complete may configuration be saved as disabled/cleared. A conflict leaves enabled intent, journal reference, and backups intact in `needsRepair`. Retry repeats probe/reconciliation and then evaluates the latest input; it never assumes a previous write succeeded.

- [ ] **Step 9: Re-run all lock-screen service tests.**

  Run: `swift test --filter LockScreenSyncServiceTests`

  Expected: PASS, including zero-system-path fixture assertions.

- [ ] **Step 10: Commit the synchronization service.**

  ```bash
  git add Sources/WallumeAppSupport/LockScreen/LockScreenSyncModels.swift Sources/WallumeAppSupport/LockScreen/LockScreenSyncService.swift Tests/WallumeAppSupportTests/LockScreenSyncServiceTests.swift
  git commit -m "feat: synchronize lock screen with main display"
  ```

## Task 4: Add the observable feature store and Lock Screen page

**Files:**
- Create: `Sources/WallumeAppSupport/LockScreen/LockScreenFeatureStore.swift`
- Create: `Sources/WallumeAppSupport/UI/LockScreenView.swift`
- Create: `Tests/WallumeAppSupportTests/LockScreenFeatureStoreTests.swift`
- Create: `Tests/WallumeAppSupportTests/LockScreenViewTests.swift`

- [ ] **Step 1: Write failing feature-store tests.** Verify the store mirrors service snapshots; commands dispatch refresh, selection, confirmation, retry, and restore without direct file IO; command errors remain visible until a later successful snapshot; and page deinitialization cancels only its event-observation task, not the service.

- [ ] **Step 2: Write failing view/state tests.** Test a pure page-view model for: disabled/unconfigured setup CTA; no-slot guidance; slot selection and separate risk-confirmation gate; waiting state; synced state with media name/time; repair state with restore/retry actions; and unsupported state with no enable action. Keep SwiftUI smoke tests structural—do not require system-wallpaper access.

- [ ] **Step 3: Run focused UI tests.**

  Run: `swift test --filter LockScreenFeatureStoreTests && swift test --filter LockScreenViewTests`

  Expected: compilation failures until the store/view exist.

- [ ] **Step 4: Implement `LockScreenFeatureStore`.** Make it `@MainActor @Observable`, own an observation task for `LockScreenSyncService.events()`, expose a stable page state and `pageError`, and wrap each action in the same error-publication pattern used by `DisplayFeatureStore`. It must not invoke `Process`, `FileManager`, or Core transaction types directly.

- [ ] **Step 5: Implement `LockScreenView`.** Render probe capability details, selected Aerial slot, the pending confirmation sheet, waiting/sync/recovery status, a concise backup/recovery explanation, and clear next actions. Add an injected `openSystemWallpaperSettings` closure that the application supplies; selection alone must never enable sync. Use Chinese user-facing text that specifies whether the next safe action is refresh, choose a slot, retry, restore, or open system settings.

- [ ] **Step 6: Re-run focused UI tests.**

  Run: `swift test --filter LockScreenFeatureStoreTests && swift test --filter LockScreenViewTests`

  Expected: PASS.

- [ ] **Step 7: Commit the presentation layer.**

  ```bash
  git add Sources/WallumeAppSupport/LockScreen/LockScreenFeatureStore.swift Sources/WallumeAppSupport/UI/LockScreenView.swift Tests/WallumeAppSupportTests/LockScreenFeatureStoreTests.swift Tests/WallumeAppSupportTests/LockScreenViewTests.swift
  git commit -m "feat: add lock screen setup page"
  ```

## Task 5: Compose the service into the application without coupling desktop runtime

**Files:**
- Modify: `Sources/WallumeApp/ApplicationController.swift`
- Modify: `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`
- Modify: `Sources/WallumeAppSupport/UI/FeatureRegistry.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift`

- [ ] **Step 1: Write failing composition/shell tests.** Assert Lock Screen is enabled while Performance and Settings remain disabled; `ApplicationShellView` routes `.lockScreen` only when supplied a lock-screen store; no Lock Screen store preserves the unavailable fallback; and ApplicationController-level wiring can produce one service/store without constructing production system paths in a unit test.

- [ ] **Step 2: Run focused composition tests.**

  Run: `swift test --filter ApplicationShellViewTests && swift test --filter ApplicationCompositionTests`

  Expected: registry/router assertions fail before integration.

- [ ] **Step 3: Compose production dependencies.** In `ApplicationController`, derive the user GeneratedUID through the new provider only when constructing the real lock-screen client; construct configuration at `~/Library/Application Support/Wallume/lock-screen-sync.json`; build one service and one feature store. A UID/client construction error must create a service in visible `needsRepair`/unavailable state, not crash launch and not affect runtime construction.

- [ ] **Step 4: Connect lifecycle and input flow.** Start lock-screen reconciliation after display assignments load. Whenever assignment events, runtime-triggered display metadata refreshes, or imports complete, send the latest assignment snapshot, `screens.screens`, and a media lookup/list snapshot to the service. Starting or failing this service must not gate `runtimeService.start`. Window closure leaves it running; `applicationShouldTerminate` first calls `stopAcceptingNewCommandsAndWait()` before `runtimeService.stop()`.

- [ ] **Step 5: Enable and route the page.** Mark `.lockScreen` enabled in `FeatureRegistry`, pass the feature store into `ApplicationShellView`, and route it to `LockScreenView`. Supply the injected system-settings opener through `NSWorkspace.shared.open` using the Desktop & Dock/Wallpaper system-preferences URL, with an error reported to the feature store if macOS refuses it.

- [ ] **Step 6: Re-run focused composition tests.**

  Run: `swift test --filter ApplicationShellViewTests && swift test --filter ApplicationCompositionTests`

  Expected: PASS.

- [ ] **Step 7: Commit app integration.**

  ```bash
  git add Sources/WallumeApp/ApplicationController.swift Sources/WallumeAppSupport/UI/ApplicationShellView.swift Sources/WallumeAppSupport/UI/FeatureRegistry.swift Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift
  git commit -m "feat: integrate lock screen sync into app"
  ```

## Task 6: Regression verification, safety review, and status record

**Files:**
- Modify: `docs/phase-four-status.md`
- Modify: `docs/progress-status.md`
- Modify: `docs/superpowers/plans/2026-07-17-lock-screen-application-sync.md` (check completed boxes only)

- [ ] **Step 1: Execute focused suites once more.**

  Run: `swift test --filter LockScreenConfigurationStoreTests && swift test --filter LockScreenSyncServiceTests && swift test --filter LockScreenFeatureStoreTests && swift test --filter LockScreenViewTests`

  Expected: PASS.

- [ ] **Step 2: Execute the full automated regression suite.**

  Run: `swift test`

  Expected: PASS with no skipped/failing new lock-screen tests.

- [ ] **Step 3: Build all release products.**

  Run: `swift build -c release --product WallumeApp && swift build -c release --product wallume-runtime && swift build -c release --product wallume-media && swift build -c release --product wallume-restore`

  Expected: all four products build successfully.

- [ ] **Step 4: Perform static safety checks.**

  Run: `git diff --check && rg -n '(/Library/Application Support/com\\.apple\\.wallpaper|/Library/Caches/Desktop Pictures)' Tests/WallumeAppSupportTests`

  Expected: `git diff --check` has no output; test sources contain no production system paths.

- [ ] **Step 5: Review the diff against the approved safety matrix.** Verify: selection/confirmation precede install; startup reconciliation precedes automatic writes; transitions restore before reinstall; disable only clears on conflict-free restore; configuration failures never overwrite the source; and runtime errors remain isolated. Record real-machine lock-screen testing, if unavailable, as pending manual acceptance—not as a fabricated result.

- [ ] **Step 6: Update status documents and plan checkboxes.** Record that Phase 4 batch 3 Lock Screen engineering and automated verification are complete, while real-device/system-wallpaper acceptance remains separately labeled if not performed. Preserve the no-push rule.

- [ ] **Step 7: Commit verification/status changes.**

  ```bash
  git add docs/phase-four-status.md docs/progress-status.md docs/superpowers/plans/2026-07-17-lock-screen-application-sync.md
  git commit -m "docs: record lock screen sync verification"
  ```

## Final Acceptance Checklist

- [ ] New Lock Screen page is reachable and Performance/Settings remain unavailable.
- [ ] First use is read-only until an Aerial slot is selected and the user confirms the risk.
- [ ] The main-display wallpaper drives sync; missing input produces waiting without writing/restoring.
- [ ] Same media is idempotent; changed media restores before a fresh install.
- [ ] Startup and disable paths preserve recoverability, fail closed on conflict, and never damage desktop wallpaper playback.
- [ ] Full tests and all four release builds pass; no production wallpaper directories occur in app-support tests.
- [ ] Changes remain local; `.vscode/` remains untouched and untracked.
