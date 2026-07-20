# Performance Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a page-scoped real-time performance view and a user-triggered 30-second local diagnostic that safely records and exports an anonymized JSON report.

**Architecture:** Reuse `RuntimeMetricSample` and `WallpaperRuntimeSnapshot`, but place performance orchestration in `WallumeAppSupport`. An actor owns timer/diagnostic lifecycle and report persistence; an observable feature store supplies SwiftUI only. ApplicationController feeds runtime snapshots and cancels the diagnostic during application termination.

**Tech Stack:** Swift 6, macOS 14+, SwiftUI/Observation, XCTest, existing `RuntimeMetricSampling`, `AtomicJSONStore`, `LocalFileStore`.

## Global Constraints

- Real-time sampling is in memory only, once per second, capped at 60 samples, and stops when the page disappears.
- A diagnostic is user-triggered, serial, exactly 30 seconds at one sample per second; cancel/termination produces no completed report.
- No sampler, page, or diagnostic may control wallpaper assignments, players, or the desktop runtime.
- Reports contain no media content/name, thumbnail, video URL, source URL, absolute user home path, or backup data; no upload occurs.
- A report write failure preserves the in-memory completed report and permits local export retry.
- Tests use controllable clocks/samplers and temporary directories; never rely on wall-clock sleeps or real user paths.
- Keep work local; do not push and do not touch `.vscode/`.

---

## File Map

| Area | Files |
| --- | --- |
| Models/sampling | `Sources/WallumeAppSupport/Performance/PerformanceModels.swift`, `PerformanceMetricSampler.swift` |
| Lifecycle/report service | `Sources/WallumeAppSupport/Performance/PerformanceDiagnosticsService.swift`, `PerformanceReportStore.swift` |
| UI state/page | `Sources/WallumeAppSupport/Performance/PerformanceFeatureStore.swift`, `Sources/WallumeAppSupport/UI/PerformanceView.swift` |
| App wiring | `Sources/WallumeApp/ApplicationController.swift`, `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`, `Sources/WallumeAppSupport/UI/FeatureRegistry.swift` |
| Tests | `Tests/WallumeAppSupportTests/PerformanceDiagnosticsServiceTests.swift`, `PerformanceFeatureStoreTests.swift`, `PerformanceViewTests.swift`, shell/composition tests |

## Task 1: Performance data model, aggregation, and redacted report persistence

**Files:**
- Create: `Sources/WallumeAppSupport/Performance/PerformanceModels.swift`
- Create: `Sources/WallumeAppSupport/Performance/PerformanceReportStore.swift`
- Create: `Tests/WallumeAppSupportTests/PerformanceDiagnosticsServiceTests.swift`

- [x] **Step 1: Write failing tests** for a 60-item ring window, current/average/peak CPU and RSS aggregation, deterministic runtime counters, and versioned JSON report encoding that rejects fields containing media names or absolute paths.
- [x] **Step 2: Run RED:** `swift test --filter PerformanceDiagnosticsServiceTests` — expected missing-model compilation failure.
- [x] **Step 3: Implement** `PerformanceSample`, `PerformanceRuntimeContext`, `PerformanceSummary`, `PerformanceDiagnosticReport`, and `PerformanceReportStore`. The report must include only start time, duration, sample count, scenario, aggregate metrics, display/session/resource counts, pause reasons, chip, physical memory, and macOS version. `PerformanceReportStore.save(_:)` atomically writes one JSON document beneath `~/Library/Application Support/Wallume/Diagnostics` and `latest()` reads it.
- [x] **Step 4: Run GREEN:** `swift test --filter PerformanceDiagnosticsServiceTests` — aggregation and redaction tests pass.
- [x] **Step 5: Commit:** `git commit -m "feat: add performance diagnostic report models"`.

## Task 2: Actor-owned realtime sampling and 30-second diagnostic service

**Files:**
- Create: `Sources/WallumeAppSupport/Performance/PerformanceMetricSampler.swift`
- Create: `Sources/WallumeAppSupport/Performance/PerformanceDiagnosticsService.swift`
- Modify: `Tests/WallumeAppSupportTests/PerformanceDiagnosticsServiceTests.swift`

