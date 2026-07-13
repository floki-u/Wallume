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

Closed by the follow-up below. No known concerns remain.

## Safety Follow-up

The initial review concerns were resolved in a second strict TDD cycle:

- Added schema-2 `.restoring`, written durably before the first target-changing recovery
  primitive. Schema-1 journals remain readable but cannot claim the v2-only phase;
  unknown schemas remain rejected.
- Refresh now runs while the journal is `.restoring`. Failure retains backups and all
  recognized artifacts; retry refreshes even when targets are already original. Cleanup
  and `.restored`/`.conflicted` are written only after refresh succeeds.
- Replaced random artifact suffixes with manifest-id/target/role deterministic paths.
  Restart reconciliation covers pre-exchange stage, post-exchange displaced entity,
  absent-target quarantine, index complete/partial restore, and cleanup-capture crashes.
- Artifact creation uses exclusive atomic write/copy primitives. Artifact cleanup uses
  an atomic same-directory cleanup quarantine, validates the moved entity, and restores
  it on mismatch. Unknown or raced artifact combinations remain present and force a
  conflict with backups retained.
- Synchronous recovery calls are serialized in-process so deterministic artifacts cannot
  be shared by concurrent callers.

### Follow-up RED

1. Crash-artifact and refresh-retry tests failed to compile because `.restoring` did not
   exist.
2. External Index target/artifact equality test showed an unexplained artifact was
   deleted; cleanup now requires a fully-before state or a proven restore relationship.
3. Stage-creation race showed an external artifact was overwritten, and cleanup race
   showed changed artifact bytes were deleted. Exclusive creation and guarded cleanup
   fixed both failures.
4. A last-instant artifact change before exchange initially installed unverified bytes;
   recovery now swaps back, verifies the installed target, preserves the artifact, and
   reports conflict.
5. A late target change after artifact cleanup initially produced a conflicted journal
   without naming the target in `RecoveryReport`; final per-record verification now
   appends the exact target conflict and retains backups.

### Follow-up GREEN

- `swift test --filter RecoveryCoordinatorTests`: 33 tests, 0 failures.
- `swift test --filter AtomicIOTests`: 11 tests, 0 failures.
- `swift test --filter LockScreenTransactionTests`: 14 tests, 0 failures.
- `swift test --filter WallpaperIndexPatcherTests`: 16 tests, 0 failures.
- `swift test`: 81 tests, 0 failures.
- `git diff --check`: clean.

## Trust-Boundary and Cross-Process Follow-up

The final review batch tightened recovery around hostile journals, concurrent processes,
and deletion races:

- New installs write schema 2; schema 1 remains readable, while unknown schemas and
  schema-1-only misuse of v2 recovery fields fail closed.
- Recovery validates every journal URL against `AerialPaths` before deriving artifacts
  or mutating anything. Video, poster, index, primary/recovery backups, and poster backup
  must match their canonical transaction-derived locations; traversal and symlink escape
  are rejected.
- Install and restore share an injectable Darwin `flock` advisory lock at a fixed file
  under application support. Independent lock instances serialize across processes.
- Cleanup captures are stored in manifest-scoped, owner-only `0700` directories beside
  each target. Deletion uses parent-directory descriptors, no-follow inode identity,
  `unlinkat`, and parent `fsync`; identity mismatch retains the unknown entity and records
  a conflict. Ordinary successful removal also syncs its parent directory.
- Backup hashes are revalidated as a complete set before cleanup. Cleanup authorization
  is journaled before the first deletion so a crash between backup deletions can converge,
  while changed backups remain untouched and force a conflict.
- Video, poster, and index ownership are re-read after refresh and artifact cleanup.
  Final index ownership requires `restore` to report no restored paths and no conflicts;
  a late index write therefore retains all backups.

### Final Follow-up RED

1. Schema and durable-remove tests showed new writers still emitted v1 and `remove` did
   not synchronize its parent.
2. A malicious target URL was accepted before allowlist validation and could reach the
   recovery mutation path.
3. A refresh-time index write was absent from the final report, and a changed redundant
   backup was deleted.
4. Replacing a validated cleanup capture immediately before deletion showed the old
   path-based unlink could remove an unowned inode.
5. Two independent advisory locks initially had no shared cross-process exclusion.

### Final Follow-up GREEN

- Focused recovery/atomic-I/O/transaction/patcher suite: 81 tests, 0 failures.
- Full package suite: 89 tests, 0 failures.
- `git diff --check`: clean.
- Includes malicious sentinel URL, late index ownership, changed backup, authorized
  partial-cleanup restart, last-instant capture replacement, durable parent sync, schema
  v2 writer, and independent advisory lock competition regressions.

