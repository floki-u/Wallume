<p align="center">
  <img src="docs/images/wallume-icon.png" width="80" alt="Wallume icon" />
</p>

<h1 align="center">Wallume</h1>

<p align="center"><strong>Live wallpapers and lock-screen scenes for macOS, using your local images and videos.</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-222222?style=flat-square" alt="macOS 14 or later" />
  <img src="https://img.shields.io/badge/Download-Apple%20Silicon-222222?style=flat-square" alt="Current download supports Apple Silicon" />
  <img src="https://img.shields.io/badge/Status-Experimental-EF6E54?style=flat-square" alt="Experimental release" />
</p>

<p align="center">
  <a href="https://github.com/floki-u/Wallume/releases">Download</a> ·
  <a href="https://floki-u.github.io/apps/wallume/">Website</a> ·
  <a href="#download-and-install">Install</a> ·
  <a href="#use-wallume">Use</a> ·
  <a href="#disable-and-uninstall">Uninstall</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

Wallume is a macOS wallpaper app. Import your own images or videos and assign a different scene to each built-in or external display. On macOS 26 and later, including macOS 27, it can also prepare videos for experimental native desktop and lock-screen wallpapers.

Media stays on your Mac; Wallume does not upload your images or videos. You make the final native wallpaper selection in **System Settings → Wallpaper**. The app supports Simplified Chinese and English: switch in **Settings → App language**. Chinese is the default.

> **This is an experimental release.** Multi-display behavior, sleep/wake recovery and lock-screen transitions are still being validated. Results may vary with macOS versions and video codecs. Keep your original media files.

![Wallume: local media library and wallpapers on multiple displays](docs/images/wallume-overview.jpg)

*This overview and the GIF below are simulated demonstrations based on the project interface. The actual interface and playback behavior may differ.*

<details>
<summary>View an application screenshot</summary>

<img width="956" height="570" alt="Wallume application screenshot with Chinese interface labels" src="https://github.com/user-attachments/assets/ce17344a-f324-46c9-95c4-55bc6c12fea7" />

</details>

## Features and compatibility

| Feature | What it does |
| --- | --- |
| Local media library | Import PNG, JPG/JPEG, HEIC, MOV and MP4 files, or import a media folder. |
| Per-display scenes | Assign a separate image or video to each built-in or external display. |
| Image and video wallpapers | Display images directly from the original resource; play videos while Wallume is running. |
| Native animated lock screen | On macOS 26 and later, prepare a system-specific video copy, then select it yourself in System Settings. |
| Local data management | Clean preview caches, diagnostic records and native wallpaper copies separately. |
| Chinese and English interface | Switch languages in Settings; the change takes effect immediately. |

| Environment | Support |
| --- | --- |
| macOS 14 / 15 | Local media import, per-display assignment and desktop wallpapers. The native wallpaper provider is unavailable. |
| macOS 26 and later, including macOS 27 | The features above, plus experimental native desktop and lock-screen video wallpapers. Versions 26 and later share the same compatibility logic. |
| Apple Silicon | The current 1.3.0 download is an `arm64` build for M-series Macs. |
| Intel Mac | The current download does not include an Intel-native build. |

Native animated wallpapers use private system interfaces. The code targets macOS 26 and later; **macOS 27 has not yet been validated on a physical Mac**. Actual behavior depends on the interfaces and runtime environment in each system version.

## Download and install

### 1. Download and extract

