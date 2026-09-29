# Changelog

## Unreleased

### Features

- Add native PNG, JPG, JPEG, and HEIC wallpaper import with direct, zero-player desktop rendering and static lock-screen handoff through System Settings.

### Fixes

- Keep uninstall working after Wallume.app is moved into Applications by shipping a standalone cleanup helper and falling back to the installed app for older packages.
- Remove the native wallpaper extension's persisted preferences together with its provider documents during cleanup.

## 1.2.9 - 2026-09-28

### Features

- Redesign the native macOS interface around the approved Cinema Workspace direction, with a compact projection sidebar, immersive media library, display workspace, lock-screen handoff, runtime health view, and grouped settings.
- Add adaptive light and dark design tokens while keeping the coral projection accent and semantic playback states consistent.
- Complete English localization for the redesigned interface and improve native renderer telemetry visibility.

### Fixes

- Throttle native renderer metric writes to reduce unnecessary local updates.
- Preserve uninstall and cleanup behavior when application paths contain spaces.
