# Lock Screen Application Sync Final Review Fixes

Date: 2026-07-17

## Result

All six merge-blocking review findings are resolved without broadening the system-file mutation boundary.

1. Configuration load failure is terminal for the lifetime of a `LockScreenConfigurationStore`. Replacing malformed bytes and invoking retry cannot reload the store or regain mutation authority; the service regression verifies no probe, recovery, install, or configuration overwrite occurs.
2. Unknown macOS generations still inspect and safely recover existing configured `prepared`, `writing`, and `restoring` transactions, and permit explicit restore/disable for committed or conflicted owned transactions. They continue to block every new install. Foreign backups remain a higher-priority fail-closed gate.
3. Termination closes admission and drops commands that have not started. It waits only for the operation already in progress to reach its safe endpoint. The deterministic gate test queues replacement and restore work behind a blocked install and verifies neither queued system action begins.
4. Media switching persists a validated `restoring` marker before restore. If recovery reaches its verified endpoint and its journal is consequently omitted from inspection before configuration clearing, startup clears only this marked stale reference and resynchronizes. Unmarked missing journals still require repair; conflicts roll the marker back to the prior durable configuration.
5. The page and API expose explicit re-synchronization. Diagnostic export produces a versioned, path-free immutable JSON snapshot and uses SwiftUI's local save picker. It excludes media/slot URLs and backup names, performs no upload, and does not call the system client.
6. The documented prohibited-path gate now checks whether app-support tests construct production wallpaper file URLs. It intentionally permits inert fixture strings used to test rejection/redaction, and the documented command passes.

## Verification

- `swift test --filter LockScreenConfigurationStoreTests`: 15 passed.
- `swift test --filter LockScreenSyncServiceTests`: 50 passed.
- `swift test --filter LockScreenFeatureStoreTests`: 6 passed.
- `swift test --filter LockScreenViewTests`: 8 passed.
- `swift test`: 329 passed.
- Release builds passed for `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore`.
- `git diff --check`: passed.
- Documented production-URL construction scan: passed.

No real system wallpaper path or process is used by the new tests. Real-device/system-wallpaper acceptance remains pending manual verification, consistent with the project status documents.
