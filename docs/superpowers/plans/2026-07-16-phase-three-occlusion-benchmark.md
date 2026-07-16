# Phase-three occlusion and benchmark implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish phase-three engineering with conservative event-driven window occlusion pause and explicit JSON performance benchmarking.

**Architecture:** A pure occlusion evaluator consumes normalized display and window snapshots; an AppKit monitor supplies event-triggered snapshots through injected providers. A benchmark sampler runs only in benchmark mode and aggregates process metrics into a Codable report.

**Tech Stack:** Swift 6, CoreGraphics, AppKit, Darwin, Foundation, XCTest, macOS 14.

## Global constraints

- Do not request Accessibility permission or poll during normal playback
- Fail open when window information is missing or unreadable
- Pause for occlusion only when every active wallpaper display is fully covered
- Benchmark sampling runs only after the explicit benchmark command
- Mark certification blocked until base M1/macOS 14 hardware is available
- Preserve the untracked `.vscode/` directory and exclude it from commits

---

### Task 1: Normalize window snapshots and evaluate occlusion

**Files:**

- Create: `Sources/WallumeCore/AppKitRuntime/WindowOcclusion.swift`
- Create: `Tests/WallumeCoreTests/WindowOcclusionTests.swift`

**Interfaces:**

- Produces `WindowSnapshot`, `WindowSnapshotProviding`, `WindowOcclusionEvaluator`, and `CGWindowSnapshotProvider`
- `WindowOcclusionEvaluator.allDisplaysObscured(displays:windows:ownPID:) -> Bool`

- [ ] **Step 1: Write failing union and multi-display tests**

Test adjacent windows whose union covers one display, and two displays where only one is covered. The first must return true; the second false.

- [ ] **Step 2: Verify red**

Run: `swift test --filter WindowOcclusionTests`

Expected: compilation fails because snapshot and evaluator types do not exist.

- [ ] **Step 3: Implement normalized snapshots and exact union coverage**

Filter own PID, nonzero layers, zero-alpha or offscreen windows, empty bounds, and missing required fields. Split each display at all rectangle x edges; for every x slab, merge y intervals and require complete display-height coverage.

`CGWindowSnapshotProvider` calls `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` and returns nil on read or conversion failure. Nil is distinct from an empty successful snapshot.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter WindowOcclusionTests`

```bash
git add Sources/WallumeCore/AppKitRuntime/WindowOcclusion.swift Tests/WallumeCoreTests/WindowOcclusionTests.swift
git commit -m "feat: evaluate desktop window occlusion"
```

### Task 2: Add event-driven occlusion monitoring

**Files:**

- Create: `Sources/WallumeCore/AppKitRuntime/WindowOcclusionMonitor.swift`
- Create: `Tests/WallumeCoreTests/WindowOcclusionMonitorTests.swift`
- Modify: `Sources/WallumeCore/AppKitRuntime/RuntimeEnvironmentMonitor.swift`
- Modify: `Sources/WallumeRuntime/main.swift`

**Interfaces:**

- Produces `WindowOcclusionMonitor.start(displays:onChange:)`, `updateDisplays(_:)`, and `stop()`
- Extends `RuntimeEnvironmentMonitor` with an independent obscuration source

- [ ] **Step 1: Write the failing event test**

Post an injected workspace activation notification after replacing the fake window snapshot with full coverage. Assert the monitor emits true and creates no timer.

- [ ] **Step 2: Verify red**

Run: `swift test --filter WindowOcclusionMonitorTests`

Expected: compilation fails because the monitor does not exist.

- [ ] **Step 3: Implement AppKit event observation**

Observe workspace application activation, active-Space changes, screen-parameter changes, and application activation. Read one injected snapshot per event. Emit false on nil and only emit transitions. `updateDisplays` reevaluates immediately; `stop` removes observers.

Feed this value into `RuntimeEnvironmentMonitor` as its independent `appObscured` signal. Wire `wallume-runtime` to update the monitor from current screens.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter 'WindowOcclusionMonitorTests|RuntimeEnvironmentMonitorTests'`

