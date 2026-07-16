# Wallume Lock-Screen Foundation Status

Updated: 2026-07-16

## Current state

- Repository: `floki-u/Wallume`
- Local branch: `codex/phase-three-completion`
- Remote policy: merge and push the complete phase-three engineering batch after verification
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
11. Phase 2 media library and `wallume-media` importer — complete.
12. Phase 3 testable runtime core — complete.
13. Phase 3 AppKit screen observation and desktop surfaces — complete.
14. Phase 3 muted shared AVFoundation playback and system pause signals — complete.
15. Phase 3 conservative full-obscuration pause — complete.
16. Phase 3 explicit JSON performance benchmark — complete.
17. Phase 3 engineering implementation — complete; base-M1/macOS-14 certification blocked by unavailable hardware.
18. Phase 4 batch 1 application shell, gallery, and complete background import experience — complete; 203 tests and four release-product builds passed, with no remaining Critical or Important review issues.

Task 7 was accepted by an independent task review with no Critical, Important, or Minor findings. Its local head is `5009015`. The implementation includes schema-v2 recovery journals, atomic guarded replacement, crash-resumable artifacts, complete backup ownership checks, no-follow path validation, cross-process advisory locking, conservative conflict retention, and a documented local threat boundary.

Task 8 adds dependency-injected `wallume-restore` command parsing, `status`, `restore <transaction-uuid>`, and `restore-all`; wires the executable to live filesystem dependencies; honors `HOME` from the process environment; keeps empty `status` read-only even under an isolated home directory; and refreshes only `WallpaperAgent` and `WallpaperAerialsExtension` after explicit restores.

Task 9 adds `wallume-restore probe`, a report-only `LockScreenProbe`, native arm64 GitHub Actions CI, and `docs/lock-screen-safety.md`. The live probe was verified on this machine as read-only by before/after SHA-256 and mtime/size comparisons for the live manifest, `Index.plist`, lock-screen poster, and discovered `.mov` slots.

Task 10 reviewed the whole branch against `main`. The review found one blocking spec issue: incomplete `.prepared`/`.writing` recovery could preserve external target changes but still mark the transaction `restored` and delete backups. This was fixed by requiring final original-state verification to be strict; such external changes now become conflicts and retain backups.

Task 11 adds the reusable media library and `wallume-media` CLI. The media library owns
schema-2 `library.json`, SHA-256 duplicate lookup, safe owned-artifact removal, and
transactional import staging. Imports accept `.mp4` and `.mov`, never modify source files,
transcode one HEVC `hvc1` `.mov` variant per source, generate JPEG artwork, and register
the media item only after owned artifacts are installed. The CLI supports `import`, `list`,
`show`, and `remove` with dependency-injected command tests and live AVFoundation adapters.

## Verification record

- Implementer full suite at task head: 106 tests passed, 0 failures.
- Implementer focused safety suites: 99 tests passed, 0 failures.
- Primary-agent final verification: `swift test` passed 106 tests with 0 failures; `git diff --check` passed.
- Task 8 verification: `swift test --filter RestoreCommandTests` passed 5 tests with 0 failures; `swift build -c release --product wallume-restore` passed; isolated `HOME="$(mktemp -d)" .build/release/wallume-restore status` exited 0 with no output and no created files; `swift test` passed 115 tests with 0 failures; `git diff --check` passed.
- Task 9 verification: `swift test` passed 118 tests with 0 failures; `swift build -c release --product wallume-restore` passed; `.build/release/wallume-restore probe` exited 0 and reported `generation: tahoe`; live before/after SHA-256 and mtime/size snapshots were identical; `git diff --check` passed. Spec review found no actionable issues; maintainability review findings were addressed before final verification.
- Task 10 verification: whole-branch standards review found no P0/P1 issues and noted future refactors for `RecoveryCoordinator`, guarded exchange duplication, and artifact role naming; whole-branch spec review's P1 recovery-conflict issue was fixed. `swift test --filter RecoveryCoordinatorTests/testIncompleteJournalPreservesUnownedCurrentTargetsAsConflicts`, `swift test`, `swift build -c release`, and `git diff --check` passed after the fix.
- Task 11 verification: `swift test --filter MediaPathsTests`, `swift test --filter MediaLibraryTests`, `swift test --filter MediaImporterTests`, `swift test --filter AVFoundationMediaTests`, and `swift test --filter MediaCommandTests` passed during implementation. Final automated acceptance passed `swift test` with 142 tests, `swift build -c release --product wallume-media`, `swift build -c release --product wallume-restore`, and `git diff --check`. Manual real-media acceptance generated disposable `.mp4` and `.mov` files under an isolated realpath `HOME`, imported both through `.build/release/wallume-media`, verified unchanged source SHA-256 values before and after import/remove, verified every variant reopened through AVFoundation as `.mov` HEVC `hvc1` with longest edge 96 and frame rate no higher than 60, and confirmed `remove` deleted only Wallume-owned artifacts.
- Independent task review: approved.
- No automated test accesses the live macOS wallpaper directories.
- Phase 3 status: `engineeringComplete`; performance certification: `blockedByHardware`.
- Phase 3 engineering verification: `swift test` passed 175 tests with 0 failures; release builds of `wallume-runtime`, `wallume-media`, and `wallume-restore` passed; malformed benchmark input exited 64 with empty standard output; `git diff --check` passed. Completion review found no remaining Critical or Important issues.

## Remaining phase-1 tasks

None.

Local handoff: branch `agent/media-library-importer` in worktree `.worktrees/media-library-importer` contains the complete phase-2 media importer work on top of the phase-1 foundation. The recovery-metadata design is finalized: the Wallume transaction journal is authoritative, while the same-directory `primaryBackup` is a discovery anchor and verified backup, not a second manifest.

## Safety boundary

Wallume protects against crashes, concurrent Wallume processes, stale system state, ordinary external rewrites, malformed journals, path traversal, and static symlink redirection. macOS does not provide an atomic compare-inode-and-unlink primitive; the project therefore does not claim protection from an active same-UID attacker precisely replacing a private cleanup entry during the final syscall window.
