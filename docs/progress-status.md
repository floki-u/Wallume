# Wallume progress status

Updated: 2026-07-20

## Completed engineering milestones

1. Phase 1: lock-screen safety foundation.
2. Phase 2: media library and importer.
3. Phase 3: testable runtime core, AppKit desktop surfaces, muted shared playback, system pause signals, obscuration handling, and benchmark tooling. Target-hardware performance certification remains deferred.
4. Phase 4 batch 1: application shell, gallery, and complete serial background import experience.
5. Phase 4 batch 2: display assignment, per-display presentation, reconnect restoration, global playback controls, and in-process runtime ownership.
6. Phase 4 batch 3: Lock Screen setup page, serialized main-display synchronization, recovery-safe restoration, and automated regression verification.
7. Phase 4 batch 4: Performance diagnostics page, application composition, local report persistence/export, and current-machine reference verification (locally merged).
8. Phase 4 batch 5: enabled Settings page with launch/login/low-power preferences, directory and build information, redacted retryable local diagnostics export, termination-safe commit admission, and automated verification.

## Current position

Performance diagnostics is locally merged. Settings is enabled and its engineering work is complete: all three preferences, directory/build information, redacted retryable local export, and application-owned export termination are delivered. Final review-remediation verification passed 38 focused tests and 404 full-suite tests with zero failures; local Release-configuration builds completed for `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore`; and `git diff --check` passed. Termination closes commit admission, rejects not-yet-admitted export writes, drains an already-admitted synchronous atomic commit, and preserves preferences plus the lock-screen → diagnostics → runtime shutdown order. The current diagnostics reference machine is Apple M4 with 51,539,607,552 bytes physical memory on macOS 26; this is not M1 data or target-hardware certification. No packaged release or remote integration is claimed. Phase 4 itself remains in progress pending localization, application state restoration, manual Settings/whole-app UI acceptance, and real-system Lock Screen installation/lock/unlock/restoration acceptance.

## Next work

1. Complete localization and application state restoration.
2. Perform manual Settings and whole-application UI acceptance.
3. Perform real-device/system-wallpaper installation, lock/unlock, and restoration acceptance for Lock Screen, then run the final phase-four completion review.

Remote policy: keep the phase-four commits local until the complete phase is finished and approved for push.