## Second Safety Review Follow-up

- Recovery now rejects symlinks in every existing component of each canonical target,
  backup, and manifest-scoped cleanup path before mutation. A same-origin resolved-path
  comparison is not treated as proof; traversal uses `fstatat(..., AT_SYMLINK_NOFOLLOW)`
  and `openat(..., O_NOFOLLOW)` component by component.
- Install acquires the shared advisory lock immediately after the unsupported-OS gate,
  before discovery, foreign-backup scanning, hashing, index reads, or plist planning.
  Backups use exclusive creation, so a waiting install re-reads post-lock state and can
  never overwrite the first install's primary backup.
- Authorized backup cleanup recognizes a missing source plus its derived cleanup capture,
  verifies capture ownership, and completes guarded durable deletion. Changed captures
  remain listed in retained backup material and force conflict.
- Before final phase, recovery inventories every cleanup directory derived from manifest
  targets and backups. Empty directories are durably removed, known captures are handled
  by their owning recovery path, and unknown entries remain with a corresponding conflict.
- Guarded removal opens every parent component without following symlinks, then performs
  the inode identity check and `unlinkat` through that descriptor before parent `fsync`.

### Explicit threat model

The cleanup protocol protects against concurrent Wallume processes, crashes, and ordinary
external rewrites. Its transaction-specific directory is owner-only (`0700`), and Wallume
holds the cross-process `flock`. macOS provides no atomic compare-inode-and-unlink primitive,
so this implementation does not claim protection from an active same-UID attacker that can
precisely replace a private-directory entry in the final syscall window.

### Second Review RED

1. A symlinked Aerial videos directory redirected recovery into a sentinel tree; the
   sentinel video was modified and refresh ran.
2. A waiting install could perform discovery and hashing before attempting the lock, and
   the non-exclusive backup copy overwrote the first install's primary backup.
3. An authorized backup already moved into its cleanup capture was treated as deleted;
   restart left both capture and cleanup directory behind while marking restored.
4. An empty cleanup directory survived finalization, while an unknown cleanup entry did
   not conflict its target and allowed backup deletion.
5. A symlinked parent containing a hard link to the expected inode let the old path-based
   parent open unlink the sentinel entry.

### Second Review GREEN

- Focused recovery/atomic-I/O/transaction/patcher suite: 89 tests, 0 failures.
- Full package suite: 96 tests, 0 failures.
- `git diff --check`: clean.
- Regression coverage includes directory-symlink sentinel rejection, two-install lock
  ordering and primary-backup preservation, owned/unowned backup captures, empty/unknown
  cleanup directories, and no-follow guarded deletion through a symlinked parent.

## Third Safety Review Follow-up

- Added a shared `PathSafetyValidator` used by install and recovery. It combines
  component-by-component no-follow traversal with explicit existing/maybe-missing
  regular-file and directory requirements.
- Every deterministic restore/quarantine/index/cleanup artifact is validated before any
  read, hash, exchange, exclusive install, or reconciliation. Symlink artifacts remain
  untouched, never enter system targets, and retain the whole backup set.
- Transaction preflight runs once before lock-file creation for zero-mutation rejection,
  then again while holding the flock. Transaction-id-derived backup, journal, and stage
  paths are validated before discovery, hashing, index reads, planning, or directory writes.
- Backup cleanup now validates the complete unique group before durable authorization.
  Source-only, owned-capture-only, and previously-authorized-complete are the only accepted
  states; source-plus-capture, non-regular entries, bad hashes, and unknown cleanup entries
  block deletion of every backup.
- Restore and inspect validate the transactions directory and journal as no-follow regular
  files before decoding. External manifests reached through journal or parent symlinks
  cannot drive recovery or receive a writeback.

### Third Review RED

1. A journal symlink drove a full restore from an external valid manifest.
2. Video `.restore` symlinks could be atomically exchanged into the target and remove the
   primary backup referent; index and poster deterministic stages had the same trust gap.
3. Install had no explicit unsafe-path preflight for symlinked videos, Store, or backup
   directories.
4. A source-plus-capture ambiguity on the first backup allowed later backups in the group
   to be deleted before the conflict was finalized.

### Third Review GREEN

- Focused recovery/atomic-I/O/transaction/patcher suite: 99 tests, 0 failures.
- Full package suite: 106 tests, 0 failures.
- `git diff --check`: clean.
- Covers video/index/poster stage symlinks, journal and transactions-parent symlinks,
  install sentinel trees, and all-or-nothing backup-group rejection.
