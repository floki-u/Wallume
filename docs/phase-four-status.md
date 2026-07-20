# Phase four status

Updated: 2026-07-20

## Batch 1: application shell, gallery, and import experience

Implementation status: engineering complete and approved for local merge.

Delivered:

- AppKit application lifecycle, menu-bar status item, and releasable main window.
- Stable five-module SwiftUI navigation shell.
- Searchable lazy media gallery and on-demand muted details preview.
- Multi-file, multi-folder, recursive drag/drop scanning with hidden/package filtering.
- Strictly serial import queue with stage/progress reporting, cancel-current, cancel-all, failure continuation, and retry history.
- Background import continuation, conditional completion notifications, guarded deletion, and safe termination.

Not delivered in this batch: display assignment/control, lock-screen UI, performance UI, settings UI, localization, volume control, or final phase-four UI acceptance.

Verification: 203 tests passed with zero failures; release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed. Completion review found no remaining Critical or Important issues.

## Batch 2: display assignment and playback control

Implementation status: engineering complete and ready for local merge.

Delivered:

- Stable display identities with connected and remembered-disconnected display catalog entries.
- Versioned, atomic assignment persistence with conservative corruption handling and version-one migration.
- Multi-display assignment from media details, including per-target context and Select All.
- Displays page cards with replace, remove, retry, and clear-remembered-configuration actions.
- Per-display Fill, Fit, and Stretch presentation modes, defaulting to Fill.
- Automatic assignment restoration when a remembered display reconnects.
- A single in-process wallpaper runtime that survives main-window close and shares players across displays.
- Persisted global pause/resume composed with system pause reasons and exposed in the app and status menu.
- Per-display player and desktop-surface failure reporting without interrupting successful displays.
- Muted playback; volume control remains intentionally deferred.

Automated verification after completion-review fixes: `swift test` passed 247 tests with zero failures; release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed.

Completion review: all findings were resolved with regression coverage; final re-review found no remaining Critical or Important issues.

Deferred: true hardware performance certification cannot be completed on the currently available machine.

## Batch 3: lock-screen synchronization

Implementation status: engineering and automated verification complete; real-machine system-wallpaper acceptance remains pending.

Delivered:

- A Lock Screen page, enabled in navigation. At this batch's completion, Performance and Settings were intentionally unavailable; both are now enabled.
- Explicit Aerial-slot selection and a separate risk-confirmation gate before any lock-screen installation.
- Serial, main-display-driven synchronization with read-only startup reconciliation, idempotent same-media handling, restore-before-reinstall transitions, and conflict-safe disable/recovery behavior.
- Fail-closed configuration persistence and a narrow production system-client boundary that leaves desktop wallpaper runtime construction isolated from lock-screen failures.

Automated verification: focused lock-screen suites passed 86 tests with zero failures; `swift test` passed 336 tests with zero failures; Release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed; and the app-support test scan found no construction of production system-wallpaper file URLs. Inert fixture text used to prove unsafe persisted data is rejected is not a filesystem access.

Safety review: the implemented and tested paths require selection and confirmation before install, reconcile recovery before automatic writes, restore before a changed-media install, retain enabled configuration on restore conflict, and stop configuration mutations after a failed/changed source-file check.

Manual acceptance pending: no real-device/system-wallpaper installation, lock/unlock, or restoration exercise was performed in this verification. This remains a separate acceptance requirement and is not represented as an automated result.

## Batch 4: performance diagnostics

Implementation status: engineering and automated/current-machine verification complete; locally merged.

Delivered:

- Page-scoped, in-memory one-per-second realtime process metrics with a 60-sample cap.
- User-triggered serial 30-second diagnostic with cancellation, local atomic persistence, retry-save, and anonymous JSON export.
- Count-only wallpaper runtime context; no media identifiers, paths, URLs, thumbnails, backup data, uploads, or runtime-control side effects.
- One application-owned diagnostics service/store; Performance is enabled. Settings remained unavailable at this batch's completion and is now enabled. Runtime snapshots are forwarded to diagnostics, and application termination stops diagnostics before the desktop runtime.

Verification: `swift test` passed 378 tests with zero failures; release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed. A production-service reference diagnostic completed on the current machine with exactly 30 samples over 30 seconds and was retained at `~/Library/Application Support/Wallume/Diagnostics/report.json`. Reference environment only (not M1 certification): Apple M4, 51,539,607,552 bytes physical memory, macOS 26, `single-display` scenario.

## Batch 5: settings lifecycle completion

Implementation status: engineering and automated verification complete; pending the remaining phase-four manual acceptance work.

Delivered:

- Application-owned cancellation and awaiting of an in-flight Settings diagnostics export during termination.
- Persisted ordinary preferences remain intact when termination cancels an incomplete export.
- The established shutdown order remains lock-screen, diagnostics, then desktop runtime; export cancellation completes before that sequence.
- No Settings controls, routes, or direct system/filesystem/runtime side effects were added.

Initial completion verification: `swift test` passed 399 tests with zero failures; release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed. Review-remediation verification: `swift test` passed 400 tests with zero failures; focused composition, Settings view, and diagnostics-export suites plus `git diff --check` passed. The focused composition suite includes cancellation, preference-preservation, exact shutdown-order, and post-termination export-rejection coverage.

## Remaining phase-four work

1. Localization and application state restoration.
2. Manual Settings and whole-application UI acceptance.
3. Real-device/system-wallpaper installation, lock/unlock, and restoration acceptance for Lock Screen.
4. Final phase-four completion review.

Phase four as a whole is not yet complete.
