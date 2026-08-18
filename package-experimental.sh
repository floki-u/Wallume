#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename "$0") <version>" >&2
    exit 64
fi

VERSION="$1"
BUILD_DIRECTORY="$(swift build --show-bin-path)"
APP_PATH="$BUILD_DIRECTORY/Wallume.app"
UNINSTALLER="$BUILD_DIRECTORY/uninstall-wallume.sh"
ARTIFACTS_DIRECTORY="$PWD/.artifacts"
PAYLOAD_NAME="Wallume-${VERSION}"
OUTPUT_PATH="$ARTIFACTS_DIRECTORY/${PAYLOAD_NAME}.zip"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/wallume-package.XXXXXX")"
PAYLOAD_DIRECTORY="$STAGING_DIRECTORY/$PAYLOAD_NAME"

cleanup() {
    rm -rf "$STAGING_DIRECTORY"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" || ! -x "$UNINSTALLER" ]]; then
    echo "Build Wallume first with ./build-app.sh" >&2
    exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    echo "Wallume.app is version $BUILT_VERSION, but this package requests $VERSION." >&2
    echo "Rebuild with WALLUME_VERSION=$VERSION ./build-app.sh" >&2
    exit 1
fi

mkdir -p "$PAYLOAD_DIRECTORY" "$ARTIFACTS_DIRECTORY"
ditto "$APP_PATH" "$PAYLOAD_DIRECTORY/Wallume.app"
cp "$UNINSTALLER" "$PAYLOAD_DIRECTORY/uninstall-wallume.sh"
chmod +x "$PAYLOAD_DIRECTORY/uninstall-wallume.sh"
ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD_DIRECTORY" "$OUTPUT_PATH"

shasum -a 256 "$OUTPUT_PATH"
echo "Created: $OUTPUT_PATH"