- [x] **Step 1: Write failing tests** with a manual clock/sleeper and sampler fake for page appearance/disappearance, duplicate appearance, 60-sample trimming, one active diagnostic, 30 exactly scheduled samples, cancel, termination cancel, report-save failure retention, and runtime snapshot updates.
- [x] **Step 2: Run RED:** `swift test --filter PerformanceDiagnosticsServiceTests` — expected missing-service failures.
- [x] **Step 3: Implement** `PerformanceMetricSampling` production adapter over `ProcessRuntimeMetricSampler`, an actor `PerformanceDiagnosticsService`, immutable `PerformanceDiagnosticsSnapshot`, `beginRealtime()`, `endRealtime()`, `update(runtime:)`, `startDiagnostic(scenario:)`, `cancelDiagnostic()`, `retrySaveCompletedReport()`, `stop()`, and `events()`. Use injected `PerformanceClock` with a one-second tick. Realtime has no disk writes; diagnostics own their task across page disappearance; `stop()` cancels incomplete diagnostics without persisting.
- [x] **Step 4: Run GREEN:** `swift test --filter PerformanceDiagnosticsServiceTests` — all lifecycle, exact-count, cancellation, and failure tests pass.
- [x] **Step 5: Commit:** `git commit -m "feat: add performance diagnostics service"`.

## Task 3: Observable store and Performance SwiftUI page

**Files:**
- Create: `Sources/WallumeAppSupport/Performance/PerformanceFeatureStore.swift`
- Create: `Sources/WallumeAppSupport/UI/PerformanceView.swift`
- Create: `Tests/WallumeAppSupportTests/PerformanceFeatureStoreTests.swift`
- Create: `Tests/WallumeAppSupportTests/PerformanceViewTests.swift`

- [x] **Step 1: Write failing tests** for store event observation, page appear/disappear commands, start/cancel/export/retry actions, in-memory error retention, and pure page states for idle/realtime/running/completed/failed reports.
- [x] **Step 2: Run RED:** `swift test --filter PerformanceFeatureStoreTests && swift test --filter PerformanceViewTests` — expected missing symbols.
- [x] **Step 3: Implement** `@MainActor @Observable PerformanceFeatureStore` and `PerformanceView`. The view shows current/average/peak CPU/RSS, active displays/sessions/shared resources/pause reasons, live 30-second progress, cancel, retry-save, and a `FileDocument` export created only from report JSON. `onAppear` starts realtime and `onDisappear` stops only realtime.
- [x] **Step 4: Run GREEN:** `swift test --filter PerformanceFeatureStoreTests && swift test --filter PerformanceViewTests` — page/store tests pass without filesystem/process access in the view.
- [x] **Step 5: Commit:** `git commit -m "feat: add performance diagnostics page"`.

## Task 4: Application composition, reference run, and verification

**Files:**
- Modify: `Sources/WallumeApp/ApplicationController.swift`
- Modify: `Sources/WallumeAppSupport/UI/ApplicationShellView.swift`
- Modify: `Sources/WallumeAppSupport/UI/FeatureRegistry.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationShellViewTests.swift`
- Modify: `Tests/WallumeAppSupportTests/ApplicationCompositionTests.swift`
- Modify: `docs/phase-four-status.md`, `docs/progress-status.md`, this plan

- [x] **Step 1: Write failing composition tests** proving Performance is enabled while Settings remains disabled, page route requires a supplied store, runtime events update diagnostics, and termination calls diagnostics `stop()` without altering desktop-runtime shutdown ordering.
- [x] **Step 2: Run RED:** `swift test --filter ApplicationShellViewTests && swift test --filter ApplicationCompositionTests` — expected routing/composition assertion failure.
- [x] **Step 3: Implement** one service/store in `ApplicationController`; forward every `WallpaperRuntimeSnapshot` to it; expose `PerformanceView`; begin no realtime work until page appearance; cancel incomplete diagnostics before runtime stop during termination.
- [x] **Step 4: Run GREEN and gates:** `swift test`; `swift build -c release --product WallumeApp`; `swift build -c release --product wallume-runtime`; `swift build -c release --product wallume-media`; `swift build -c release --product wallume-restore`; `git diff --check`.
- [x] **Step 5: Run one current-machine diagnostic** through the production service for 30 seconds, retain the generated local report, and record actual chip, physical memory, macOS version, and scenario as a reference only—never label it M1 data.
- [x] **Step 6: Update status docs/checkboxes** with automated evidence and the current-device reference; commit `git commit -m "docs: record performance diagnostics verification"`.

## Acceptance Checklist

- [x] Realtime sampling is one-per-second, memory-only, capped at 60, and ends on page disappearance.
- [x] Diagnostic uses exactly 30 samples/seconds, survives page navigation, and cancels without a report on cancel/termination.
- [x] Reports are atomic, local, exportable, and redacted.
- [x] Performance has no runtime-control or wallpaper side effects.
- [x] Full tests, all release products, diff check, and a current-device 30-second reference run pass.

Verification recorded 2026-07-20: `swift test` passed 378 tests; all four release products and `git diff --check` passed. A production-service 30-second `single-display` reference diagnostic was retained locally at `~/Library/Application Support/Wallume/Diagnostics/report.json`: Apple M4, 51,539,607,552 bytes physical memory, macOS 26, exactly 30 samples and 30-second duration. This is a current-machine reference only, not M1 data.
