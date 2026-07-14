# Task 6 Report: Durable Lock-Screen Install Transaction

## Status

Complete.

## TDD Evidence

### RED 1: public transaction seam

Command: `swift test --filter LockScreenTransactionTests`

Result: compilation failed as expected. The compiler reported that
`WallpaperRefreshing`, `TransactionFaultPoint`, `FaultInjecting`,
`LockScreenTransaction`, `LockScreenTransactionRequest`, and
`LockScreenTransactionManifest` were not in scope.

### GREEN 1: successful install and recoverable video failure

Command: `swift test --filter LockScreenTransactionTests`

Result: 2 tests executed with 0 failures. The successful path persisted a
committed manifest after replacement verification and refresh; the injected
failure after video replacement left a readable writing manifest with both
video backups present.

### RED 2: stable primary-backup path

Command: `swift test --filter LockScreenTransactionTests`

Result: 5 tests executed with 1 expected failure. The new exact backup-name
assertion found `AERIAL-ONE.mov..app.wallume.Wallume.original` instead of
`AERIAL-ONE.mov.app.wallume.Wallume.original`.

### GREEN 2: complete focused transaction suite

Command: `swift test --filter LockScreenTransactionTests`

Result: 9 tests executed with 0 failures.

### Full verification

Command: `swift test`

Result: 38 tests executed with 0 failures and no warnings.

Command: `git diff --check`

Result: exited successfully with no whitespace errors.

## Implementation Summary

- Added the Codable, Sendable transaction phase, request, replacement record,
  and durable manifest schema. Persisted plist mutations retain Task 5's stable
  `choiceIdentity` through synthesized Codable conformance.
- Added injected `WallpaperRefreshing` and `FaultInjecting` boundaries plus a
  no-op production fault injector.
- Added a dependency-injected install state machine with no singleton or new
  dependency.
- Unsupported OS generations are rejected before discovery, hashing, or any
  directory creation.
- Discovery, input hashing, index reading, mutation planning, and mutation
  application complete before any backup or system-target change.
- The conventional primary video backup, independent recovery video backup,
  and optional existing-poster backup are copied and hash-verified before the
  prepared journal is written.
- The prepared journal is durably written before the first system-target
  replacement, and the same journal is durably advanced to writing before that
  replacement.
- Video, index, and poster changes are staged beside their targets, atomically
  replaced, and verified before moving to the next boundary.
- Committed is persisted only after all three targets verify, refresh succeeds,
  and the final injected boundary returns successfully.

## Coverage and Safety

- Covers all five injected fault boundaries and verifies their last durable
  phase, refresh count, and absence of a committed journal.
- Covers corruption of each of the two video backups and the existing-poster
  backup; every case fails before a prepared journal or target replacement.
- Covers corruption after video, index, and poster replacement; every case
  remains writing and cannot advance to later replacements or refresh.
- Covers refresh failure, an absent original poster, invalid index planning,
  stable primary-backup naming, and exact transition ordering.
- Every test uses a UUID-scoped temporary root and synthetic manifest/index/file
  data. The absolute poster URL is translated by the injected test file store
  into that temporary root, and the injected test digester reads through the
  same store. No test accesses the real wallpaper application-support or cache
  directories.

## Self-review

- Re-read the Task 6 brief line by line and checked each ordered transition
  against `install(_:)` and a focused observable-behavior test.
- Every dependency required by the brief is constructor-injected, including
  time and transaction ID generation.
- The writing journal is recoverable at every post-prepared failure point and
  contains verified backup locations plus reversible plist mutations.
- Prepared source files are unique per transaction and located in the target's
  parent directory, so every target replacement uses a same-directory rename.
- Scope is restricted to the three requested production files, the requested
  focused test file, and this report.

## Concerns

None.

---

## Reviewer Remediation: Replacement-Time TOCTOU Conflicts

### Root Cause

The initial transaction captured video, index, and poster state before backup
and journal preparation, then later replaced all three targets without a fresh
compare. A macOS or third-party write in that interval was therefore overwritten
despite the transaction's earlier preflight.

### TDD RED Evidence

#### Video race

Command:
`swift test --filter LockScreenTransactionTests/testVideoChangedAfterPreflightIsPreservedAndAbortsBeforeReplacement`

Result: 1 test executed with 7 assertion failures. Install did not throw, the
external video was overwritten, video/index/poster replacements and refresh all
ran, and the journal became committed.

#### Index race

Command:
`swift test --filter LockScreenTransactionTests/testIndexChangedAfterPlanningIsPreservedAndAbortsBeforeReplacement`

Result: 1 test executed with 6 assertion failures. Install did not throw, the
external valid plist was overwritten by the early precomputed replacement,
poster replacement and refresh ran, and the journal became committed.

