#!/bin/bash
# Package the SwiftPM executable into a launchable .app bundle.
#
# The local machine has the Swift toolchain (Command Line Tools) but no full
# Xcode, so `swift build` works locally while `xcodebuild` does not. GitHub
# Actions runs the same script on a macOS runner with full Xcode.
#
# Universal binary note: `swift build --arch arm64 --arch x86_64` fails inside
# SwiftPM's xcbuild backend (SWIFT_VERSION '' is unsupported / duplicate output
# file). Building each architecture in its own scratch path and merging the
# results with `lipo -create` works reliably.
#
# Usage: ./scripts/package_app.sh [debug|release]
#   BUILD_UNIVERSAL=1         build arm64 + x86_64 and merge into one binary
#   BUILD_ARCHS="arm64 x86_64" build exactly these architectures
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="CastAudio"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${BUILD_ARCHS:-}" ]]; then
  read -r -a ARCHS <<< "$BUILD_ARCHS"
elif [[ "${BUILD_UNIVERSAL:-0}" == "1" ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=()
fi

BINARIES=()

if [[ ${#ARCHS[@]} -eq 0 ]]; then
  echo "==> swift build -c $CONFIG (host arch)"
  swift build -c "$CONFIG"
  BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
  BINARIES+=("$BIN_DIR/$APP_NAME")
else
  for ARCH in "${ARCHS[@]}"; do
    SCRATCH="$ROOT/.build-$ARCH"
    echo "==> swift build -c $CONFIG --arch $ARCH"
    if ! swift build -c "$CONFIG" --arch "$ARCH" --scratch-path "$SCRATCH"; then
      echo "!! build failed for $ARCH" >&2
      if [[ ${#ARCHS[@]} -eq 1 ]]; then
        exit 1
      fi
      echo "!! skipping $ARCH, continuing with the other architectures" >&2
      continue
    fi
    BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --scratch-path "$SCRATCH" --show-bin-path)"
    BINARIES+=("$BIN_DIR/$APP_NAME")
  done
fi

if [[ ${#BINARIES[@]} -eq 0 ]]; then
  echo "!! no architecture built successfully" >&2
  exit 1
fi

APP_DIR="$ROOT/build/${APP_NAME}.app"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

if [[ ${#BINARIES[@]} -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_DIR/Contents/MacOS/$APP_NAME"
else
  echo "==> lipo -create ${BINARIES[*]}"
  lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

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
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
