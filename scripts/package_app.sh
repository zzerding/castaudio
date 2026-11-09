#!/bin/bash
# Package the SwiftPM executable into a launchable .app bundle.
#
# The local machine has the Swift toolchain (Command Line Tools) but no full
# Xcode, so `swift build` works locally while `xcodebuild` does not. GitHub
# Actions runs the same script on a macOS runner with full Xcode.
#
# Usage: ./scripts/package_app.sh [debug|release]
#   BUILD_UNIVERSAL=1  build arm64 + x86_64 in one binary
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="CastAudio"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_FLAGS=(-c "$CONFIG")
if [[ "${BUILD_UNIVERSAL:-0}" == "1" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_FLAGS[*]}"
swift build "${BUILD_FLAGS[@]}"

BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
APP_DIR="$ROOT/build/${APP_NAME}.app"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> zipping"
cd "$ROOT/build"
rm -f "${APP_NAME}.zip"
zip -qry "${APP_NAME}.zip" "${APP_NAME}.app"

echo "done: $APP_DIR"
echo "      $ROOT/build/${APP_NAME}.zip"
