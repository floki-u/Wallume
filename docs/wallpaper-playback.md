# Wallpaper playback

## Scope

The playback runtime connects registered media to AppKit desktop surfaces. It does not provide gallery, menu-bar, volume, or settings UI and does not write lock-screen state.

## Muted looping playback

Each active media item uses one muted `AVQueuePlayer` and one retained `AVPlayerLooper`. Playback resumes from its current position after pause.

## Shared-player presentation

Displays assigned the same media share one player and playback clock. Every display owns an independent `AVPlayerLayer` with aspect-fill gravity, so edge cropping is allowed without stretching or black bars.

## Pause signals

Session lock, system sleep, low-power state, and full desktop-window obscuration are independent pause causes. Any active cause pauses playback; playback resumes only when all causes clear. The runtime observes system and workspace notifications and does not poll during normal playback.

Window obscuration is deliberately conservative. The runtime uses the public Core Graphics on-screen window list without Accessibility permission, ignores transparent, off-screen, desktop-level, and Wallume-owned windows, and pauses only when the union of eligible windows covers every active wallpaper display. If the window list cannot be read, playback remains active. A future opt-in Accessibility mode may provide finer-grained visibility information, but is not part of phase three.

## Verification command

Build the isolated runtime and launch one registered media UUID:

```bash
swift build -c release --product wallume-runtime
.build/release/wallume-runtime <media-uuid>
```

Press Control-C to stop. Playback remains muted.

## Manual matrix

Verify one display, two displays using the same media, display hot-plug, session lock/unlock, sleep/wake, and low-power transitions. Confirm windows do not activate the app or intercept pointer events.

## Development-machine metrics

Run an explicit five-minute benchmark for each scenario:

```bash
.build/release/wallume-runtime benchmark <media-uuid> --duration 300 --scenario single-1080p
.build/release/wallume-runtime benchmark <media-uuid> --duration 300 --scenario single-4k
.build/release/wallume-runtime benchmark <media-uuid> --duration 300 --scenario dual-shared
.build/release/wallume-runtime benchmark <media-uuid> --duration 300 --scenario paused
```

Duration must be from 5 through 3600 seconds. Scenario names label the intended manual setup; they do not alter the detected displays or media. Arrange the requested display/media configuration before launching the command. Sampling occurs once per second only in benchmark mode. Normal playback does not create a performance sampler or sampling timer.

The command writes one sorted-key JSON object to standard output. Schema version 1 includes the timestamp, scenario, hardware model, OS description, active display count, media dimensions and frame rate, raw RSS/CPU samples, sample count, average and peak RSS, average and peak CPU, pause reasons, shared resource count, and manual GPU status. It also always records `developmentOnly: true` and `certification: "blockedByHardware"`.

GPU status remains `notMeasured` because GPU activity must be checked manually with Instruments or Metal HUD. Results from hardware other than a base M1 running macOS 14 are development data only.

## Phase-three status

Engineering implementation is complete. Formal performance certification remains blocked until a base M1 running macOS 14 is available for CPU, RSS, and GPU acceptance. The project does not claim phase-three performance certification yet.
