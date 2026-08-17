# macOS 26.6 dynamic lock-screen revalidation

**Date:** 2026-08-14

**Host observed:** macOS 26.6 (25G72), Darwin 25.6.0, arm64
**Scope:** read-only revalidation only. This investigation did not modify wallpaper data,
preferences, caches, system settings, processes, account state, or product source.

## Decision

macOS 26.6 still has a native, Apple-owned dynamic Aerial path that animates on
lock and unlock. It does **not** expose a public, third-party API to register
custom dynamic lock-screen content.

There are three materially different unsupported routes:

1. **Apple-Aerial overwrite:** replace an existing Apple cache movie, patch its
   selection, optionally replace a poster, and restart wallpaper services. This
   is a known-bad route: it mutates an Apple identity and has already produced
   black/reverted playback on Tahoe. It is not a candidate for a product or a
   new POC.
2. **Phonto-style catalog registration:** add a new asset, thumbnail, category,
   and subcategory to the Aerial manifest, then let Apple's signed Aerial
   extension render it. This is the only remaining implementation hypothesis
   worth testing for behavior, but it still relies on undocumented user-store
   writes and a forced reload. A pass on 25G72 would be an isolated OS-behavior
   result, not a shippable API approval.
3. **Private-framework provider emulation:** embed a normally signed
   `com.apple.wallpaper` ExtensionKit extension, load
   `WallpaperExtensionKit` dynamically, and reproduce the host's private XPC
   protocol and remote `CAContext` rendering contract. This avoids claiming
   Apple's private entitlement, but it is still private API and depends on
   runtime class layouts. It is now the highest-value isolated POC because it
   aims to become the provider rather than placing an untrusted movie inside
   Apple's Aerial catalog.

The required product feature therefore remains **blocked for release** on
macOS 26.6 until Apple publishes an entitlement-free supported interface, or a
separate distribution/legal decision explicitly accepts an unsupported,
build-specific implementation. The next technical step is P0.5 below, in a
disposable macOS user or VM only.

## Evidence boundary

The report distinguishes the following levels of evidence:

- **Observed:** obtained from the current 25G72 installation with the listed
  read-only command.
- **Upstream source:** behavior stated by a fixed Git commit; it is not an
  Apple guarantee.
- **Inference:** a conclusion drawn from the observed architecture. It is
  labeled as such and must not be promoted to a public API claim.

Earlier 26.5.2 runtime failures are retained as negative evidence, but were not
reproduced on this daily-use account because the requested scope prohibits
wallpaper writes, locking, restarts, and reboots.

## 1. ExtensionKit provider eligibility

### Observed contract on 25G72

`com.apple.wallpaper` is a system-defined ExtensionKit point, not a public SDK
surface. Its descriptor requires both an extension and host entitlement:

```plist
{
  "com.apple.wallpaper" => {
    "EXRequiredEntitlements" => {
      "com.apple.private.wallpaper.extension" => true
    }
    "EXRequiredHostEntitlements" => {
      "com.apple.private.wallpaper.extension-host" => true
    }
  }
}
```

The installed Apple providers all declare that point and are registered by
PlugInKit. The observed registered identifiers are Apple identifiers only,
including `com.apple.wallpaper.extension.dynamic`, `.aerials`, `.legacy`,
`.sequoia`, and `.image`.

The host is `com.apple.wallpaper.agent`. Its visible entitlement set includes
both `com.apple.extensionkit.host.extension-point-identifiers` for
`com.apple.wallpaper` and `com.apple.private.wallpaper.extension-host`.
The `WallpaperDynamicExtension` and `WallpaperLegacyExtension` visible
entitlement sets each contain `com.apple.private.wallpaper.extension`.

