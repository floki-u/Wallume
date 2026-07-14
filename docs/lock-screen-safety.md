# Lock Screen Safety

Wallume treats macOS lock-screen wallpaper integration as private, version-gated system state. Phase 1 supports only macOS major versions 14, 15, and 26. Unsupported major versions are report-only and cannot perform writes.

## Observed System Paths

Wallume derives all paths from an injected home directory and the current user's GeneratedUID:

- `~/Library/Application Support/com.apple.wallpaper/aerials/videos`
- `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`
- `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`
- `/Library/Caches/Desktop Pictures/<GeneratedUID>/lockscreen.png`

These paths are private implementation details of macOS. Wallume must not assume they are stable outside the explicitly supported macOS generations.

## Read And Write Scope

Wallume may read:

- the Aerial manifest `entries.json`;
- downloaded Aerial `.mov` files in the videos directory;
- `Index.plist`;
- the current lock-screen poster;
- Wallume transaction journals and backups.

Wallume may write only after an explicit install or restore command:

- the selected manifest-backed Aerial `.mov` slot;
- the narrow Idle Aerial configuration fragments inside `Index.plist`;
- `lockscreen.png`;
- Wallume-owned transaction journals, restore artifacts, and backups under `~/Library/Application Support/Wallume`;
- Wallume's exact backup marker beside the selected Aerial video.

`entries.json` is always read-only. Wallume never writes `/System`, never requests root, and never changes authentication or unlock behavior.

## Explicit Slot Rule

Wallume never chooses the first Aerial slot implicitly. Installation requires an explicit Aerial UUID that is present in `entries.json` and has a matching downloaded `.mov` file. Any foreign backup or unknown sidecar file for that slot blocks installation.

## Transaction Phases

Install transactions are durable journals:

- `prepared`: backups and planned changes exist, but target replacement has not completed.
- `writing`: one or more target writes may have happened.
- `committed`: Wallume completed the install and verified target state.
- `restoring`: recovery has started and can be resumed after a crash.
- `restored`: recovery completed cleanly.
- `conflicted`: recovery detected external or system changes and preserved them.

Every system write is preceded by preflight, durable journal creation, same-directory staging, validation, atomic replacement, verification, and compare-and-restore recovery. A crash in `prepared`, `writing`, or `restoring` must leave enough journal and backup state for `wallume-restore` to resume safely.

## Compare-And-Restore

Recovery restores only values Wallume still owns:

- A file is restored only when the current file hash still equals Wallume's installed hash.
- A file that did not exist before install is removed only when its current hash still equals Wallume's installed hash.
- An `Index.plist` fragment is restored only when the current fragment still equals Wallume's installed fragment.
- Any external or system change becomes a conflict and is never overwritten.
- Backups survive until every owned value has been verified cleanly restored.

When a conflict exists, Wallume retains the related backups and marks the journal `conflicted` for later inspection.

## Manual Deletion

macOS does not call an app-specific uninstall hook when a user drags an app bundle to the Trash. The standalone `wallume-restore` tool exists so recovery remains available even if the future app bundle is missing.

## Recovery Tool

Examples:

```bash
wallume-restore status
wallume-restore probe
wallume-restore restore 00000000-0000-0000-0000-000000000000
wallume-restore restore-all
```

`status` lists recoverable or conflicted transactions and does not write. `probe` reports supported generation, path presence, available slots, and foreign backup names. `restore` and `restore-all` are explicit write commands and refresh only `WallpaperAgent` and `WallpaperAerialsExtension` after a real restoration.

## Live Testing Boundary

Automated tests use fixtures and temporary directories only. They must not read or write the developer's live wallpaper data. Live installation testing is outside automated tests and requires a dedicated downloaded Aerial slot selected by explicit UUID. Before and after any live read-only probe, record hashes for the live `Index.plist` and discovered `.mov` slots and confirm they are unchanged.
