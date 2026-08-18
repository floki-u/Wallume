#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: uninstall-wallume.sh [--purge-data] [path-to-Wallume.app]

不带 --purge-data 时，脚本只停用 Wallume：注销原生墙纸扩展并清理提供者副本，
保留已导入的素材库。

带 --purge-data 时，确认后会将 Wallume 的应用支持目录、缓存和偏好设置移到废纸篓。
从其他位置导入的原始视频永远不会删除。
EOF
}

PURGE_DATA=0
if [[ "${1:-}" == "--purge-data" ]]; then
    PURGE_DATA=1
    shift
fi

if [[ $# -gt 1 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        exit 0
    fi
    exit 64
fi

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_APP="$SCRIPT_DIRECTORY/Wallume.app"
if [[ ! -d "$DEFAULT_APP" && -d "/Applications/Wallume.app" ]]; then
    DEFAULT_APP="/Applications/Wallume.app"
fi
APP_PATH="${1:-$DEFAULT_APP}"
CLEANUP_TOOL="$APP_PATH/Contents/Resources/wallume-provider-cleanup"
EXTENSION_PATH="$APP_PATH/Contents/Extensions/WallumeNativeWallpaperExtension.appex"
APPLICATION_SUPPORT="$HOME/Library/Application Support/Wallume"
CACHE_DIRECTORY="$HOME/Library/Caches/app.wallume.Wallume"
PREFERENCES_FILE="$HOME/Library/Preferences/com.wallume.app.plist"

if [[ ! -x "$CLEANUP_TOOL" ]]; then
    echo "未在此处找到 Wallume 清理工具：$APP_PATH" >&2
    echo "请在将 Wallume.app 移到废纸篓前运行此脚本。" >&2
    exit 1
fi

echo "Wallume 即将退出，然后移除原生墙纸扩展。"
osascript -e 'tell application id "com.wallume.app" to quit' >/dev/null 2>&1 || true
sleep 1

echo
echo "继续前，请在“系统设置 → 墙纸”中选择任意非 Wallume 墙纸。"
echo "这可避免 macOS 保留对 Wallume 提供者文件的引用。"
read -r -p "已切换系统墙纸，继续吗？[y/N] " ANSWER
if [[ "$ANSWER" != "y" && "$ANSWER" != "Y" ]]; then
    echo "已取消，未移除任何内容。"
    exit 0
fi

"$CLEANUP_TOOL" confirm-system-reset
"$CLEANUP_TOOL" cleanup

if [[ -d "$EXTENSION_PATH" ]]; then
    pluginkit -r "$EXTENSION_PATH" >/dev/null 2>&1 || true
fi

if [[ $PURGE_DATA -eq 1 ]]; then
    echo
    echo "以下仅属于 Wallume 的位置将被移到废纸篓："
    printf '  %s\n' "$APPLICATION_SUPPORT" "$CACHE_DIRECTORY" "$PREFERENCES_FILE"
    echo "这些位置以外导入的原始视频不会受影响。"
    read -r -p "输入 DELETE 以移入废纸篓：" CONFIRMATION
    if [[ "$CONFIRMATION" != "DELETE" ]]; then
        echo "已移除提供者；本地 Wallume 数据已保留。"
        exit 0
    fi

    for target in "$APPLICATION_SUPPORT" "$CACHE_DIRECTORY" "$PREFERENCES_FILE"; do
        if [[ -e "$target" ]]; then
            osascript - "$target" <<'APPLESCRIPT'
on run argv
    tell application "Finder"
        delete POSIX file (item 1 of argv)
    end tell
end run
APPLESCRIPT
        fi
    done
    echo "Wallume 数据已移到废纸篓。确认不再需要恢复后，可自行清空废纸篓。"
else
    echo "Wallume 已停用，已导入素材库和本地设置仍被保留。"
    echo "如也要清除它们，请再次运行此脚本并加 --purge-data。"
fi

echo "现在可将 Wallume.app 拖到废纸篓。"
