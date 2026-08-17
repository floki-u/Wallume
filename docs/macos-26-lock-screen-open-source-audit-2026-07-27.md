# macOS 26 Lock Screen Open-Source Audit (2026-07-27)

## Scope and conclusion

This is a source-level audit of open-source macOS video wallpaper and
screensaver projects, with a narrow question: can any implementation provide
a custom video on the real macOS 26 lock screen and legally, reliably enter a
Wallume release?

No audited project establishes a public, supported, shippable route for a
custom dynamic macOS 26 lock-screen wallpaper. Two directions remain useful
for isolated research only:

1. Aerial catalog registration with a fully formed entry and a deliberately
   encoded HEVC asset, as implemented by Phonto.
2. A third-party `com.apple.screensaver` App Extension, as used by Aerial 4.

Neither direction may be added to Wallume's release path unless it passes
repeatable real-device acceptance and an explicit distribution review. Both
rely on mechanisms Apple has not published as a supported third-party
lock-screen video API.

## Evaluation criteria

- **Mechanism**: actual code path, rather than a product claim or screenshot.
- **Tahoe evidence**: a reproducible, source-backed test of lock, unlock,
  second lock, and restart. A README assertion is recorded as an author claim,
  not as acceptance evidence.
- **Release suitability**: considers both the repository license and the
  stability/review risk of the underlying macOS mechanism. This is an
  engineering distribution assessment, not legal advice.
- **POC discipline**: no experimental write belongs in Wallume or the main
  macOS user account. Any mutating test needs a disposable macOS user or VM,
  pre-state backups, checksums, and verified restoration.

## Candidate matrix

| Candidate | Actual implementation | Tahoe reliability evidence | Release suitability | Recommended POC |
| --- | --- | --- | --- | --- |
| GonzaloRojas14/Wallpaper-Sync | Replaces a downloaded Aerial `.mov`, changes the undocumented Wallpaper Store `Idle` choice, writes a lock-screen poster, then kills `WallpaperAgent` and `WallpaperAerialsExtension`. | README claims Tahoe support, but the repository has no automated test suite or source-level second-lock/restart acceptance. | MIT source license, but the product mechanism mutates undocumented system state and kills system components. Not suitable as a Wallume release dependency. | Negative-control isolated test only; compare against the Phonto catalog approach. |
| thusvill/LiveWallpaperMacOS | Uses a borderless `NSWindow` below desktop icons with `AVQueuePlayer`, `AVPlayerLooper`, and `AVPlayerLayer`. | The README explicitly states it does not play video on the lock screen. | GPL-3.0 source cannot be copied into a non-GPL Wallume distribution. The public AppKit/AVFoundation desktop pattern may be independently implemented. It does not solve lock screen. | Read-only architecture reference or desktop-only behavior test. |
| JohnCoates/Aerial | Traditional `.saver`: `ScreenSaverView` renders video through `AVPlayerLayer`. | No macOS 26 dynamic-lock-screen acceptance. Source includes legacy Sonoma workarounds and targets the traditional ScreenSaver host. | MIT source license. Useful screensaver reference only; it is not a native lock-screen wallpaper implementation. | Verify Tahoe's legacy `.saver` enumeration in a disposable user, without treating it as a lock-screen wallpaper result. |
| AerialScreensaver/Aerial 4 + PaperSaver | Bundled `com.apple.screensaver` App Extension; PaperSaver discovers/registers extensions and writes `Desktop` and `Idle` entries into the undocumented Wallpaper Store before restarting `WallpaperAgent`. | Aerial claims Sonoma/Tahoe compatibility, but its checked-in tests do not demonstrate real lock/unlock/restart video playback. Current `WallpaperContinuity` source writes a still frame; it is not proof of live lock-screen wallpaper playback. | MIT source licenses, but the extension API declarations and Wallpaper Store writes are private/undocumented. Not a supported App Store or stable release route. | Separate minimal App Extension POC: establish whether Tahoe invokes a third-party video saver when locked, then test `Idle` only. |
| museslabs/phonto | Transcodes to HEVC Main10 with two temporal layers, creates thumbnail assets, registers a full category and asset in Aerial `entries.json`, then restarts `WallpaperAerialsExtension`. | README and code comments assert this bitstream shape supports multiple lock cycles. There is no checked-in real-device acceptance harness or recorded Tahoe run. | GPL-3.0 and undocumented Aerial catalog mutation: cannot be copied into Wallume or shipped as its product mechanism. It is the strongest isolated technical hypothesis. | Highest-priority isolated POC: catalog + media format + 5 lock cycles + restart + rollback. |
| Proton0/WallpaperVideoExtensionFix | Watches unlock notifications and sends `SIGKILL` to `WallpaperVideoExtension`. | README acknowledges a gray/black display around login. This is failure evidence, not validation. | No license file was present in the repository root at audit time; do not copy. Killing the renderer is not a release-quality recovery strategy. | Do not execute; retain only as evidence that restart-based workarounds produce visible defects. |