There is one important 26.6 nuance: the current visible entitlement blob for
`WallpaperAerialsExtension` does **not** show that key, although the extension
point requires it and the system-signed Aerial extension is registered and
running. This may be an Apple platform-signing/requirement detail rather than a
general exemption. It is not evidence that an ordinary Developer ID app can
register a provider. The only safe conclusion is that a third-party provider
cannot satisfy the documented-on-device requirement using public signing.

The public 26.6 SDK reinforces the boundary: `ScreenSaver.framework` exposes
`ScreenSaverView`; a header/interface scan found no public `WallpaperKit`,
`WallpaperProvider`, `ScreenSaverExtension`, or `ScreenSaverViewController`
contract. `NSWorkspace.setDesktopImageURL` is explicitly an API for a desktop
**image** URL and a specified `NSScreen`, not a lock-screen video API.

### Exact local commands

All commands below are read-only and were run from
`/Users/floki/NetCode/Wapper/Wallume`:

```sh
sw_vers
plutil -p /System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt
pluginkit -m -A -D -p com.apple.wallpaper
codesign -dvv --entitlements :- \
  /System/Library/ExtensionKit/Extensions/WallpaperDynamicExtension.appex
codesign -dvv --entitlements :- \
  /System/Library/ExtensionKit/Extensions/WallpaperLegacyExtension.appex
codesign -dvv --entitlements :- \
  /System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex
codesign -dvv --entitlements :- \
  /System/Library/CoreServices/WallpaperAgent.app
SDK=$(xcrun --show-sdk-path)
find "$SDK/System/Library/Frameworks/ScreenSaver.framework" -type f \
  \( -name '*.h' -o -name '*.swiftinterface' \) -print \
  -exec sh -c 'rg -n "ScreenSaver(View|Extension|ViewController)" "$1"' _ {} \;
find "$SDK" -type f \( -name '*.h' -o -name '*.swiftinterface' \) -print0 \
  | xargs -0 rg -l 'WallpaperKit|WallpaperProvider|com\\.apple\\.wallpaper|ScreenSaverExtension|ScreenSaverViewController'
```

### Risk classification

| Route | Evidence | Risk | Release eligibility |
| --- | --- | --- | --- |
| Third-party `com.apple.wallpaper` provider | Private extension and host entitlements required; no public SDK contract | **Critical**: signing/host rejection and private-API distribution risk | No |
| Traditional `.saver` / public `ScreenSaverView` | Public drawing API only; it is not a dynamic wallpaper provider | **High**: wrong lifecycle/surface for the requirement | No, except as a separate screen-saver feature |
| Private modern screen-saver extension | Internal route exists but has no public developer contract | **Critical**: private API and behavior cannot be promised | No |

## 2. Built-in Aerial fullscreen and lock behavior

### What 26.6 proves

Apple's current macOS user guide says that Landscape, Cityscape, Underwater,
and Earth aerials animate when the user locks or unlocks the Mac, and that the
selected aerial is used as the screen saver by default. This establishes that
the *built-in Aerial* path is the native dynamic lock/unlock path.

The local runtime is consistent with that description:

- `WallpaperAgent` (PID 745 during observation) launched the Apple-signed
  `WallpaperAerialsExtension` (PID 768) through ExtensionKit with decoded
  arguments `{"serviceName":"com.apple.wallpaper.extension.aerials",
  "enhancedSecurity":false,"type":1}`.
- The Aerial extension is version `245.6`, targets SDK `26.6`, and has
  minimum system version `26.6`.
- `WallpaperAgent` links private `WallpaperExtensionKit`, `WallpaperFoundation`,
  `WallpaperAerialAssets`, `WallpaperTypes`, and `Wallpaper.framework`, plus
  public `ScreenSaver.framework`.
- Read-only `strings` evidence in the agent includes
  `WallpaperExtensionKitWallpaperProviderDiscovery`,
  `ScreenSaverWallpaperProviderDiscovery`, `WallpaperScreenSaverWindow`,
  `screen-saver-catalog`, `wallpaper-extension-catalog`, and
  `useAsDesktopWallpaperAndIdleWallpaper`. The Aerial binary includes
  `AerialAssetManifestManager`, manifest/video/thumbnail storage names, and
  `selectedAerialIDs`.

