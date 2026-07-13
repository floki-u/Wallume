# Task 7 Report: Compare-and-Restore Recovery

## Result

Implemented recovery journal discovery and conservative three-state recovery for video,
poster, and wallpaper index mutations.

- `inspect()` reads the transactions directory, validates schema and journal identity,
  skips `.restored`, and stably sorts `.prepared`, `.writing`, `.committed`, and
  `.conflicted` candidates.
- Existing files restore through a verified same-directory prepared copy and atomic
  exchange. The displaced entity is verified against `installedHash`; mismatch or
  verification failure swaps back and verifies the restored external entity.
- Originally absent files move atomically and exclusively to same-directory quarantine,
  verify the moved entity, then either delete it or restore it exclusively.
- Index recovery uses one snapshot, restores only matching `after` fragments, stages in
  the same directory, exchanges atomically, and verifies the displaced snapshot.
- Values already equal to `original`/`before` are clean, not conflicts. Invalid plist,
  malformed manifests, corrupt journals, unknown schemas, missing/corrupt backups, and
  external changes fail closed.
- Backups are deleted only after every owned value is original and conflict-free.
  Refresh runs only when at least one target actually changed.

All tests use temporary directories and synthetic fixtures. No real wallpaper target is
read or written.

## TDD Evidence

### RED

1. Initial clean/conflict tests: `swift test --filter RecoveryCoordinatorTests` failed to
   compile with `cannot find type 'RecoveryCoordinator' in scope`.
2. Invalid external index test failed with unexpected
   `WallpaperIndexError.invalidPropertyList`; recovery then classified it as a preserved
   conflict.
3. Displaced-entity read failure test showed the target incorrectly remained original
   instead of being swapped back to installed; the guarded rollback path was added.
4. Inconsistent `originalHash`/`originalBackup` test failed because semantic manifest
   validation did not exist; validation now rejects it before mutation.

### GREEN

- `swift test --filter RecoveryCoordinatorTests`: 18 tests, 0 failures.
- `swift test --filter WallpaperIndexPatcherTests`: 16 tests, 0 failures.
- `swift test`: 65 tests, 0 failures.
- `git diff --check`: clean.

## Coverage

- Clean committed recovery and external video/index conflicts.
- Equivalent fixtures for every Task 6 fault point, including prepared/no-write and
  each partial writing boundary.
- Originally absent poster both installed and never-written cases.
- Missing and corrupt backups, partial index conflict, invalid external plist.
- Stable orphan-journal inspection, corrupt journal, unknown schema, malformed manifest.
- Repeated restore idempotence and refresh-only-on-change.
- Video exchange race, index snapshot race, quarantine race, displaced-entity read
  failure, and explicit exchange rollback failure.

## Self-review

The safety and spec review found one actionable high-risk issue: a malformed manifest
could pair a nil original hash with a non-nil backup and be mistaken for an originally
absent target. This is fixed with fail-closed manifest invariant validation and a
regression test. The review also prompted the guarded rollback test for a displaced
entity that cannot be read.

## Concerns

- Recovery-stage/quarantine files use unique names. A process crash inside recovery can
  strand a hidden same-directory artifact; the journal remains recoverable and backups
  remain conservative, but this task does not yet rediscover those stage artifacts.
- `.restored` and backup cleanup occur before calling the refresher. If refresh itself
  fails, the restored filesystem state is durable but a retry does not re-run refresh.
  Fully closing this window requires an explicit durable recovery/refresh-pending state,
  rather than guessing from already-original targets.
