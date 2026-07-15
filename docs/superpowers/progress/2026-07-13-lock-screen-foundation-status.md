# Wallume Lock-Screen Foundation Status

Updated: 2026-07-14

## Current state

- Repository: `floki-u/Wallume`
- Local branch: `agent/lock-screen-safety`
- Remote policy: local commits only; nothing from this implementation branch has been pushed
- Plan: `docs/superpowers/plans/2026-07-10-wallume-lock-screen-safety-foundation.md`
- Design: `docs/superpowers/specs/2026-07-10-wallume-design.md`

## Completed tasks

1. Swift package and stable product identity — complete.
2. macOS 14/15/26 routing and derived paths — complete.
3. Durable atomic file IO and SHA-256 verification — complete.
4. Explicit manifest-backed Aerial slot discovery — complete.
5. Narrow reversible `Index.plist` mutations — complete.
6. Durable lock-screen installation transaction — complete.
7. Compare-and-restore recovery and orphan handling — complete.
8. Standalone read-only/status and explicit restore CLI — complete.
9. Read-only live probe, CI, and phase-1 safety documentation — complete.
10. Whole-branch review and local branch handoff — complete.

Task 7 was accepted by an independent task review with no Critical, Important, or Minor findings. Its local head is `5009015`. The implementation includes schema-v2 recovery journals, atomic guarded replacement, crash-resumable artifacts, complete backup ownership checks, no-follow path validation, cross-process advisory locking, conservative conflict retention, and a documented local threat boundary.

Task 8 adds dependency-injected `wallume-restore` command parsing, `status`, `restore <transaction-uuid>`, and `restore-all`; wires the executable to live filesystem dependencies; honors `HOME` from the process environment; keeps empty `status` read-only even under an isolated home directory; and refreshes only `WallpaperAgent` and `WallpaperAerialsExtension` after explicit restores.

Task 9 adds `wallume-restore probe`, a report-only `LockScreenProbe`, native arm64 GitHub Actions CI, and `docs/lock-screen-safety.md`. The live probe was verified on this machine as read-only by before/after SHA-256 and mtime/size comparisons for the live manifest, `Index.plist`, lock-screen poster, and discovered `.mov` slots.

Task 10 reviewed the whole branch against `main`. The review found one blocking spec issue: incomplete `.prepared`/`.writing` recovery could preserve external target changes but still mark the transaction `restored` and delete backups. This was fixed by requiring final original-state verification to be strict; such external changes now become conflicts and retain backups.

## Verification record

- Implementer full suite at task head: 106 tests passed, 0 failures.
- Implementer focused safety suites: 99 tests passed, 0 failures.
- Primary-agent final verification: `swift test` passed 106 tests with 0 failures; `git diff --check` passed.
- Task 8 verification: `swift test --filter RestoreCommandTests` passed 5 tests with 0 failures; `swift build -c release --product wallume-restore` passed; isolated `HOME="$(mktemp -d)" .build/release/wallume-restore status` exited 0 with no output and no created files; `swift test` passed 115 tests with 0 failures; `git diff --check` passed.
- Task 9 verification: `swift test` passed 118 tests with 0 failures; `swift build -c release --product wallume-restore` passed; `.build/release/wallume-restore probe` exited 0 and reported `generation: tahoe`; live before/after SHA-256 and mtime/size snapshots were identical; `git diff --check` passed. Spec review found no actionable issues; maintainability review findings were addressed before final verification.
- Task 10 verification: whole-branch standards review found no P0/P1 issues and noted future refactors for `RecoveryCoordinator`, guarded exchange duplication, and artifact role naming; whole-branch spec review's P1 recovery-conflict issue was fixed. `swift test --filter RecoveryCoordinatorTests/testIncompleteJournalPreservesUnownedCurrentTargetsAsConflicts`, `swift test`, `swift build -c release`, and `git diff --check` passed after the fix.
- Independent task review: approved.
- No automated test accesses the live macOS wallpaper directories.

## Remaining phase-1 tasks

None.

Local handoff: branch `agent/lock-screen-safety` in worktree `.worktrees/lock-screen-safety` contains the complete phase-1 foundation. The recovery-metadata design is finalized: the Wallume transaction journal is authoritative, while the same-directory `primaryBackup` is a discovery anchor and verified backup, not a second manifest.

## Safety boundary

Wallume protects against crashes, concurrent Wallume processes, stale system state, ordinary external rewrites, malformed journals, path traversal, and static symlink redirection. macOS does not provide an atomic compare-inode-and-unlink primitive; the project therefore does not claim protection from an active same-UID attacker precisely replacing a private cleanup entry during the final syscall window.
