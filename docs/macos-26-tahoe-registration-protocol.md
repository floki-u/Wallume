# macOS 26 Tahoe custom Aerial registration protocol

This note records the on-machine reverse analysis used for Wallume's Tahoe path. It is not a
claim that macOS exposes a public custom lock-screen API.

## Observed system contract

The user-level Aerial store is under:

- `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`
- `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`
- `~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/`
- `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`

The Aerial extension loads an asset by `assetID` (not the older `selectedID` shape). A valid
custom entry must be reachable from a category and a subcategory, and must provide a local video
URL and preview-image URL. The observed extension contains manifest/archive loading and Aerial
asset category/subcategory types. The unpacked `entries.json` and `manifest.tar` were semantically
identical on the investigated Tahoe installation; the agent-facing editable document is the
unpacked manifest.

`Index.plist` contains many independent `Idle` values: system default, displays, space defaults
and space/display combinations. Their providers are not uniformly Aerials. Replacing all of
them is unsafe: it collapses the user's multi-display and per-space choices in System Settings.
The only mutation candidates are the selected main display's direct
`Displays/<display UUID>/Idle` entry and its `Spaces/<space UUID>/Displays/<display UUID>/Idle`
entries. The current desktop-space UUID is not exposed through a stable public API, so Wallume
updates every space for that one display and journals each value separately; it never mutates a
different display or a global override. The sole exception is an Index which already has no
display/space entries because macOS is in global automatic mode: Wallume then changes only the
existing `AllSpacesAndDisplays/Linked` and `SystemDefault/Linked` choices and restores them
exactly. It never converts a per-display setup into global mode.

## Wallume transaction

1. Before any system file is changed, re-encode the desktop playback variant into a private
   staging movie matching the observed native Aerial media contract: HEVC Main10, 10-bit,
   constant 240 fps and an exact 240000 Hz track time scale. Reject an output that does not
   pass this inspection; never register a normal 8-bit/60-fps desktop export as a Tahoe Aerial.
2. Create an owned video and a PNG image preview beneath the Aerial user directory.
3. Add the asset under the stable Wallume category and subcategory in `entries.json`.
4. Configure only the selected display's direct and per-space `Idle → Content → Choices`
   values with the Aerial provider and `assetID`, retaining exact prior values.
5. Snapshot only the current-host `com.apple.screensaver/moduleDict` key, then point it to the
   built-in `WallpaperAerialsExtension`; never replace the complete screen-saver preference
   domain.
6. Verify the copied media, manifest and index before restart; clear only derived Aerial bitmap
   cache and restart the wallpaper agent.
7. On reset or a failed transaction, restore only paths still equal to Wallume's post-write
   value. Restore the screen-saver key only when it still points at Apple's Aerial extension;
   retain a later user choice. Keep externally changed files as conflicts rather than overwriting
   them.

## Acceptance checks

Wallume must not call the operation synchronised merely because local files were written. The
release acceptance check is:

1. The Wallume category is visible in System Settings > Wallpaper.
2. The custom item has a preview and can be selected there.
3. After locking, unlocking and locking again, `WallpaperAerialsExtension` opens the owned movie
   and renders it rather than a black surface. Opening the movie alone is insufficient evidence.
4. Reset removes only Wallume's asset/category/thumbnail and restores all recorded `Idle` values.

If any check fails, the UI must report a pending/failed system verification rather than success and
keep reset available.
