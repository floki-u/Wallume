# Wallume application shell and gallery

## Launch behavior

`WallumeApp` is an AppKit menu-bar application with SwiftUI feature pages. The first launch opens the gallery. Later launches remain in the menu bar unless the `openGalleryAtLaunch` preference is enabled by the later settings page.

The sidebar has stable Gallery, Displays, Lock Screen, Performance, and Settings entries. Gallery and Displays are implemented; the other pages clearly identify themselves as later-batch features.

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

## Display assignment and playback

Open a media item's details and choose Set as Wallpaper to select one or more connected displays. The selector supports individual targets and Select All, shows each target's current assignment, and commits the selection as one persisted update.

The Displays page lists connected displays plus remembered disconnected displays. Each connected display card shows its current wallpaper, resolution, main-display state, runtime errors, and controls for replacing or removing the wallpaper. Presentation is configured independently per display as Fill, Fit, or Stretch; new assignments default to Fill. A disconnected display keeps its assignment and presentation mode and restores them when the same stable display identity reconnects. Its remembered configuration can also be cleared explicitly.

Wallume owns wallpaper playback inside the menu-bar application. Closing the gallery window does not stop playback. Media assigned to several displays shares one player for lower resource use while each desktop surface keeps its own presentation mode. Playback is muted, and this batch intentionally has no volume control.

Pause and Resume are global, persisted controls available on the Displays page and status-item menu. User pause composes with system pause reasons such as sleep, screen lock, thermal pressure, or full app obscuration; removing the user pause does not falsely report playback as active while a system reason remains. A player or desktop-surface failure remains isolated to its display and can be retried without deleting the saved assignment.

## Remaining phase-four batches

1. Lock-screen, performance, and settings pages.
2. Localization, state restoration, UI acceptance, and phase-four completion.

True hardware performance certification remains deferred until the required target Mac is available.
