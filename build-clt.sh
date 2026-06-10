#!/bin/bash
# Build PodsMute with Command Line Tools only (no Xcode / xcodegen needed).
# Compiles with swiftc and assembles the .app bundle manually.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PodsMute"
BUNDLE_ID="com.podsmute.app"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
TARGET="arm64-apple-macos14.0"

echo "==> Compiling with swiftc ($TARGET)..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc -O -parse-as-library \
    -target "$TARGET" \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    PodsMute/App/*.swift \
    PodsMute/UI/*.swift \
    PodsMute/Services/*.swift

echo "==> Assembling bundle..."
# Resolve the xcodebuild-style $(VAR) placeholders in Info.plist
sed -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
    -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g" \
    PodsMute/App/Info.plist > "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist" > /dev/null

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cp AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Codesigning (ad-hoc)..."
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"

echo "==> Done: $APP_DIR"
