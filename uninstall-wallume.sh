#!/bin/bash
set -euo pipefail

usage() {
    echo "usage: $(basename "$0") [--remove-app] [path-to-Wallume.app]"
}

REMOVE_APP=0
if [[ "${1:-}" == "--remove-app" ]]; then
    REMOVE_APP=1
    shift
fi

if [[ $# -gt 1 ]]; then
    usage
    exit 64
fi

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:-$SCRIPT_DIRECTORY/Wallume.app}"
CLEANUP_TOOL="$APP_PATH/Contents/Resources/wallume-provider-cleanup"
EXTENSION_PATH="$APP_PATH/Contents/Extensions/WallumeNativeWallpaperExtension.appex"

if [[ ! -x "$CLEANUP_TOOL" ]]; then
    echo "Wallume cleanup tool was not found in: $APP_PATH" >&2
    exit 1
fi

echo "Before continuing, choose any non-Wallume wallpaper in System Settings > Wallpaper."
echo "This prevents macOS from retaining a reference to Wallume's provider files."
read -r -p "The system wallpaper has been changed. Continue? [y/N] " ANSWER
if [[ "$ANSWER" != "y" && "$ANSWER" != "Y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

"$CLEANUP_TOOL" confirm-system-reset
"$CLEANUP_TOOL" cleanup

if [[ -d "$EXTENSION_PATH" ]]; then
    pluginkit -r "$EXTENSION_PATH" >/dev/null 2>&1 || true
fi

if [[ $REMOVE_APP -eq 1 ]]; then
    rm -rf "$APP_PATH"
    echo "Wallume was removed."
else
    echo "Wallume provider files were removed and the extension was unregistered."
    echo "To remove the application too, run this script again with --remove-app."
fi
