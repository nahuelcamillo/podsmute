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

# Firmar con una identidad ESTABLE si existe (ver tools/make-signing-cert.sh).
# Con identidad estable el designated requirement no depende del cdhash, asi que
# el permiso de Accesibilidad sobrevive a los rebuilds. Sin ella, cae a ad-hoc
# (cdhash) y el permiso se pierde en cada recompilacion.
SIGN_ID="${PODSMUTE_SIGN_ID:-PodsMute Self-Signed}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> Codesigning con identidad estable: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP_DIR"
else
    echo "==> [WARN] Identidad '$SIGN_ID' no encontrada; firmando ad-hoc."
    echo "    [WARN] El permiso de Accesibilidad se perdera en cada rebuild."
    echo "    [WARN] Para arreglarlo, una sola vez: ./tools/make-signing-cert.sh"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
fi

echo "==> Done: $APP_DIR"
