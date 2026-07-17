# Lock Screen Application Sync Final Review Fixes

Date: 2026-07-17

## Result

All six merge-blocking review findings are resolved without broadening the system-file mutation boundary.

1. Configuration load failure is terminal for the lifetime of a `LockScreenConfigurationStore`. Replacing malformed bytes and invoking retry cannot reload the store or regain mutation authority; the service regression verifies no probe, recovery, install, or configuration overwrite occurs.
2. Unknown macOS generations still inspect and safely recover existing configured `prepared`, `writing`, and `restoring` transactions, and permit explicit restore/disable for committed or conflicted owned transactions. They continue to block every new install. Foreign backups remain a higher-priority fail-closed gate.
3. Termination closes admission and drops commands that have not started. It waits only for the operation already in progress to reach its safe endpoint. The deterministic gate test queues replacement and restore work behind a blocked install and verifies neither queued system action begins.
4. Media switching persists a validated `restoring` marker before restore, but that marker is not evidence of completion. Startup resumes only a referenced journal that remains inspectable (including `.restored` journals with pending terminal cleanup) through idempotent recovery. Missing or unrelated journal evidence remains in repair with no reference clearing or install.
5. The page and API expose explicit re-synchronization. Diagnostic export produces a versioned, path-free immutable JSON snapshot and uses SwiftUI's local save picker. It excludes media/slot URLs and backup names, performs no upload, and does not call the system client.
6. The documented prohibited-path gate now checks whether app-support tests construct production wallpaper file URLs. It intentionally permits inert fixture strings used to test rejection/redaction, and the documented command passes.

## Verification

- `swift test --filter LockScreenConfigurationStoreTests`: 16 passed.
- `swift test --filter LockScreenSyncServiceTests`: 56 passed.
- `swift test --filter LockScreenFeatureStoreTests`: 6 passed.
- `swift test --filter LockScreenViewTests`: 8 passed.
- `swift test`: 336 passed.
- Release builds passed for `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore`.
- `git diff --check`: passed.
- Documented production-URL construction scan: passed.

No real system wallpaper path or process is used by the new tests. Real-device/system-wallpaper acceptance remains pending manual verification, consistent with the project status documents.

## Second Final Review Fixes

1. A loaded configuration store returns its trusted in-memory snapshot on retry/re-sync; only a fresh store/process reads disk again.
2. Restore markers no longer authorize clearing an absent referenced transaction. Missing or unrelated candidates fail closed, while a matching `.restored` candidate resumes idempotent terminal cleanup before reevaluation.
3. Termination is checked after probe/inspection and around every new install/restore boundary. A gated probe cannot advance to recovery after termination, and a restore already in progress can finish without beginning a replacement install.

## Third Final Review Fixes

1. Once a media-switch restore reaches a verified endpoint, the service durably clears the restoring reference before it observes termination. Shutdown therefore prevents the replacement install without leaving a stale restore marker for the next process.
2. Every new install now verifies the previously trusted configuration source immediately beforehand. This non-adopting check rejects both malformed and valid external replacements, transitions to repair, and issues no system install.
