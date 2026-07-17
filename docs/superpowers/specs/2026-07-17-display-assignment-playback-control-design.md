# Display assignment and playback control design

Date: 2026-07-17

## Scope

This is phase four, batch two. It connects the tested runtime core to the application shell and delivers display discovery, persistent per-display wallpaper assignment, three presentation modes, and global playback pause/resume.

This batch does not implement lock-screen synchronization UI, performance UI, settings UI, localization, volume control, packaging, or hardware performance certification. Playback remains muted. The existing `wallume-runtime` executable remains available for diagnostics and later hardware benchmarking, but the application UI does not control it as a subprocess.

## Product behavior

### Display inventory

The Displays page shows connected displays and remembered disconnected displays. Each display entry includes a stable identifier, display name, pixel dimensions, main-display status, connection status, current media assignment, presentation mode, and runtime error state.

Connected displays can receive, replace, or remove an assignment. A disconnected display retains its assignment and presentation mode, is clearly marked offline, and automatically resumes its saved assignment when it reconnects. The user may explicitly clear a disconnected display's saved configuration.

### Assigning from the gallery

The media detail view adds a Set as Wallpaper action. It opens a selector containing connected displays only. The selector supports individual checkboxes and Select All, shows existing assignments, summarizes the number of targets, and disables confirmation until at least one display is selected.

Confirmation validates the complete operation, writes all selected assignments as one persisted update, and then reconciles the running wallpaper sessions. Assigning the same media to several displays continues to share one playback resource.

### Playback controls

Wallume exposes one global Pause or Resume action in both the main window toolbar and the status-item menu. It controls the `.user` runtime pause reason and never removes environmental reasons such as screen lock, sleep, low power, thermal pressure, or full desktop occlusion. The status item reports whether playback is running or paused and how many displays currently have active wallpaper sessions.

The user's pause choice is persisted. Relaunching the application therefore respects an intentional paused state. Environmental pause reasons are transient and are recomputed from the current system state.

### Presentation modes

Each assigned display independently stores one of three modes:

- Fill: preserve aspect ratio and crop overflowing edges. This is the default.
- Fit: preserve aspect ratio and show the complete frame, allowing letterboxing.
- Stretch: fill the display without preserving aspect ratio.

Displays that share a media item share its player while their presentation surfaces apply presentation modes independently.

## Architecture

### In-process runtime

`WallumeApp` owns a single in-process `WallpaperRuntimeService`. Closing the main window does not stop wallpaper playback. The service stops only during formal application termination, when it removes observers, closes desktop surfaces, and releases playback resources in order.

`WallpaperRuntimeService` composes the existing `RuntimeCoordinator`, shared `PlayerPool`, AppKit desktop surfaces, screen provider, environment monitor, and occlusion monitor. It consumes complete snapshots of displays, assignments, presentation modes, and pause reasons and applies incremental updates. Unchanged sessions and players are not restarted.

The standalone `wallume-runtime` diagnostic executable continues to compile and use the same core components, but it is not part of the UI control path.

### Display catalog

`DisplayCatalog` converts AppKit screen snapshots into application-facing `DisplayRecord` values. Stable IDs come from the CoreGraphics display UUID associated with the screen's `CGDirectDisplayID`, not from `NSScreen` object identity. If CoreGraphics cannot produce a UUID, the provider uses a namespaced fallback based on the direct display ID for the current connection and marks that identity as nonpersistent; the catalog must not silently merge it with a remembered persistent display.

The catalog maintains the current connected snapshot and joins it with remembered display metadata from the assignment document. A connected record replaces remembered name, dimensions, and main-display status with current values. A missing remembered display remains visible as disconnected.

### Assignment store

`DisplayAssignmentStore` is the authoritative owner of a versioned `display-assignments.json` document. Each entry contains:

- stable display ID and last known display metadata;
- assigned media UUID, when present;
- presentation mode;
- whether the display identity is persistent.

The document also stores the global user-paused choice. Updates are serialized and written with the existing atomic JSON storage infrastructure. A batch gallery assignment is one store mutation, so a validation or persistence failure changes neither the document nor the running snapshot.

The existing gallery usage checker reads this same schema. Removing or replacing an assignment immediately changes deletion eligibility after the store publishes its new snapshot.

### Application state and controllers

