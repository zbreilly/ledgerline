#!/bin/bash
# Builds build.noindex/Ledgerline.app (".noindex" keeps Spotlight from listing a second copy): Rust core (static lib) + UniFFI Swift bindings + SwiftUI front end,
# then installs release builds into /Applications.
# Usage: scripts/build-macos.sh [debug]
#   LEDGERLINE_NO_INSTALL=1      build only, don't install
#   LEDGERLINE_INSTALL_DIR=path  install somewhere other than /Applications
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE=release
CARGO_FLAGS=(--release)
SWIFT_OPT=-O
if [[ "${1:-}" == "debug" ]]; then PROFILE=debug; CARGO_FLAGS=(); SWIFT_OPT=-Onone; fi

TARGET=arm64-apple-macos14.0
export MACOSX_DEPLOYMENT_TARGET=14.0
GEN="$ROOT/apple/Generated"
APP="$ROOT/build.noindex/Ledgerline.app"

# Keep this Mac's folder names (and so the account name) out of the binary: panic messages
# and debug info embed full source paths. The encoded form is used because ROOT may contain spaces.
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$HOME=~"$'\x1f'"--remap-path-prefix=$ROOT=."

echo "==> Building Rust core ($PROFILE)"
cargo build -p ledgerline_core "${CARGO_FLAGS[@]}"

echo "==> Generating Swift bindings"
cargo run -q --release --features bindgen --bin uniffi-bindgen -- \
  generate --library "target/$PROFILE/libledgerline_core.dylib" --language swift --out-dir "$GEN"
# swiftc finds C modules through a file named module.modulemap.
cp "$GEN/ledgerline_coreFFI.modulemap" "$GEN/module.modulemap"

echo "==> Compiling SwiftUI app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc $SWIFT_OPT -parse-as-library -swift-version 5 -target "$TARGET" \
  -module-name Ledgerline \
  -I "$GEN" \
  "$GEN/ledgerline_core.swift" apple/Ledgerline/*.swift \
  "target/$PROFILE/libledgerline_core.a" \
  -framework SwiftUI -framework Charts -framework AppKit -framework UniformTypeIdentifiers \
  -o "$APP/Contents/MacOS/Ledgerline"

cp apple/Resources/Info.plist "$APP/Contents/Info.plist"
cp apple/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"

# Install release builds into Applications so the app you open is always current.
# Skip with LEDGERLINE_NO_INSTALL=1; choose another folder with LEDGERLINE_INSTALL_DIR.
INSTALL_DIR="${LEDGERLINE_INSTALL_DIR:-/Applications}"
if [[ "$PROFILE" == release && "${LEDGERLINE_NO_INSTALL:-}" != 1 ]]; then
  DEST="$INSTALL_DIR/Ledgerline.app"
  # Copy beside it, then swap, so a running copy keeps working until it's reopened.
  rm -rf "$DEST.new"
  ditto "$APP" "$DEST.new"
  rm -rf "$DEST"
  mv "$DEST.new" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "Installed: $DEST"
  if pgrep -f "$DEST/Contents/MacOS/Ledgerline" >/dev/null; then
    echo "Ledgerline is open; quit and reopen it to use the new build."
  fi
fi
