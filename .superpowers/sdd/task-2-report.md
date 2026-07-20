# Task 2 report — Redacted local diagnostic export

## Scope delivered

- Added `DiagnosticsExportService`, a versioned `Codable` document, and injected settings, lock-screen, transaction, and performance snapshot seams.
- The document includes only setting booleans, count/status-only lock-screen and transaction summaries, the existing aggregate-only performance report, and tightly validated build/system metadata.
- Added `LockScreenDiagnosticsSummary`, which derives phase/count/boolean values from `LockScreenSyncState` while deliberately excluding media IDs and names, URLs, backup names, paths, transaction IDs, and raw errors.
- Writes use `AtomicJSONStore` over the injected `FileStore`. The only public failures are `DiagnosticsExportUserError.writeFailed` and `.cancelled`; provider failures are represented by safe unavailable summaries.
- Kept UI, controller composition, routing, lifecycle, and network behavior out of this task.

## TDD evidence

1. RED: `swift test --filter DiagnosticsExportServiceTests` failed before implementation because the export service, document, safe lock-screen adapter, and summary types did not exist.
2. GREEN: the first export slice passed after adding the minimal versioned document and `AtomicJSONStore` writer.
3. RED: the unavailable-performance assertion failed because a missing latest report was encoded with `available` status. The service now emits `unavailable` with no report for a missing or failed provider.
4. RED: unsafe build/system fixture values were encoded verbatim. The metadata initializer now accepts only semantic-version/build/macOS/architecture shapes and replaces anything else with `unavailable`.
5. GREEN: `swift test --filter DiagnosticsExportServiceTests` passed 4 tests: redacted decoded export, unavailable-provider redaction, unsafe build metadata redaction, and write-failure preservation followed by retry.

## Verification

- `swift test --filter DiagnosticsExportServiceTests`: 4 tests, 0 failures.
- `swift test`: 390 tests, 0 failures.
- `git diff --check`: passed.

## Concerns

- None within Task 2. Task 3 must provide the local user-selected destination and wire `PerformanceReportStore.latest()` into the injected performance reader; Task 4 owns in-flight export cancellation during application termination.

## Review follow-up

- Replaced the arbitrary performance closure with the narrow `PerformanceReportReading` protocol; `PerformanceReportStore` conforms and `DiagnosticsExportService` now calls `latest()` internally. Reader errors and missing reports continue to encode only `unavailable` and no raw error text.
- Reworked `LocalFileStore.replace` for an existing target to use atomic exchange. If the directory sync after swapping fails, `exchange` swaps the original bytes back and synchronizes the rollback before returning the failure. Old prepared bytes are cleaned up best-effort only after a durable successful replacement, so cleanup trouble cannot turn a completed commit into a reported failure.
- Added a post-replacement directory-sync failure regression proving the old destination bytes survive and a subsequent retry writes the new bytes.

### Review verification

- `swift test --filter DiagnosticsExportServiceTests`: 4 tests, 0 failures.
- `swift test --filter AtomicIOTests`: 16 tests, 0 failures.
