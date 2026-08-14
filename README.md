# Wallume

Wallume imports local video wallpapers and, on macOS 26, stages the selected main-display video
for Wallume's native wallpaper provider. macOS then renders the chosen video for both desktop and
lock screen through System Settings.

## Build

This development build requires Xcode, an Apple Development signing identity, and a macOS 26 SDK.

```bash
./build-app.sh
open "$(swift build --show-bin-path)/Wallume.app"
```

`build-app.sh` embeds the signed `com.wallume.app.wallpaper` extension into `Wallume.app` and
removes Xcode's temporary extension registration. Override signing settings with
`WALLUME_SIGNING_IDENTITY`, `WALLUME_XCODE_SIGNING_IDENTITY`, and `WALLUME_DEVELOPMENT_TEAM` when
needed.

## Native Wallpaper Flow

1. Import a video and assign it to the main display in Wallume.
2. Open **Lock Screen Sync** and choose **Prepare Current Video**.
3. Open System Settings, choose the video under **Wallume**, and verify desktop and lock screen.

Wallume never writes Apple's wallpaper Store directly. If dynamic playback cannot be selected, the
same page exposes the generated static cover for manual selection. Before removing provider data,
choose another wallpaper in System Settings, confirm the reset in Wallume, then clean provider
resources. The main Wallume media library is retained.

The native provider currently uses macOS 26 private framework behavior and is intended for local
development validation while compatibility and distribution support are assessed.
