# Wallume application shell and gallery

## Launch behavior

`WallumeApp` is an AppKit menu-bar application with SwiftUI feature pages. The first launch opens the gallery. Later launches remain in the menu bar unless the `openGalleryAtLaunch` preference is enabled by the later settings page.

The sidebar has stable Gallery, Displays, Lock Screen, Performance, and Settings entries. This batch implements Gallery; the other pages clearly identify themselves as later-batch features.

## Importing media

Use Import Files, Import Folder, or drag files/folders into the gallery. Folder scanning is recursive. Hidden files, hidden directories, package contents, and formats other than MOV/MP4 are ignored. Candidates are deduplicated and processed in stable path order.

Only one item is inspected/transcoded at a time. The bottom task drawer shows the current stage, progress, queue history, scan warnings, and final imported/duplicate/failed/cancelled totals.

- Cancel Current waits for the current item's temporary artifacts to be cleaned, then continues.
- Cancel All cancels the current item and every waiting item; completed imports remain.
- A failed item does not stop later items. Retry and Retry All Failed create visible new attempts.

Closing the gallery releases its SwiftUI page tree but keeps the queue alive. The menu bar displays progress and cancellation actions. Completion produces an in-app result while the gallery is visible and active; otherwise Wallume requests notification permission and sends a local completion notification.

Quitting during an active queue requires confirmation. Confirming cancels all and waits for cleanup before process termination.

## Gallery and details

Gallery search matches names, codec, and dimensions. Details show media metadata and load no video decoder until Play Preview is clicked. Preview is always muted and its player is released when details close. Finder reveal is non-destructive.

Deletion never removes the original source file. A media item referenced by a display configuration cannot be deleted; Wallume lists those displays and requires the user to change their wallpaper first.

## Remaining phase-four batches

1. Display configuration, wallpaper assignment, and playback controls.
2. Lock-screen, performance, and settings pages.
3. Localization, state restoration, UI acceptance, and phase-four completion.
