# Phase three status

Updated: 2026-07-16

## Outcome

- Engineering status: `engineeringComplete`
- Performance certification: `blockedByHardware`
- UI status: deferred to the later product-UI phase; phase three provides runtime behavior and AppKit desktop surfaces only

Phase three now contains the testable multi-display runtime core, shared muted AVFoundation playback, AppKit desktop surfaces, display hot-plug handling, lock/sleep/low-power pause composition, conservative full-window-obscuration pause, and an explicit performance benchmark command.

## Automated acceptance

The automated gate is:

```bash
swift test
swift build -c release --product wallume-runtime
swift build -c release --product wallume-media
swift build -c release --product wallume-restore
git diff --check
```

Malformed benchmark input must exit 64 before media lookup or window creation. Normal runtime startup contains no benchmark sampler or sampling timer; those are created only after parsing the explicit `benchmark` command.

The 2026-07-16 engineering gate passed 175 tests with zero failures, all three release-product builds, the malformed-input exit check, and `git diff --check`. Completion review found no remaining Critical or Important issues.

## Hardware-blocked acceptance

Formal certification requires a base M1 Mac running macOS 14. On that machine, run the 1080p, 4K, dual-shared, and paused scenarios, retain their JSON reports, and inspect GPU activity manually with Instruments or Metal HUD. Only after CPU, RSS, and GPU thresholds are accepted may the certification state change from `blockedByHardware` to `certified`.

Current-machine reports remain development evidence and must not be represented as formal certification.