These observations demonstrate an Apple-managed path joining wallpaper,
screen-saver/idle content, and Aerial catalog assets. They do **not** establish
that a custom asset can survive that lifecycle, nor do they establish behavior
at the pre-login login window. Those are runtime acceptance questions for an
isolated POC.

### Exact local commands

```sh
ps -axo pid,ppid,command \
  | rg 'WallpaperAgent|WallpaperAerialsExtension|WallpaperDynamicExtension|WallpaperLegacyExtension'
ps -axo command | rg '/WallpaperAerialsExtension ' \
  | sed -E 's/.*-LaunchArguments //' | head -1 | base64 -D
plutil -p /System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Info.plist
otool -L /System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent \
  | rg -i 'Wallpaper|ScreenSaver|DynamicDesktop|ExtensionKit'
strings /System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent \
  | rg -n 'useAsDesktopWallpaperAndIdleWallpaper|WallpaperScreenSaverWindow|ScreenSaverWallpaperProviderDiscovery|WallpaperExtensionKitWallpaperProviderDiscovery|com.apple.wallpaper.choice.helios|wallpaper-extension-catalog|screen-saver-catalog'
strings /System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/MacOS/WallpaperAerialsExtension \
  | rg -i -C 1 'manifest|thumbnail|catalog|selectedAerialIDs|video'
```

### Public and local sources

