# Task 4 report — Settings lifecycle completion and release verification

## Scope delivered

- Added an application-owned actor for the one in-flight Settings diagnostics export.
- Termination now cancels and awaits that export before service shutdown, without changing the established lock-screen → diagnostics → runtime order.
- Persisted ordinary settings are not modified by the cancellation path.
- No Settings UI, route, or earlier feature scope changed.

## TDD evidence

1. RED: `swift test --filter ApplicationCompositionTests` failed as expected because the termination composition had neither a settings-export cancellation operation nor an ownership seam.
2. GREEN: the same focused suite passed 8 tests after the owner was wired through `ApplicationController` and termination composition.
3. The new composition test holds a cancellable export in flight, verifies cancellation is awaited before service shutdown, checks persisted preference values, and records the exact settings-export → lock-screen → diagnostics → runtime sequence.

## Release verification

- `swift test`: 399 tests, 0 failures.
- `swift build -c release --product WallumeApp`: passed.
- `swift build -c release --product wallume-runtime`: passed.
- `swift build -c release --product wallume-media`: passed.
- `swift build -c release --product wallume-restore`: passed.
- `git diff --check`: passed.

## Status and concerns

Performance is already locally merged. Settings engineering and automated verification are complete. Manual localization, application state-restoration, Settings/whole-app UI acceptance, and real-system Lock Screen installation, lock/unlock, and restoration acceptance remain pending. No remote push was performed.

## Review remediation — terminal export ownership

- RED: `swift test --filter ApplicationCompositionTests` proved that, after cancelling an in-flight export, the prior coordinator still started a newly submitted export.
- GREEN: termination now marks the coordinator terminal before examining the in-flight task. It cancels and awaits any started export, while every later or crossing `perform` request rejects before its operation is invoked.
- Regression coverage holds one export in flight, terminates it, attempts another export, and proves the attempted operation never starts. The existing composition test continues to prove persisted preference values and lock-screen → diagnostics → runtime ordering.
- Verification: `swift test --filter ApplicationCompositionTests` (9 tests), `swift test --filter SettingsViewTests` (4 tests), `swift test --filter DiagnosticsExportServiceTests` (4 tests), full `swift test` (400 tests), and `git diff --check` all passed.

## Final review remediation

- `LocalFileStore.replace` now refuses a directory or symlink destination before `RENAME_SWAP` and removes the swapped-out entry only with `unlink` after a second no-follow regular-file check. A directory destination retains both its contents and the prepared file.
- The release gate was rerun because this changes core atomic I/O.

## Final commit-admission and Settings UI review

- Replaced the blocking `NSCondition` drain with an `NSLock`-protected admission state and checked continuations. Terminal marking remains synchronous with `beginCommit()`, while an actor calling `terminateAndWait()` now suspends instead of occupying a cooperative executor thread. Cancellation cannot bypass draining an admitted commit.
- Added deterministic regressions through the real `DiagnosticsExportService` → `AtomicJSONStore` → `FileStore` path. A pre-commit export blocked during snapshot preparation is rejected after admission becomes terminal and writes no destination. An export blocked inside `writeAtomically` keeps termination suspended, completes as valid JSON after release, and is treated as successful.
- Replaced constant Settings test flags with typed preference-control and diagnostics-action presentations that `SettingsView` itself renders. Coverage asserts all three production toggle labels plus ready, retry, and choose-another-destination actions; controller tests exercise both retrying the same destination and choosing a replacement destination after failure.
- Focused verification passed 39 tests across `DiagnosticsExportServiceTests`, `SettingsViewTests`, `ApplicationCompositionTests`, `ApplicationShellViewTests`, `SettingsStoreTests`, and `RuntimeEnvironmentMonitorTests`.
- Final local verification passed `swift test` with 405 tests and zero failures. Release-configuration builds completed for `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore`; `git diff --check` passed.
- Remaining acceptance is explicitly manual: Settings/whole-app UI acceptance, localization, application state restoration, and real-system Lock Screen installation, lock/unlock, and restoration. No packaged release or remote integration is claimed.

### Required two-axis review follow-up

- Replaced the bounded scheduler-yield admission probe with an explicit lock-protected termination signal, so the crossing-termination regression synchronizes on the actual terminal transition without timing assumptions.
- Consolidated the duplicated destination-selection/export path in `SettingsDiagnosticsExportController`.
- Made the page model the source for build and success rendering, retained typed labels/actions as the production `ForEach` inputs, and added hosting-view coverage that asserts the exact semantic identifiers for all three toggles plus select-destination, retry, and choose-another-destination. The controller-seeding initializer is internal to the app-support module.

### Final race-safety and presentation-model remediation

- Replaced `LocalFileStore.replace`'s `RENAME_SWAP` plus deferred recursive cleanup with a descriptor-relative `renameat` commit. Parent traversal and temporary creation use `openat`/`fstatat` with no-follow semantics. All throwable synchronization is preflighted before the rename commit; no error is reported after old bytes cease to be addressable.
- Failed installs intentionally retain their uniquely named prepared regular file. This avoids macOS's unavoidable pathname identity race between a metadata check and `unlinkat`; no error path recursively removes, follows, or unlinks an entry that an external actor may have substituted.
- Added a deterministic pre-commit race hook and regression that replaces the destination with a populated directory. The kernel rejects the file-over-directory rename, the sentinel contents survive, and the fully synchronized prepared bytes remain available.
- Moved the lock-screen diagnostics snapshot into the testable application composition seam and removed its summary-only updater. Every event now derives both the exported summary and current-error presence from the same complete `LockScreenSyncState`; a regression proves a later healthy event clears a prior error.
- Removed the inert AppKit accessibility bridge and private hosting-view traversal. Settings now renders from a typed control presentation carrying stable identity, role, enabled state, and production action; tests assert the exact toggle/button action model used by the `ForEach` controls.
- Verification: focused `AtomicIOTests` (18), `ApplicationCompositionTests` (10), and `SettingsViewTests` (6) passed. Full `swift test` passed 407 tests with zero failures. Release builds passed for `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore`; `git diff --check` passed before commit.

### Post-commit durability follow-up

- A successful `renameat` no longer suppresses a failing post-rename directory sync. The same no-follow parent descriptors remain open across `renameat` and both required `fsync` calls, preventing a parent-path replacement from redirecting the durability check.
- The new `AtomicFileStoreError.durabilityUncertain(destination)` explicitly distinguishes a post-commit durability failure from a pre-commit write failure. Its contract is intentional: the new document may already be visible, so callers must inspect the destination before retrying and must never infer that prior bytes survived.
- `AtomicJSONStore` documents and propagates this contract. An audit confirmed every production JSON writer propagates its throwing write result; Diagnostics export maps the error to `destinationMayContainExport` with an inspect-before-retry message instead of the ordinary retry-safe failure.
- Regressions inject a post-rename sync failure, prove the exact durable-commit error, prove the newly committed bytes remain readable, and prove unrelated populated directories and symlinks are untouched. A diagnostics regression proves the high-level user error is surfaced while the completed export remains decodable.
- Verification: `AtomicIOTests` (20) and `DiagnosticsExportServiceTests` (7) passed before final full-suite and release verification.