The race seam was then narrowed to the prepared-index staging interval. Before
the final compare was added, the same command again executed 1 test with 6
failures and proved that a change immediately before `replace` was overwritten.

#### Existing poster race

Command:
`swift test --filter LockScreenTransactionTests/testExistingPosterChangedBeforeReplacementIsPreservedAndAborts`

Result: 1 test executed with 5 assertion failures. Install did not throw, the
external poster was overwritten, refresh ran, and the journal became committed.

### GREEN Evidence

- The three single-race commands each executed 1 test with 0 failures after
  their corresponding compare-before fix.
- The absent-original-poster race command executed 1 test with 0 failures and
  verifies that a newly created external poster is preserved.
- `swift test --filter LockScreenTransactionTests` executed 13 tests with 0
  failures.
- `swift test` executed 42 tests with 0 failures and no warnings.
- `git diff --check` exited successfully with no whitespace errors.

### Implementation

- Added `LockScreenTransactionError.targetChanged(URL)` for video and poster
  compare conflicts.
- Video staging is followed immediately by a SHA-256 comparison against the
  initially captured original hash before the slot replacement.
- Poster staging is followed by an existence/hash comparison matching the
  initial state. An initially absent poster must remain absent; an initially
  present poster must remain present with the same hash.
- Removed the early precomputed index replacement. At the index step, the
  transaction reads current bytes and applies the persisted Task 5 mutations,
  so both compare-before and stable choice identity are checked.
- After staging the index sibling, the transaction re-reads the source index,
  applies the mutations again for Task 5 validation, and compares the latest
  source bytes with the step-local snapshot before replacement. This catches
  changes during staging without relying on potentially non-deterministic bytes
  from two independent binary-plist serializations.
- Existing prepared/writing journal transitions, failure points, and the
  no-automatic-rollback policy are unchanged.

### Test Safety and Observations

- The injected `FileStore` writes synthetic external content only after the
  relevant prepared sibling is created and before the real target replacement.
- Each race test asserts the external target's semantic or literal contents,
  the absence of the corresponding/later replacements and refresh, a writing
  journal, and no committed journal event.
- Poster coverage includes both an initially existing file changed externally
  and an initially absent file created externally.
- All filesystem activity remains inside UUID-scoped temporary roots; the
  absolute poster path continues to be translated by the test file store.

### Self-review

- Video and poster compare after staging, placing their preflight directly next
  to replacement.
- Index uses current data at its own step rather than the install-start bytes,
  and performs a second validation after staging to close that additional
  window.
- Index external content is checked semantically (`selectedID`) rather than by
  binary-plist byte equality; production source-snapshot comparison remains
  byte-exact and fail-closed.
- Conflict paths leave the durable journal in writing, preserve external
  content, and do not perform whole-file rollback.

### Concerns

None.

---

## Second Reviewer Remediation: Atomic Guarded Replacement

### Root Cause

The prior compare immediately before an unconditional rename still had an
unavoidable TOCTOU window: another writer could change the target after the
compare returned and before rename entered the kernel. No number of caller-side
reads can close that window.

### TDD RED Evidence

#### Atomic filesystem primitives

Command:
`swift test --filter AtomicIOTests/testAtomicExchangeSwapsTwoExistingFiles`

Result: compilation failed because `LocalFileStore` had no `exchange` or
`installExclusively` members.

#### Last-instant video race

The test store moved its external write into the `exchange` method immediately
before the real atomic operation. Command:
`swift test --filter LockScreenTransactionTests/testVideoChangedAfterPreflightIsPreservedAndAbortsBeforeReplacement`

Result: 1 test executed with 8 failures. The old transaction never called
exchange, did not throw, overwrote the external video through replace, continued
through index/poster/refresh, and committed.

#### Last-instant index race

Command:
`swift test --filter LockScreenTransactionTests/testIndexChangedAfterPlanningIsPreservedAndAbortsBeforeReplacement`

Result: 1 test executed with 7 failures. The old transaction bypassed exchange,
overwrote the external plist, continued to poster/refresh, and committed.

#### Last-instant existing-poster race

Command:
`swift test --filter LockScreenTransactionTests/testExistingPosterChangedBeforeReplacementIsPreservedAndAborts`

Result: 1 test executed with 6 failures. The old transaction bypassed exchange,
overwrote the external poster, refreshed, and committed.

#### Rollback-failure mutation RED

The common guarded helper already mapped rollback failure to the serious error
when its dedicated test was added. To prove sensitivity, the mapping was
temporarily mutated to pass through the injected error, then this command ran:
`swift test --filter LockScreenTransactionTests/testMismatchRollbackFailureIsReportedAsSeriousRecoveryFailure`

Result: 1 test executed with 1 failure because it observed `injected` rather
than `guardedReplacementRecoveryFailed`. Restoring the mapping made the same
test execute once with 0 failures.