Open [Releases](https://github.com/floki-u/Wallume/releases) and download `Wallume-<version>.zip` from the latest **Pre-release**. Choose the application archive under **Assets**; `Source code (zip)` contains the source rather than the application.

Double-click the ZIP first. It extracts to a `Wallume-<version>` folder. If Archive Utility stays stuck on extraction, use the fallback below.

<details>
<summary>Extraction is stuck: use Terminal instead</summary>

Cancel the current extraction. If it will not cancel, quit Archive Utility in Activity Monitor. Move the partially extracted folder to the Trash, then open Terminal and run:

```bash
cd ~/Downloads
ditto -x -k "Wallume-1.3.0.zip" .
```

This example uses 1.3.0; replace the ZIP filename for another version. The archive already contains its version folder, so you do not need to create one. Terminal extraction is a fallback; identifying why double-click extraction stalled requires checking the system state at the time.

</details>

### 2. Install the application

Open the extracted folder and **drag only the Wallume application into Applications**. Its full filename is `Wallume.app`; Finder usually hides the `.app` extension.

The installed application should be at `/Applications/Wallume.app`. Do not drag the entire `Wallume-<version>` folder into Applications, or the default paths in the instructions below will not match.

| Extracted file | Where to keep it |
| --- | --- |
| `Wallume.app` | Drag into Applications. |
| `uninstall-wallume.sh` | Keep in the downloaded version folder, or move to a location you will retain. |
| `wallume-provider-cleanup` | Preferably keep beside the uninstall script; it cleans native wallpaper resources during uninstallation. |

The application and uninstall script can be stored separately. Since 1.3.0, the script first looks for the standalone cleanup tool beside it, then falls back to the tool inside the specified application. Moving the application on the same disk removes it from the original folder; this is expected.

### 3. Open for the first time

Double-click Wallume in Applications. The experimental package uses a development signature and has not been notarized by Apple. If macOS blocks opening it, first confirm that the archive came from this project's Releases, then run:

```bash
xattr -dr com.apple.quarantine /Applications/Wallume.app
open /Applications/Wallume.app
```

## Use Wallume

![Simulated Wallume workflow: browse media, choose a scene and assign displays](docs/images/wallume-demo.gif)

*Simulated workflow; the demonstration media is illustrative.*

[View the high-resolution demo (MP4)](docs/images/wallume-demo.mp4)

The steps below use the English interface labels. Select **English** in **Settings → App language** if needed.

### Choose a desktop scene

1. Open **Library** and import local images, videos or a media folder.
2. Open **Displays** and choose a scene for each screen.
3. Check the desktop result. Video wallpapers require Wallume to keep running. After reconnecting displays or waking your Mac, check that each scene has resumed correctly.

### Choose an animated lock-screen scene · macOS 26 and later

1. In **Displays**, assign a video to the main display first.
2. Open **Lock screen sync**, select **Use for lock screen** and wait for media preparation to finish.
3. In **System Settings → Wallpaper**, select the prepared scene in the **Wallume** group.
4. Return to Wallume and select **I selected it, check again**. The app shows **Lock screen enabled** only after it confirms the system's actual selection.

“Prepared” means that the media copy exists; **you still need to select it in System Settings**. To use a static image as the system wallpaper or lock screen, choose that image manually in the system wallpaper settings.

### Switch or clean lock-screen media

1. Choose a non-Wallume wallpaper in **System Settings → Wallpaper** first.
2. Return to **Lock screen sync → Manage lock-screen resources** and select **Check system status**.
3. Once cleanup is allowed, clean the lock-screen copy. You can then prepare new media or remove old media.

## Disable and uninstall

**Switch the system wallpaper first, run the script next, and remove the application last.** `Wallume.app` must still exist while the uninstall script runs.

The examples assume that the application is at `/Applications/Wallume.app` and the uninstall files are in `~/Downloads/Wallume-1.3.0/`. Replace these paths for another version or location. Keep the quotes around paths containing spaces.

### Disable native wallpapers and clean their copies, keeping the library

Choose a non-Wallume wallpaper in **System Settings → Wallpaper**, then run:

```bash
bash "$HOME/Downloads/Wallume-1.3.0/uninstall-wallume.sh" "/Applications/Wallume.app"
```

After your confirmation, the script quits the application, unregisters the native wallpaper extension and cleans provider copies. Your imported media library, caches and settings remain available for later use.

### Uninstall completely

Choose a non-Wallume wallpaper in **System Settings → Wallpaper**, then run:

```bash
bash "$HOME/Downloads/Wallume-1.3.0/uninstall-wallume.sh" --purge-data "/Applications/Wallume.app"
```

1. Confirm when prompted that the system is using a non-Wallume wallpaper.
2. Enter `DELETE` to move Wallume's media library, caches, diagnostics and preferences to the Trash, and clean provider copies and preferences.
3. Wait for the script to finish, then move Wallume from Applications to the Trash.

Original images and videos stored outside Wallume are not deleted. macOS may retain empty sandbox container metadata without user data; these are system-managed records.

## FAQ

<details>
<summary>I moved the entire version folder into Applications. What should I do?</summary>

Open that folder and move the Wallume application into the root of Applications, so it is at `/Applications/Wallume.app`. The two uninstall files can remain in their existing folder. Use the script's actual path when uninstalling.

</details>

<details>
<summary>I deleted the download folder or uninstall script. Can I still uninstall?</summary>

Download and extract the complete package again, keeping its uninstall script and matching cleanup tool. Run the newly downloaded script with the actual path of your installed application. Run the script before removing the application.

</details>

<details>
<summary>I changed the system wallpaper. Why is cleanup still unavailable?</summary>

macOS may delay releasing wallpaper resources after locking, changing settings pages or waking. Wait a few seconds and select **Check system status** again. Proceed once the app confirms that cleanup is allowed.

</details>

<details>
<summary>Can I just drag the application to the Trash?</summary>

Dragging it to the Trash does not run Wallume's cleanup logic and may leave the native wallpaper extension and provider resources behind. Follow the uninstall sequence above.

</details>

<details>
<summary>How do I report import, display or lock-screen problems?</summary>

Open an [issue](https://github.com/floki-u/Wallume/issues) with your macOS version, chip type, display count, media format and reproduction steps. Mention any display reconnection, sleep/wake or lock-screen involvement. You can export an anonymous diagnostic summary from **Settings → Local data**. Do not attach private images or videos.

</details>

## Project information and usage terms

For normal use, download a release package. To inspect the implementation or build locally, see [Package.swift](Package.swift) and the [build script](build-app.sh). Building the application requires Xcode and a matching Apple Development signing identity; the script accepts your development team ID through `WALLUME_DEVELOPMENT_TEAM`.

Wallume **is not open-source software**. It is permitted only for personal learning, evaluation and non-commercial testing. Without the copyright holder's written permission, you may not use the project's source code, application, icons or derivative versions commercially, sell or redistribute them, or include them in another product.

See the [third-party notice](NativeWallpaperProvider/NOTICE.md) for third-party sources and their licenses.