```bash
git add Sources/WallumeCore/AppKitRuntime Tests/WallumeCoreTests/WindowOcclusionMonitorTests.swift Tests/WallumeCoreTests/RuntimeEnvironmentMonitorTests.swift Sources/WallumeRuntime/main.swift
git commit -m "feat: pause fully obscured wallpaper playback"
```

### Task 3: Aggregate and encode performance samples

**Files:**

- Create: `Sources/WallumeCore/Runtime/RuntimeBenchmark.swift`
- Create: `Tests/WallumeCoreTests/RuntimeBenchmarkTests.swift`

**Interfaces:**

- Produces `RuntimeMetricSample`, `RuntimeBenchmarkScenario`, `GPUVerificationStatus`, `RuntimeBenchmarkReport`, `RuntimeMetricSampling`, and `ProcessRuntimeMetricSampler`

- [ ] **Step 1: Write failing aggregation test**

Aggregate samples `(80 bytes, 2%)` and `(120 bytes, 6%)`. Assert average RSS 100, peak 120, average CPU 4, certification `blockedByHardware`, and successful JSON encoding.

- [ ] **Step 2: Verify red**

Run: `swift test --filter RuntimeBenchmarkTests`

Expected: compilation fails because benchmark types do not exist.

- [ ] **Step 3: Implement report and process sampler**

Use Mach task information for resident bytes and process CPU-time deltas against monotonic elapsed time for CPU percentage. Encode schema version, timestamp, scenario, hardware model, OS, displays, media metadata, samples, pause reasons, shared resource count, GPU status, `developmentOnly = true`, and `blockedByHardware` certification.

- [ ] **Step 4: Verify and commit**

Run: `swift test --filter RuntimeBenchmarkTests`

```bash
git add Sources/WallumeCore/Runtime/RuntimeBenchmark.swift Tests/WallumeCoreTests/RuntimeBenchmarkTests.swift
git commit -m "feat: add wallpaper runtime benchmark reports"
```

### Task 4: Add benchmark command and phase completion documentation

**Files:**

- Modify: `Sources/WallumeRuntime/main.swift`
- Modify: `docs/wallpaper-playback.md`
- Modify: `docs/superpowers/progress/2026-07-13-lock-screen-foundation-status.md`
- Create: `docs/phase-three-status.md`

**Interfaces:**

- Supports `wallume-runtime benchmark <media-uuid> --duration <seconds> --scenario <label>`
- Writes one JSON report to stdout after the duration
- Normal runtime remains timer-free

- [ ] **Step 1: Add strict benchmark parsing and execution**

Accept scenarios `single-1080p`, `single-4k`, `dual-shared`, and `paused`; require duration 5–3600 seconds. Reject invalid input with exit 64 before opening windows. Start a one-second sampler only in benchmark mode. For `paused`, retain user pause throughout. At completion stop monitors, emit sorted-key JSON, and terminate.

- [ ] **Step 2: Document engineering completion**

Document JSON fields, manual GPU status, conservative occlusion limits, future Accessibility option, `engineeringComplete`, and `blockedByHardware`. Do not mark certified.

- [ ] **Step 3: Run final verification**

Run: `swift test && swift build -c release --product wallume-runtime && swift build -c release --product wallume-media && swift build -c release --product wallume-restore && git diff --check`

Also verify malformed benchmark input exits 64 and normal usage does not instantiate the sampler.

- [ ] **Step 4: Commit**

```bash
git add Sources/WallumeRuntime docs
git commit -m "docs: complete phase three engineering"
```

## Plan self-review

- Task 1 covers filtering, exact union coverage, multi-display behavior, and fail-open snapshots.
- Task 2 covers event-driven updates, no polling, environment composition, and runtime wiring.
- Task 3 covers RSS/CPU sampling, stable JSON, development-only labeling, and hardware-blocked certification.
- Task 4 covers strict CLI behavior, benchmark-only sampling, documentation, and release gates.
- Accessibility precision mode and base-M1/macOS-14 certification remain outside implementation.
