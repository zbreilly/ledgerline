#!/bin/bash
# Builds a Ledgerline.app meant for other people's Macs and zips it:
#   dist/Ledgerline-<version>-macos-<universal|arm64|x86_64>.zip  (+ .sha256)
#
# Differences from scripts/build-macos.sh (which builds for this Mac and installs it):
#   - builds for Apple Silicon and Intel and joins them into one universal app
#   - uses the rustup toolchain, whose standard library runs on macOS 14 and later
#   - keeps this machine's folder names out of the binary, and refuses to finish if any remain
#   - never installs anything
#
# Usage: scripts/package-macos.sh
#   LEDGERLINE_ARCHS="arm64"   build one architecture only (default: "arm64 x86_64")
#
# Needs both Rust targets:  rustup target add aarch64-apple-darwin x86_64-apple-darwin
# The app is signed ad hoc, not notarized: see "Download" in README.md for how to open it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHS="${LEDGERLINE_ARCHS:-arm64 x86_64}"
MIN_OS=14.0
export MACOSX_DEPLOYMENT_TARGET=$MIN_OS
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' apple/Resources/Info.plist)"
GEN="$ROOT/apple/Generated"
WORK="$ROOT/build.noindex/package"
APP="$WORK/Ledgerline.app"
OUT="$ROOT/dist"
# A separate Cargo folder, so the path-hiding flags below don't force scripts/build-macos.sh to rebuild.
export CARGO_TARGET_DIR="$ROOT/target/package"

# Homebrew's Rust only supports the macOS it was built on. Use rustup's toolchain when there is one.
# Both tools are named by full path: cargo otherwise runs whichever rustc comes first on PATH.
CARGO=(cargo)
if command -v rustup >/dev/null 2>&1 && TOOLCHAIN_CARGO="$(rustup which --toolchain stable cargo 2>/dev/null)"; then
  CARGO=("$TOOLCHAIN_CARGO")
  RUSTC="$(rustup which --toolchain stable rustc)"
  export RUSTC
fi

# Compilers write source paths into binaries (panic messages, assertions). Replace this machine's
# folders with neutral names. The separator is the unit-separator byte so paths may contain spaces.
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$HOME=/home"$'\x1f'"--remap-path-prefix=$ROOT=/ledgerline"
SWIFT_MAPS=(-file-prefix-map "$HOME=/home" -file-prefix-map "$ROOT=/ledgerline")

triple() { if [[ "$1" == arm64 ]]; then echo aarch64-apple-darwin; else echo "$1-apple-darwin"; fi; }

rm -rf "$WORK"
mkdir -p "$WORK" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT"

FIRST=""
for arch in $ARCHS; do
  [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo "Unknown architecture: $arch" >&2; exit 1; }
  echo "==> Building Rust core ($arch)"
  "${CARGO[@]}" build --release -p ledgerline_core --target "$(triple "$arch")"
  [[ -n "$FIRST" ]] || FIRST="$arch"
done

echo "==> Generating Swift bindings"
"${CARGO[@]}" run -q --release --features bindgen --bin uniffi-bindgen -- \
  generate --library "$CARGO_TARGET_DIR/$(triple "$FIRST")/release/libledgerline_core.dylib" --language swift --out-dir "$GEN"
# swiftc finds C modules through a file named module.modulemap.
cp "$GEN/ledgerline_coreFFI.modulemap" "$GEN/module.modulemap"

BINARIES=()
for arch in $ARCHS; do
  echo "==> Compiling SwiftUI app ($arch)"
  LOG="$WORK/swiftc-$arch.log"
  if ! swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos$MIN_OS" \
      -module-name Ledgerline "${SWIFT_MAPS[@]}" \
      -I "$GEN" \
      "$GEN/ledgerline_core.swift" apple/Ledgerline/*.swift \
      "$CARGO_TARGET_DIR/$(triple "$arch")/release/libledgerline_core.a" \
      -framework SwiftUI -framework Charts -framework AppKit -framework UniformTypeIdentifiers \
      -o "$WORK/Ledgerline-$arch" 2> "$LOG"; then
    cat "$LOG" >&2
    exit 1
  fi
  if grep -q "was built for newer 'macOS' version" "$LOG"; then
    echo "The Rust standard library in use only supports a newer macOS than $MIN_OS, so this app" >&2
    echo "would not run on older Macs. Build with a rustup toolchain (https://rustup.rs)." >&2
    exit 1
  fi
  grep -v '^$' "$LOG" >&2 || true
  BINARIES+=("$WORK/Ledgerline-$arch")
done

BIN="$APP/Contents/MacOS/Ledgerline"
if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create -output "$BIN" "${BINARIES[@]}"
  LABEL=universal
else
  cp "${BINARIES[0]}" "$BIN"
  LABEL="$FIRST"
fi
# Drop debugging and local symbols: smaller, and they name object files on the build machine.
strip -S -x "$BIN"

cp apple/Resources/Info.plist "$APP/Contents/Info.plist"
cp apple/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> Checking the app"
for arch in $ARCHS; do
  MINOS="$(vtool -arch "$arch" -show-build "$BIN" | awk '/minos/ {print $2; exit}')"
  [[ "$MINOS" == "$MIN_OS" ]] || { echo "The $arch build targets macOS $MINOS, expected $MIN_OS." >&2; exit 1; }
done
# Nothing from this machine's home folder may be left in the app.
if LC_ALL=C grep -r -a -q -F "$HOME" "$APP"; then
  echo "The app still contains this machine's home folder path ($HOME). Not packaging it." >&2
  LC_ALL=C grep -r -a -o -F "$HOME" "$APP" | sort | uniq -c | head -5 >&2
  exit 1
fi
echo "Architectures: $(lipo -archs "$BIN"); minimum macOS $MIN_OS; no local paths."

NAME="Ledgerline-$VERSION-macos-$LABEL"
rm -f "$OUT/$NAME.zip" "$OUT/$NAME.zip.sha256"
# No resource forks or extended attributes: the zip holds the app's files and nothing else.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT/$NAME.zip"
(cd "$OUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "Packaged: $OUT/$NAME.zip"
cat "$OUT/$NAME.zip.sha256"
