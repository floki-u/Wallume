#!/bin/bash
set -e

BUILD_DIR="$(swift build --show-bin-path)"
APP_NAME="Wallume.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SAVER_NAME="Wallume.saver"
SAVER_PATH="$BUILD_DIR/$SAVER_NAME"
SAVER_CONTENTS="$SAVER_PATH/Contents"
SAVER_MACOS="$SAVER_CONTENTS/MacOS"
NATIVE_PROVIDER_DERIVED_DATA="$PWD/.build/NativeWallpaperProvider"
NATIVE_PROVIDER_APP="$NATIVE_PROVIDER_DERIVED_DATA/Build/Products/Debug/WallumeProviderHost.app"
NATIVE_EXTENSION="$NATIVE_PROVIDER_APP/Contents/Extensions/WallumeNativeWallpaperExtension.appex"
DEVELOPMENT_TEAM="${WALLUME_DEVELOPMENT_TEAM:?Set WALLUME_DEVELOPMENT_TEAM to the Apple Development team used for this local build.}"
XCODE_SIGNING_IDENTITY="${WALLUME_XCODE_SIGNING_IDENTITY:-Apple Development}"

if [[ -n "${WALLUME_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$WALLUME_SIGNING_IDENTITY"
else
    SIGNING_IDENTITY=""
    while IFS= read -r candidate; do
        subject="$(security find-certificate -p -c "$candidate" | openssl x509 -noout -subject 2>/dev/null || true)"
        if [[ "$subject" == *"OU=$DEVELOPMENT_TEAM"* ]]; then
            SIGNING_IDENTITY="$candidate"
            break
        fi
    done < <(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)".*/\1/p')
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "No Apple Development signing identity matches team $DEVELOPMENT_TEAM. Set WALLUME_SIGNING_IDENTITY or WALLUME_DEVELOPMENT_TEAM."
    exit 1
fi

echo "Building WallumeApp..."
swift build --product WallumeApp
swift build --product WallumeScreenSaver
swift build --product wallume-provider-cleanup

echo "Building Wallume native wallpaper provider..."
xcodebuild \
    -project NativeWallpaperProvider/WallumeNativeWallpaperProvider.xcodeproj \
    -scheme WallumeProviderHost \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$NATIVE_PROVIDER_DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="$XCODE_SIGNING_IDENTITY" \
    build >/dev/null

if [[ ! -d "$NATIVE_EXTENSION" ]]; then
    echo "Native wallpaper extension was not produced at $NATIVE_EXTENSION"
    exit 1
fi

echo "Creating $APP_NAME bundle..."
rm -rf "$APP_PATH"
mkdir -p "$MACOS" "$RESOURCES"
mkdir -p "$CONTENTS/Extensions"

cp "$BUILD_DIR/WallumeApp" "$MACOS/WallumeApp"
cp "$BUILD_DIR/wallume-provider-cleanup" "$RESOURCES/wallume-provider-cleanup"
cp "$PWD/Assets/Wallume.icns" "$RESOURCES/Wallume.icns"
# SwiftPM keeps target resources in a separate bundle next to the executable.
# Copy it into the app bundle as well; otherwise Bundle.module cannot resolve
# WallumeAppSupport's localized UI resources after distribution.
APP_SUPPORT_RESOURCES="$BUILD_DIR/Wallume_WallumeAppSupport.bundle"
if [[ ! -d "$APP_SUPPORT_RESOURCES" ]]; then
    echo "WallumeAppSupport resource bundle was not produced at $APP_SUPPORT_RESOURCES"
    exit 1
fi
cp -R "$APP_SUPPORT_RESOURCES" "$RESOURCES/"
cp -R "$NATIVE_EXTENSION" "$CONTENTS/Extensions/"
cp "$PWD/uninstall-wallume.sh" "$BUILD_DIR/uninstall-wallume.sh"
chmod +x "$BUILD_DIR/uninstall-wallume.sh"
# Xcode registers its temporary build product while compiling. The shippable extension is the
# one embedded in Wallume.app, so keep the temporary path out of System Settings.
pluginkit -r "$NATIVE_EXTENSION" >/dev/null 2>&1 || true

cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WallumeApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.wallume.app</string>
    <key>CFBundleName</key>
    <string>Wallume</string>
    <key>CFBundleIconFile</key>
    <string>Wallume</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLSchemes</key>
            <array><string>wallume</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH" >/dev/null
codesign --verify --deep --strict "$APP_PATH"
# Register the signed, embedded copy. System Settings must never point to Xcode's DerivedData
# product, which disappears on the next clean build.
pluginkit -a "$CONTENTS/Extensions/WallumeNativeWallpaperExtension.appex" >/dev/null

echo "Creating $SAVER_NAME bundle..."
rm -rf "$SAVER_PATH"
mkdir -p "$SAVER_MACOS"
cp "$BUILD_DIR/libWallumeScreenSaver.dylib" "$SAVER_MACOS/libWallumeScreenSaver.dylib"

cat > "$SAVER_CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>libWallumeScreenSaver.dylib</string>
    <key>CFBundleIdentifier</key>
    <string>com.wallume.screensaver</string>
    <key>CFBundleName</key>
    <string>Wallume</string>
    <key>CFBundlePackageType</key>
    <string>savr</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSPrincipalClass</key>
    <string>WallumeScreenSaverView</string>
</dict>
</plist>
EOF
codesign --force --sign - "$SAVER_PATH" >/dev/null

echo "Done! Run: open $APP_PATH"
echo "Screen saver: $SAVER_PATH"