- [Apple: Customize the wallpaper on your Mac](https://support.apple.com/guide/mac-help/choose-your-desktop-picture-mchlp3013/mac)
- [Apple: `NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl%28_%3Afor%3Aoptions%3A%29)
- Local system files named in the commands above. They were installed with
  macOS 26.6 (25G72); they are implementation evidence, not API documentation.

## 3. Phonto catalog registration versus Apple-Aerial overwrite

### The two mechanisms are not equivalent

**Direct overwrite** is implemented by Wallpaper-Sync's current fixed commit.
It selects the first downloaded Apple Aerial movie, saves a backup, atomically
copies the user's movie into that Apple-named file, writes an `Idle`
configuration into `Store/Index.plist`, writes a per-user `lockscreen.png`
poster under `/Library/Caches/Desktop Pictures`, and calls `killall
WallpaperAgent WallpaperAerialsExtension`.

Source: [Wallpaper-Sync `_set_lockscreen_video.py`, lines 166-264](https://github.com/GonzaloRojas14/Wallpaper-Sync/blob/09716bfc1922620994cb151fee62fcc299c92b66/bin/_set_lockscreen_video.py#L166-L264).

This route replaces a resource whose identity and ownership belong to Apple.
It does not create a valid independent catalog entry. Previous Wallume Tahoe
evidence recorded that the Aerial cache could be rewritten/revalidated and
that subsequent lock cycles could become black. On this basis, classify direct
overwrite as **rejected** rather than a control worth repeating.

**Phonto catalog registration** is structurally different:

1. It creates a stable UUIDv5 for the source media and writes a HEVC Main10
   movie and a 640px thumbnail under the Aerial user store.
2. It upserts an asset record with `categories`, `subcategories`,
   `previewImage`, and `url-4K-SDR-240FPS` fields.
3. It creates/repairs a named category and non-empty subcategory with valid
   representative asset and preview references. Its source explains that
   malformed category metadata can cause the entire Aerial section to vanish
   from System Settings.
4. It kills `WallpaperAerialsExtension` so the next launch rereads the
   manifest. Its source says an existing UUID otherwise retains a cached
   `AVAsset`.
5. Its encoder sets `NumberOfTemporalLayers` to two and labels this necessary
   for re-arming across lock cycles. That is the project's empirical claim, not
   an Apple media specification.

Sources: [Phonto installer, lines 1-16](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/install.rs#L1-L16), [store paths and installation, lines 199-265](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/install.rs#L199-L265), [manifest/category construction, lines 301-472](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/install.rs#L301-L472), and [temporal-layer setting, lines 221-235](https://github.com/museslabs/phonto/blob/9eaa162135626d22617bca1bdbedb52567d76074/src/macos_live_lockscreen/transcode.rs#L221-L235).

The current 25G72 user store has the same broad shape as this hypothesis:
`entries.json` has `assets`, `categories`, `initialAssetCount`,
`localizationVersion`, and `version`; its categories have nested
subcategories. That observation confirms only the schema family, not that
Phonto's data is accepted by this build.

### Risk classification

| Mechanism | System state touched | Main failure modes | Risk | Product status |
| --- | --- | --- | --- | --- |
| Apple-Aerial overwrite | Apple cache movie, `Index.plist`, poster cache, running processes | Revalidation/reversion, black lock surface, damaged user selection, failed restore | **Critical** | Rejected |
| Phonto-style custom catalog | User Aerial manifest, video and thumbnail store, running Aerial extension | Whole catalog disappears, asset rejected, first-frame-only/black later cycle, OS update breakage, GPL contamination if copied | **Critical** | Isolated POC only |
| System UI with a user-selected image/Live Photo | User chooses content through System Settings | No documented Mac custom-video lock animation; no app-controlled configuration API | **Medium** for data safety; **High** for feature uncertainty | Optional non-product observation only |

The Phonto project is GPL-3.0. Its implementation must not be copied into
Wallume; an eventual isolated POC must be independently written from observed
format requirements and carry its own licensing review.

## Executable POC acceptance matrix

All executions below are **future work**. They must run in a new disposable
macOS 26.6 user or a VM snapshot. Do not run them in the daily-use account that
produced this report. No POC code belongs in the Wallume product target.

| ID | Hypothesis and environment | Execution gate | Pass criteria | Fail criteria and disposition |
| --- | --- | --- | --- | --- |
| P0: provider eligibility | A separately signed minimal `com.apple.wallpaper` extension can be registered without Apple-private entitlements. Isolated VM. | Build/sign/install it, then inspect `pluginkit -m -A -D -p com.apple.wallpaper`; no wallpaper-store writes. | A non-Apple provider is registered and discoverable by `WallpaperAgent` without private entitlement. | Signing, registration, or host discovery fails: provider route is closed; do not attempt entitlement spoofing. Expected outcome is failure. |
| P0.5: private-framework provider emulation | A normally signed ExtensionKit shell can be activated by `WallpaperAgent` while dynamically loading `WallpaperExtensionKit` and responding to its private XPC contract. Isolated VM. | Begin from a separate MIT-licensed reference build; capture its code signature, PlugInKit record, extension log, and all `WallpaperAgent` connection attempts. Do not write the Aerial manifest or Store. | The provider appears in System Settings, receives `provideSettingsViewModels`, choice, `acquire`, update, snapshot, and invalidate callbacks; its remote `CAContext` shows a deliberately generated video during six lock-cycle/restart checks; a VM rollback returns the machine to baseline. | No host connection, callback/layout mismatch, gray/black output, failure after restart, or failed rollback: mark this OS build unsupported. Do not add private-framework declarations to Wallume. |
| P1: public-media observation | A verified Live Photo or animated HEIF, manually selected in System Settings, animates at Mac lock/unlock. Disposable user. | User performs selection; application does not write wallpaper state. Record screen only after explicit test authorization. | Motion is visible on first lock, second lock after unlock, and after restart; content remains selected. | Rejected import, first-frame-only, or static content: no public custom-media route. Even a pass is manual-only, not Wallume automation. |
| P2: catalog acceptance | A new catalog category plus a unique HEVC Main10/two-temporal-layer movie is rendered by Apple's Aerial extension. Disposable user/VM snapshot. | Complete baseline and rollback capture below; use a new UUID/category; select only through System Settings; restart only inside the disposable environment. | Category visible; thumbnail and item selectable; six total lock cycles (five lock/unlock plus one post-restart) show continuous custom motion; desktop selections untouched; complete byte-for-byte restoration succeeds; native Apple Aerial still passes a final lock/unlock. | Missing category, picker corruption, black/gray frame, only first frame, loss after restart, user-selection damage, or non-identical restoration. Mark route failed on 25G72. A pass remains unsupported experimental behavior. |
| P3: overwrite negative control | Replacing an Apple Aerial cache slot can meet the same acceptance. | **Do not execute.** Existing failure evidence and destructive surface are sufficient. | No pass condition; this is rejected by design. | Any proposed repetition requires a new safety review because it overwrites Apple-owned cache identity, `Idle` state, poster cache, and process state. |

### P2 baseline, execution, and rollback checklist

The following shell commands are executable only after substituting
`$TARGET_HOME` for the disposable account's home directory and after taking a
VM snapshot or equivalent complete backup. They are documented here, not run.

1. **Capture a manifest and Store baseline before any POC writer runs.**

   ```sh
   export TARGET_HOME='/Users/disposable-wallume-poc'
   export WALLPAPER_ROOT="$TARGET_HOME/Library/Application Support/com.apple.wallpaper"
   mkdir -p "$TARGET_HOME/Desktop/wallume-poc-baseline"
   ditto "$WALLPAPER_ROOT/aerials" "$TARGET_HOME/Desktop/wallume-poc-baseline/aerials"
   cp "$WALLPAPER_ROOT/Store/Index.plist" "$TARGET_HOME/Desktop/wallume-poc-baseline/Index.plist"
   shasum -a 256 "$WALLPAPER_ROOT/aerials/manifest/entries.json" \
     "$WALLPAPER_ROOT/Store/Index.plist" \
     > "$TARGET_HOME/Desktop/wallume-poc-baseline/hashes-before.txt"
   plutil -p "$WALLPAPER_ROOT/Store/Index.plist" \
     > "$TARGET_HOME/Desktop/wallume-poc-baseline/Index-before.txt"
   ```

2. **Prepare only independent media.** The fixture must use a unique UUID and
   a unique category/subcategory; it must not reference, replace, rename, or
   delete an Apple asset. Validate media with:

   ```sh
   ffprobe -v error -show_streams -show_format -of json /path/to/poc.mov
   ```

   Record the encoder evidence that the fixture is HEVC Main10 and contains
   the required two temporal layers. Do not treat a successful encode as proof
   of lock-screen playback.

3. **Install and select.** A separately reviewed POC fixture may write its
   custom manifest/category, custom movie, and thumbnail only in the disposable
   account. Selection must happen through System Settings. Record the category
   appearance and selected item before any lock test.

4. **Run acceptance.** Record exactly: lock #1, unlock #1, lock #2, unlock #2,
   lock #3, unlock #3, lock #4, unlock #4, lock #5, unlock #5, restart, lock
   #6, unlock #6. For each lock, record whether motion starts, remains moving,
   and resumes without black/gray/still output. Test every attached display.

5. **Rollback and prove restoration.** Restore the complete baseline, then
   compare all tracked bytes and rerun the native Aerial final check:

   ```sh
   diff -qr "$TARGET_HOME/Desktop/wallume-poc-baseline/aerials" "$WALLPAPER_ROOT/aerials"
   cmp "$TARGET_HOME/Desktop/wallume-poc-baseline/Index.plist" "$WALLPAPER_ROOT/Store/Index.plist"
   shasum -a 256 "$WALLPAPER_ROOT/aerials/manifest/entries.json" \
     "$WALLPAPER_ROOT/Store/Index.plist"
   ```

   `diff`/`cmp` must be clean after restoration. Any mismatch, including a
   user choice changed by the POC, fails P2.

## Follow-up constraints

- Do not enable existing Tahoe experimental code in the product while P2 is
  pending.
- Do not write Aerial manifests, `Index.plist`, poster caches, or terminate
  `WallpaperAgent`/`WallpaperAerialsExtension` in the daily-use account.
- Do not copy Phonto source or make a GPL-derived implementation part of
  Wallume. A POC must be a standalone fixture with its own legal review.
- Before beginning P2, repeat the first two command blocks on the exact target
  OS build and record the build number in the POC results.

## 4. Newly discovered private-framework provider reference

After the initial revalidation, a separate source audit found
[`kageroumado/phosphene` at `1816e6e`](https://github.com/kageroumado/phosphene/tree/1816e6e1a338d884db10eb0937ca6f9677576571).
Unlike the catalog route, its extension declares only the same
`com.apple.wallpaper` extension point and has no private wallpaper entitlement
in its Xcode project. At runtime it loads the private
`WallpaperExtensionKit.framework`, defines the otherwise unavailable XPC
protocol locally, and renders through a remote `CAContext`. See its
[extension entry point](https://github.com/kageroumado/phosphene/blob/1816e6e1a338d884db10eb0937ca6f9677576571/PhospheneExtension/PhospheneExtension.swift),
[connection setup](https://github.com/kageroumado/phosphene/blob/1816e6e1a338d884db10eb0937ca6f9677576571/PhospheneExtension/WallpaperExtensionConfig.swift),
and [declared private protocol](https://github.com/kageroumado/phosphene/blob/1816e6e1a338d884db10eb0937ca6f9677576571/PhospheneExtension/WallpaperExtension-Bridging-Header.h).

This host compiled that reference unchanged with code signing disabled on
2026-08-14. Its private framework path also successfully `dlopen`ed on 25G72,
and the runtime classes `WallpaperRemoteContextXPC`, `WallpaperSnapshotXPC`,
`WallpaperCreationRequestXPC`, `WallpaperSettingsViewModelsXPC`, and
`WallpaperIDXPC` were present. These are necessary compatibility signals, not
proof of an allowed or stable provider. The reference itself explicitly calls
the framework private and relies on runtime introspection; it reports support
as an empirical claim rather than an Apple contract.

P0.5 therefore supersedes P2 as the first live experiment: if it passes, it
is technically closer to the requested native lock-screen behavior and keeps
Apple's Aerial catalog untouched. It still cannot be shipped through a normal
public-API/App-Store path without a separate distribution, legal, and
maintenance decision.

## 5. P0.5 daily-account result (2026-08-14)

This result is an observation of the separate Phosphene reference build, not
an implementation claim for Wallume.

- The reference app and its `com.apple.wallpaper` ExtensionKit extension were
  built with the local Apple Development identity, registered with PlugInKit,
  and selected through System Settings.
- A locally imported custom MP4 was accepted by the provider. The user
  completed lock, unlock, and a second lock on the daily-use account, and
  confirmed that the custom video continued to animate on the native lock
  screen.
- The system wallpaper Store identifies
  `glass.kagerou.phosphene.extension` as the active provider and references
  the imported video. The extension state file reports active renderer
  contexts for display IDs 1 and 3.

This is a meaningful P0.5 partial pass: a normally signed third-party
provider can supply real dynamic native lock-screen content on macOS 26.6
(25G72), without modifying Apple's Aerial catalog or manually patching the
wallpaper Store.

The desktop half is not accepted yet. At the time of observation the
reference extension reported `full` playback policy after unlock, but the user
did not see the imported video rendered on the main desktop. Its persisted
preferences file was absent, so the reference defaults rule out the explicit
`Only on Lock Screen`, `Pause When Hidden`, and manual-pause controls. Treat
this as a separate desktop composition/acquire defect until a visual desktop
pass is recorded. Reboot persistence, every attached display, recovery after
extension restart, and a Wallume-owned implementation remain untested.
