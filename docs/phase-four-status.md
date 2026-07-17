# Phase four status

Updated: 2026-07-17

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

- A Lock Screen page, enabled in navigation while Performance and Settings remain unavailable.
- Explicit Aerial-slot selection and a separate risk-confirmation gate before any lock-screen installation.
- Serial, main-display-driven synchronization with read-only startup reconciliation, idempotent same-media handling, restore-before-reinstall transitions, and conflict-safe disable/recovery behavior.
- Fail-closed configuration persistence and a narrow production system-client boundary that leaves desktop wallpaper runtime construction isolated from lock-screen failures.

Automated verification: focused lock-screen suites passed 85 tests with zero failures; `swift test` passed 335 tests with zero failures; Release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed; and the app-support test scan found no construction of production system-wallpaper file URLs. Inert fixture text used to prove unsafe persisted data is rejected is not a filesystem access.

Safety review: the implemented and tested paths require selection and confirmation before install, reconcile recovery before automatic writes, restore before a changed-media install, retain enabled configuration on restore conflict, and stop configuration mutations after a failed/changed source-file check.

Manual acceptance pending: no real-device/system-wallpaper installation, lock/unlock, or restoration exercise was performed in this verification. This remains a separate acceptance requirement and is not represented as an automated result.

## Remaining phase-four work

1. Performance and settings pages.
2. Localization, state restoration, UI acceptance, and phase-four completion.

Phase four as a whole is not yet complete.
