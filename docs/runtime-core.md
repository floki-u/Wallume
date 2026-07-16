# Runtime core

## Scope

Runtime core manages display sessions, shared playback resources, and pause state. It does not create windows, enumerate displays, or play real media.

## Inputs and outputs

`RuntimeCoordinator` reconciles stable display IDs, media assignments, and an environment snapshot into an immutable runtime snapshot.

## Resource sharing

Sessions assigned the same `MediaItem.id` share one playback resource. The resource is released after its final session ends.

## Pause policy

User pause, app obscuring, screen lock, low-power mode, and system sleep pause all active resources. Playback resumes only after every reason clears.

## Failure behavior

Unavailable media and duplicate display assignments report a failure while preserving the existing session. Failures never write lock-screen state.

## Platform adapter boundary

Future AppKit display observation and AVFoundation players implement the injected catalog and player contracts without leaking platform objects into the core.

## Performance measurement handoff

The snapshot exposes session count, resource reference counts, creation count, pause causes, and failures. Real RSS, CPU, and GPU measurement begins with the future AppKit and AVFoundation runtime adapter.