`ApplicationController` constructs the store, catalog, runtime service, Displays feature model, gallery assignment presenter, and shared playback-control model. On launch it loads the persisted document, starts display observation and environmental monitors, and performs the initial reconcile. The UI observes immutable view-state snapshots rather than reaching into runtime components.

The runtime service reports per-display session state and failure details back to the display model. The UI submits commands through focused interfaces for assignment, presentation mode, removal, retry, and global pause state.

## Data flow

### Application launch

1. Load and validate the assignment document.
2. Obtain the current display snapshot and join it with remembered displays.
3. Restore the persisted `.user` pause reason when required.
4. Validate referenced media against the library.
5. Reconcile valid connected assignments into wallpaper sessions.
6. Publish display, playback, and error snapshots to the SwiftUI and status-item surfaces.

### Batch assignment

1. The user chooses a media item and one or more connected displays.
2. The command validates the media, targets, and requested modes against one current snapshot.
3. The store atomically writes one updated document containing all targets.
4. The runtime service receives the new assignment snapshot and reconciles only changed sessions.
5. The display page, status item, and gallery usage state refresh from the committed snapshot.

### Display changes

1. AppKit publishes a complete screen snapshot.
2. The catalog marks missing remembered records offline and identifies reconnected records by stable ID.
3. Runtime reconciliation closes sessions for disconnected displays without deleting their assignments.
4. A reconnected display automatically recreates its saved session if its media is available.

## UI design

### Displays page

The page uses a vertical collection of display cards consistent with the existing application shell. A card header contains the display name, online or offline badge, main-display badge, and resolution. Its body contains the current wallpaper thumbnail and media name, or an unassigned state. Its controls provide Replace Wallpaper, Remove, and presentation-mode selection.

Offline cards disable playback-affecting controls and expose Clear Saved Configuration. Runtime failures appear on the affected card with a concise message and Retry action. A document-level load failure appears as a page-level alert because assignments cannot be trusted.

### Display selector

The gallery detail action presents a sheet with connected display rows, current assignment context, individual selection, Select All, a target count, Cancel, and Confirm. The sheet is a selection and confirmation surface only; presentation mode continues to use the target display's saved mode, defaulting to Fill for a first assignment.

### Shared playback control

The main toolbar and status-item menu bind to the same playback-control model. Both surfaces use the effective state: if any pause reason is active, they show Resume only when the user pause reason is active and otherwise explain that playback is paused by the system. Removing the user reason does not claim that playback resumed while another reason remains.

## Validation and failure handling

- Assignment commands reject unavailable media, offline targets, empty target sets, duplicate targets, and invalid presentation values before persistence.
- Atomic write failures preserve the prior document and prior running snapshot.
- A malformed or unsupported assignment document fails closed: Wallume preserves the file, starts no untrusted assignments, and shows an actionable error. It does not overwrite the file automatically.
- A missing media file preserves the assignment, reports Media Unavailable, and allows replacement or removal.
- Player or desktop-surface failure is isolated to its display. Successful displays continue running and the persisted assignment remains available for retry.
- Runtime reconciliation is idempotent. Retrying an unchanged successful display does not recreate its player.
- Application termination first stops observation, then closes display sessions, and finally releases pooled playback resources.

## Testing and acceptance

Unit and integration coverage includes:

- stable and fallback display identity mapping;
- online, offline, and reconnect catalog behavior;
- versioned document decoding, migration, serialized atomic updates, write failure, and corrupt-file protection;
- transactional multi-display assignment and shared player reference counts;
- Fill, Fit, and Stretch mapping on independent presentation surfaces;
- incremental reconcile behavior for assignment and display changes;
- global user pause persistence and composition with environmental pause reasons;
- missing media, single-display player or surface failure, retry, and unaffected-display continuity;
- immediate gallery deletion-guard refresh after replace or removal;
- Displays page, display-selector sheet, toolbar, and status-item state tests;
- closing the main window while runtime playback remains active and ordered cleanup at application termination.

Completion gates are the full Swift test suite, release builds of `WallumeApp`, `wallume-runtime`, `wallume-media`, and `wallume-restore`, `git diff --check`, and completion review with no unresolved critical or important findings. Hardware performance certification remains deferred and is recorded separately rather than blocking engineering completion of this batch.
