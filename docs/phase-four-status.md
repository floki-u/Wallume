# Phase four status

Updated: 2026-07-16

## Batch 1: application shell, gallery, and import experience

Implementation status: engineering complete pending final review and merge.

Delivered:

- AppKit application lifecycle, menu-bar status item, and releasable main window.
- Stable five-module SwiftUI navigation shell.
- Searchable lazy media gallery and on-demand muted details preview.
- Multi-file, multi-folder, recursive drag/drop scanning with hidden/package filtering.
- Strictly serial import queue with stage/progress reporting, cancel-current, cancel-all, failure continuation, and retry history.
- Background import continuation, conditional completion notifications, guarded deletion, and safe termination.

Not delivered in this batch: display assignment/control, lock-screen UI, performance UI, settings UI, localization, volume control, or final phase-four UI acceptance.

Verification: 194 tests passed with zero failures; release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; `git diff --check` passed.