## Detailed evidence

### 1. Wallpaper-Sync: Aerial slot replacement

The lock-screen script targets the user's Aerial video directory and manifest:

- `AERIALS_DIR` is `~/Library/Application Support/com.apple.wallpaper/aerials/videos`.
- `INDEX_PLIST` is `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`.
- Installation copies the input video over an existing Aerial file, assigns the
  Aerial ID to the `Idle` choice, regenerates a lock-screen PNG, and restarts
  Wallpaper processes.

Evidence:

- [Aerial paths and atomic replacement](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/bin/_set_lockscreen_video.py#L27-L72)
- [Index.plist mutation and process restart](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/bin/_set_lockscreen_video.py#L166-L205)
- [Installation sequence](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/bin/_set_lockscreen_video.py#L228-L272)
- [Author claim of Tahoe support and required Aerial setup](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/README.md#L28-L44)

The desktop renderer is a conventional public-API window placed beneath desktop
icons. It hides that window while locked so the native Aerial route is expected
to take over.

- [Desktop window level and lock behavior](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/app/WallpaperEngine.swift#L9-L17)
- [Hide desktop window at lock](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/app/WallpaperEngine.swift#L69-L75)

This is materially the same family of experimentation previously rejected for
Wallume: it has no trustworthy reload contract, and a local write may appear to
work once while failing after a second lock or restart.

### 2. LiveWallpaperMacOS: public desktop playback only

The daemon creates an `NSWindow` at `kCGDesktopWindowLevel - 1`, attaches an
`AVPlayerLayer`, and loops the selected asset with `AVPlayerLooper`.

- [Desktop window and AVFoundation playback](https://github.com/thusvill/LiveWallpaperMacOS/blob/490a51e695fa2de6d29956b16649694fe00dc70d/wallpaperdaemon/daemon.mm#L203-L292)
- [Explicit lock-screen limitation](https://github.com/thusvill/LiveWallpaperMacOS/blob/490a51e695fa2de6d29956b16649694fe00dc70d/README.md#L61-L62)
- [GPL-3.0 license](https://github.com/thusvill/LiveWallpaperMacOS/blob/490a51e695fa2de6d29956b16649694fe00dc70d/LICENSE)

Its value is limited to independently implementing desktop rendering with
public APIs. It confirms that an ordinary process cannot remain visible in the
real lock-screen compositor.

### 3. JohnCoates/Aerial: legacy ScreenSaverView

The original project derives `AerialView` from `ScreenSaverView` and uses an
`AVPlayerLayer` in that host. Its initializer identifies System
Preferences/ScreenSaverEngine as the runtime caller and contains legacy host
workarounds for Sonoma.

- [ScreenSaverView and AVPlayerLayer](https://github.com/JohnCoates/Aerial/blob/6b4aa82ab3d5e247a198d86c3d645fcf68c98fec/Aerial/Source/Views/AerialView.swift#L9-L25)
- [Traditional host and legacy behavior](https://github.com/JohnCoates/Aerial/blob/6b4aa82ab3d5e247a198d86c3d645fcf68c98fec/Aerial/Source/Views/AerialView.swift#L119-L168)
- [MIT license](https://github.com/JohnCoates/Aerial/blob/6b4aa82ab3d5e247a198d86c3d645fcf68c98fec/LICENSE)

It is not evidence for a custom dynamic wallpaper in Tahoe. A legacy saver can
be a screensaver experiment, but it must not be relabeled as a native lock
screen wallpaper implementation.

### 4. Aerial 4 and PaperSaver: private modern screensaver extension

Aerial 4's extension declares the `com.apple.screensaver` extension point.
Its local header explicitly identifies the `ScreenSaverExtension` and related
view-controller classes as private APIs. The project README acknowledges that
the App Extension API is private.

- [Extension point declaration](https://github.com/AerialScreensaver/Aerial/blob/15f9c35b9db69795325eab608fa00f11ef13a0a3/AerialScreenSaverExtension/Info.plist#L15-L21)
- [Private API declarations](https://github.com/AerialScreensaver/Aerial/blob/15f9c35b9db69795325eab608fa00f11ef13a0a3/AerialScreenSaverExtension/PrivateHeaders/ScreenSaverPrivate.h#L1-L40)
- [Project statement that the API is private](https://github.com/AerialScreensaver/Aerial/blob/15f9c35b9db69795325eab608fa00f11ef13a0a3/README.md#L13-L17)

The present `WallpaperContinuity` implementation is notable because it is not
a live wallpaper path: it captures a still frame and sets desktop wallpaper
state. The file comments also say that the `.appex` does no wallpaper work.

- [Continuity is a still-frame implementation](https://github.com/AerialScreensaver/Aerial/blob/15f9c35b9db69795325eab608fa00f11ef13a0a3/Aerial/Model/WallpaperContinuity.swift#L1-L23)

PaperSaver is an engineering map of the Sonoma+ Wallpaper Store, not a public
API wrapper. It declares private CoreGraphics functions for space discovery,
then writes provider choices into the Store's `Desktop` and `Idle` slots and
restarts WallpaperAgent. Its own README says it is work in progress and not
ready for production.

- [Private CoreGraphics declarations](https://github.com/AerialScreensaver/PaperSaver/blob/f38915ef1a4ac9e6c7a840802562d52a9f24fb8b/Sources/PaperSaverKit/ScreensaverManager.swift#L1-L10)
- [Wallpaper Store extension writer](https://github.com/AerialScreensaver/PaperSaver/blob/f38915ef1a4ac9e6c7a840802562d52a9f24fb8b/Sources/PaperSaverKit/WallpaperManager.swift#L406-L452)
- [Work-in-progress warning](https://github.com/AerialScreensaver/PaperSaver/blob/f38915ef1a4ac9e6c7a840802562d52a9f24fb8b/README.md#L1-L27)

This direction is worth a minimal isolated runtime experiment because it is
architecturally distinct from Aerial asset replacement. It remains unsuitable
for a shipping dependency until Apple publishes and supports the extension
point and configuration contract.

### 5. Phonto: strongest media/catalog hypothesis, still unsupported

Phonto does more than replace an existing Aerial video. It creates a complete
custom catalog entry, category and thumbnail. It uses a HEVC Main10 encoder
configuration that sets `NumberOfTemporalLayers` to two, documenting that this
is intended to re-arm playback across lock cycles. It then kills the Aerial
extension so it rereads the catalog.

- [Pipeline and private-entitlement dependency](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/install.rs#L1-L16)
- [Aerial catalog paths and registration flow](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/install.rs#L199-L265)
- [Manifest/category write and forced reload](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/install.rs#L301-L472)
- [Temporal-layer encoder setting](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/transcode.rs#L221-L235)
- [GPL-3.0 license](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/LICENSE)

The codec and catalog shape are a legitimate unknown to test. The repository's
comments and README are not a substitute for the required Wallume acceptance:
five consecutive locks, unlock after each, restart, re-lock, no black frame,
and complete restoration of the pre-POC user state.

### 6. WallpaperVideoExtensionFix: negative evidence

This utility listens for `com.apple.screenIsUnlocked` and force-kills
`WallpaperVideoExtension`. Its README documents a gray or black display around
login. The source should be retained only as proof that force-restart recovery
has a visible failure mode.

- [Unlock-triggered SIGKILL](https://github.com/Proton0/WallpaperVideoExtensionFix/blob/e897fa7f665f567c00d1d57059ccf3e39cb535e2/main.cpp#L10-L43)
- [Documented gray/black login defect](https://github.com/Proton0/WallpaperVideoExtensionFix/blob/e897fa7f665f567c00d1d57059ccf3e39cb535e2/README.md#L5-L12)

## Recommended research sequence

### POC-A: Phonto-derived catalog and media acceptance

Run this only in a disposable macOS 26 user or virtual machine. Do not copy
Phonto's GPL code into Wallume; independently build the smallest test fixture
needed to validate the format and catalog hypothesis.

1. Capture checksums and copies of `Index.plist`, Aerial `entries.json`,
   Aerial videos, thumbnails, and lock-screen cache before the test.
2. Use a uniquely named HEVC Main10 test asset with temporal layers, thumbnail,
   and a complete new catalog category. Do not overwrite an Apple asset slot.
3. Select it through System Settings, then record five lock/unlock cycles and
   one restart followed by another lock.
4. Treat a black frame, first-frame-only result, lost picker category, or
   failed restoration as a failed POC.
5. Restore every altered file and confirm the original Apple Aerial works
   through a second lock after restoration.

Passing POC-A would prove an engineering behavior on the tested OS build only.
It would not turn the undocumented catalog into a release-safe Wallume API.

### POC-B: minimal screensaver App Extension

In a separate signed test app, implement only a visible timestamp/video test
view. First establish registration and loading through the system screensaver
path. Then test whether the extension is actually rendered in the locked state,
not merely in preview or idle mode.

This POC must not modify the Wallume target. It must separately evaluate:

- whether third-party `com.apple.screensaver` extensions are discoverable on
  the installed Tahoe build;
- whether the extension loads while the session is locked;
- whether it survives a second lock and restart;
- whether its private API usage can be signed, notarized and distributed under
  Wallume's intended channel.

Failure in any condition rejects this route as a core-feature implementation.

## Product decision

Wallume should keep macOS 26 custom dynamic lock screen unavailable in the
release UI until a route passes the above acceptance and distribution review.
The existing safety rule remains: do not write Aerial manifests, Wallpaper
Store indexes, lock-screen posters, or restart Wallpaper processes from the
product path. Experimental code, if approved later, must remain isolated from
the shipping target until it demonstrates stable behavior.
