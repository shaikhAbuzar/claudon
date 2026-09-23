#!/usr/bin/env bash
# Builds build/Claudon.app. Needs only the Swift toolchain (Xcode or the Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Claudon"
BUNDLE_ID="app.claudon.Claudon"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ClaudonCore/TokenCounts.swift)"
APP="build/$APP_NAME.app"

swift build -c release --product "$APP_NAME"
swift build -c release --product "${APP_NAME}Widget"
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# The app draws its own icon; turn it into an .icns file.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The widget extension. WidgetKit only loads sandboxed widgets, so it gets the sandbox plus
# read access to the one folder where the app writes widget.json.
APPEX="$APP/Contents/PlugIns/${APP_NAME}Widget.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN_DIR/${APP_NAME}Widget" "$APPEX/Contents/MacOS/${APP_NAME}Widget"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}Widget</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID.Widget</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}Widget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
ENTITLEMENTS="build/${APP_NAME}Widget.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
    <array><string>/Library/Application Support/$APP_NAME/</string></array>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough to run locally, post notifications, add a login item and
# show the widget. Sign the extension first, then the app around it.
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($VERSION)"