### Implementation

- Extended `FileStore` with `exchange(_:with:)` and
  `installExclusively(_:from:)`.
- `LocalFileStore` implements these with macOS `renameatx_np` using
  `RENAME_SWAP` and `RENAME_EXCL`, followed by parent-directory fsync. The
  exchange synchronizes both parents when they differ. If synchronization fails
  after a successful exchange, it exchanges the names back; failed rollback or
  failed rollback synchronization reports `AtomicFileStoreError.exchangeRecoveryFailed`.
- Existing video, index, and poster targets are replaced by atomic exchange.
  The prepared sibling then contains the exact target inode/content that won
  immediately before the exchange.
- Video and existing-poster guards hash the swapped-out file and compare it to
  the expected original hash. Index compares the swapped-out bytes exactly to
  the current snapshot used by Task 5 `patcher.apply` at the index step.
- On mismatch, transaction immediately exchanges the files back and verifies
  the external hash/bytes at the target before throwing `targetChanged`.
- If rollback exchange or restoration verification fails, transaction throws
  explicit `guardedReplacementRecoveryFailed` and does not claim safety.
- An initially absent poster uses the exclusive atomic move. If an external
  poster appears first, `EEXIST` maps to `targetChanged`; the external target
  and prepared installation file are both retained.
- Matching exchanges verify installed target content, remove the swapped-out
  prepared sibling, and retain the existing fault-point ordering.

### Tests and Safety

- Atomic exchange test verifies both files swap; exclusive-conflict test
  verifies neither existing target nor prepared file is modified.
- Successful transaction ordering now observes video/index/poster exchanges.
  The initially absent-poster success path explicitly observes exclusive move.
- Three race tests inject only inside the guarded primitive immediately before
  the Darwin operation. Each verifies external content restored at target,
  writing journal, no commit, and no later replacement/refresh.
- Rollback-failure test verifies the installed candidate remains at target, the
  external content remains recoverable at the prepared sibling, only one
  exchange completed, and no later step or commit occurred.
- All tests continue to use UUID-scoped temporary roots and the mapped synthetic
  poster location; no real wallpaper or system cache path is accessed.

### GREEN Verification

- `swift test --filter AtomicIOTests`: 10 tests, 0 failures.
- `swift test --filter LockScreenTransactionTests`: 14 tests, 0 failures.
- `swift test`: 46 tests, 0 failures and no warnings.
- `git diff --check`: no whitespace errors.

### Self-review

- The safety decision is based on what the kernel atomically swapped out, not a
  caller-side preflight followed by rename.
- Index replacement bytes derive from the same current snapshot later recovered
  at the prepared path and compared byte-for-byte after exchange.
- External mismatch content is restored before `targetChanged` is returned;
  restoration uncertainty has a distinct severe error.
- Prepared files remain same-directory, durable prepared/writing journal
  transitions are unchanged, no whole-file automatic rollback is introduced
  beyond the immediate guarded-exchange mismatch correction, and no third-party
  dependency was added.

### Concerns

None.

#### Exchange synchronization recovery TDD

Command:
`swift test --filter AtomicIOTests/testExchangeSynchronizationFailureRestoresOriginalNames`

RED result: compilation failed because `AtomicFileStoreError` did not exist.

GREEN result: 1 test executed with 0 failures. An injected directory-sync
failure after the real swap caused an immediate swap-back; both original names
and contents were restored, while the second injected sync failure produced the
explicit atomic recovery error.

---

## P1 Remediation: Preserve the Exact Index Snapshot Used for Planning

### Root Cause

The transaction retained the bytes passed to `patcher.plan`, but the index step
later applied those mutations to a newly read snapshot. This allowed an
unrelated external modification after planning to reach the replacement path.

### TDD Evidence

`testIndexChangedBetweenPlanningAndReplacementIsPreservedBeforeExchange` first
failed: the fixture changed only its temporary `Index.plist` after the prepared
index sibling was written, and the transaction performed `exchange:index`.

### Implementation

After staging the prepared index sibling and immediately before the guarded
exchange, the transaction re-reads `Index.plist` and byte-compares it with the
exact `originalIndex` data passed to `patcher.plan`. A mismatch throws
`targetChanged`, leaves the writing journal intact, and performs no index,
poster, refresh, or commit action. The existing guarded exchange still protects
the final kernel-level window.

### Verification

- `swift test --filter LockScreenTransactionTests/testIndexChangedBetweenPlanningAndReplacementIsPreservedBeforeExchange`: 1 test, 0 failures.
- `swift test --filter LockScreenTransactionTests`: 19 tests, 0 failures.
- `swift test`: 107 tests, 0 failures.
- `git diff --check`: exited successfully.
