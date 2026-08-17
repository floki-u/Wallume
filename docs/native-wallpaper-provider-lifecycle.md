# Native wallpaper provider lifecycle

The macOS 26 native provider is a separate extension bundle. It never modifies
Apple Aerial assets or `com.apple.wallpaper` Store files directly. Wallume only
copies the selected media and its already-generated cover image into its own
provider sandbox directory:

`~/Library/Containers/com.wallume.app.wallpaper/Data/Documents/`

The deployment includes `wallpaper.mov`, `fallback.jpg`, and guarded video
metadata in a per-media directory. The extension can read only this container;
the main app remains responsible for copying the selected media into it.

## Failure and fallback

If the provider cannot be selected, cannot render, or fails a lock-screen
verification, Wallume must leave the current system selection unchanged. The
lock-screen page offers the imported video's generated cover image as a static
fallback and opens System Settings so the user can choose it manually. It must
also keep reset/recovery controls available; a fallback is never applied
silently.

## Reset and uninstall

Before resetting or removing Wallume, the user selects another wallpaper in
System Settings. Once the system no longer references Wallume's provider, the
application records that reset and removes only its own provider directory.
The packaged uninstall flow invokes:

```sh
wallume-provider-cleanup status
wallume-provider-cleanup confirm-system-reset
wallume-provider-cleanup cleanup
```

`cleanup` deliberately refuses while the recorded provider is active. This
prevents deleting a video which `WallpaperAgent` may still be rendering. The
main Wallume media library is not deleted by this command.
