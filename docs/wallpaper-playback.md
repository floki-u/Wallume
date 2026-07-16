# Wallpaper playback

## Scope

The playback runtime connects registered media to AppKit desktop surfaces. It does not provide gallery, menu-bar, volume, or settings UI and does not write lock-screen state.

## Muted looping playback

Each active media item uses one muted `AVQueuePlayer` and one retained `AVPlayerLooper`. Playback resumes from its current position after pause.

## Shared-player presentation

Displays assigned the same media share one player and playback clock. Every display owns an independent `AVPlayerLayer` with aspect-fill gravity, so edge cropping is allowed without stretching or black bars.

## Pause signals

Session lock, system sleep, and low-power state are independent pause causes. Any active cause pauses playback; playback resumes only when all causes clear. The runtime observes system notifications and does not poll.

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

Measure resident memory and average CPU for 1080p, 4K, two displays sharing one media, and paused playback. Check GPU activity with Instruments or Metal HUD. Results from hardware other than a base M1 running macOS 14 are development data only.

## Remaining phase-three gates

Foreground-application full-obscuration pause and formal base-M1/macOS-14 performance approval remain before phase three can be pushed as complete.
