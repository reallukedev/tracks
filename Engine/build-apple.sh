#!/bin/bash
# Builds the Rust engine for Apple platforms and packages it for Xcode:
#
#   Engine/apple/TracksEngine/TracksEngineFFI.xcframework   static libraries + C header
#   Engine/apple/TracksEngine/Sources/TracksEngine/          generated Swift bindings
#
# TracksCore depends on that Swift package. Run this after changing anything in Engine/, and
# once after cloning. It's incremental: an unchanged engine rebuilds in a second or two.
#
#   Engine/build-apple.sh            release build (what the apps ship, and what Debug uses,
#                                    since SQLite and the stats are slow unoptimized)
#   Engine/build-apple.sh --debug    unoptimized, for stepping through Rust in LLDB
#
# Set CARGO_TARGET_DIR to build somewhere other than Engine/target (a bigger disk, say).
set -euo pipefail

cd "$(dirname "$0")"
ENGINE="$PWD"
PROFILE=release
CARGO_PROFILE=(--release)
if [ "${1:-}" = "--debug" ]; then
  PROFILE=debug
  CARGO_PROFILE=()
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ENGINE/target}"
# Match the apps' deployment targets, so the linker doesn't warn about newer objects.
export IPHONEOS_DEPLOYMENT_TARGET=27.0
export MACOSX_DEPLOYMENT_TARGET=27.0

if ! command -v cargo >/dev/null; then
  echo "✗ Rust isn't installed. Install it from https://rustup.rs, then run this again." >&2
  exit 1
fi

# macOS 27 runs on Apple silicon only, so every slice is arm64.
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
rustup target add "${TARGETS[@]}" >/dev/null

for target in "${TARGETS[@]}"; do
  cargo build -p tracks-ffi --lib --target "$target" "${CARGO_PROFILE[@]}" --locked
done

PACKAGE="$ENGINE/apple/TracksEngine"
SOURCES="$PACKAGE/Sources/TracksEngine"
STAGING="$CARGO_TARGET_DIR/apple-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/headers" "$SOURCES"

# Bindings come from the library's own metadata, so they always match the binary.
cargo run -q -p uniffi-bindgen --release --locked -- generate \
  --library "$CARGO_TARGET_DIR/aarch64-apple-darwin/$PROFILE/libtracks_engine.a" \
  --language swift --out-dir "$STAGING/generated" >/dev/null

mv "$STAGING/generated/"*.swift "$SOURCES/TracksEngine.swift"
cp "$STAGING/generated/"*.h "$STAGING/headers/"
# Xcode looks for exactly this name inside an XCFramework's headers.
cp "$STAGING/generated/"*.modulemap "$STAGING/headers/module.modulemap"

XCFRAMEWORK="$PACKAGE/TracksEngineFFI.xcframework"
rm -rf "$XCFRAMEWORK"
args=()
for target in "${TARGETS[@]}"; do
  args+=(-library "$CARGO_TARGET_DIR/$target/$PROFILE/libtracks_engine.a" -headers "$STAGING/headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$XCFRAMEWORK" >/dev/null

echo "✓ TracksEngine $PROFILE built for ${TARGETS[*]}"
