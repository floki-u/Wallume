# Desktop surfaces

## Scope

The AppKit desktop-surface layer converts macOS screen events into static, per-display desktop windows. It does not assign media, create players, expose application UI, or write lock-screen state.

## Window behavior

Each surface uses a borderless nonactivating panel at the desktop window level. It is transparent, has no shadow, ignores pointer events, stays visible when the application deactivates, and joins all Spaces.

## Lifecycle

DesktopWindowController creates one surface for every stable display ID. It updates a surface only when its frame changes, and closes the surface when the display disappears. Repeating an identical snapshot has no effect.

## Notification source

AppKitScreenProvider observes screen-parameter changes and application activation through NotificationCenter. It does not poll. Calling stop removes every observer.

## Failure isolation

A failed window creation produces a DesktopSurfaceFailure for that display. Other displays continue reconciling, and a later snapshot may retry the failed display.

## Manual checks

On a disposable build, connect and disconnect an external display. Confirm one surface follows each display frame, does not focus the app, does not intercept clicks, remains across Space changes, and closes after disconnection.

## Next adapter

The next runtime batch replaces the empty content view with an AVFoundation-backed presentation layer. PlayerPool remains responsible for sharing playback resources across displays.

