#!/bin/bash
#
# Build whisper.xcframework for iOS from whisper.cpp source.
#
# Usage:
#   ./scripts/setup-whisper.sh              # Build for all platforms (device + simulator)
#   ./scripts/setup-whisper.sh --simulator  # Build for iOS Simulator only (CI mode)
#
# The resulting xcframework is placed in Frameworks/whisper.xcframework
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORK_DIR="$PROJECT_ROOT/Frameworks"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

WHISPER_REPO="https://github.com/ggerganov/whisper.cpp.git"
WHISPER_TAG="v1.7.3"
SIMULATOR_ONLY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --simulator) SIMULATOR_ONLY=true ;;
    esac
done

# Skip if already built
if [ -d "$FRAMEWORK_DIR/whisper.xcframework" ]; then
    echo "whisper.xcframework already exists at $FRAMEWORK_DIR/whisper.xcframework"
    echo "Delete it first if you want to rebuild."
    exit 0
fi

echo "==> Cloning whisper.cpp ($WHISPER_TAG)..."
git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$TEMP_DIR/whisper.cpp"

cd "$TEMP_DIR/whisper.cpp"

NCPU=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# ---------- Collect all public headers ----------
# whisper.h includes ggml.h which may include other ggml headers.
# We must ship every header that whisper.h transitively references.
echo "==> Collecting public headers..."
mkdir -p "$TEMP_DIR/headers"

# Copy whisper public header
cp include/whisper.h "$TEMP_DIR/headers/"

# Copy all ggml public headers (whisper.h -> ggml.h -> ggml-*.h)
find ggml/include -name "*.h" -exec cp {} "$TEMP_DIR/headers/" \;

# Create module map that exposes whisper and treats ggml headers as part of the module
cat > "$TEMP_DIR/headers/module.modulemap" << 'MODULEMAP'
module whisper {
    umbrella "."
    export *
}
MODULEMAP

# ---------- iOS Simulator (arm64 + x86_64) ----------
echo "==> Building for iOS Simulator..."
cmake -B build-sim \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DGGML_METAL=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF

cmake --build build-sim --config Release -j"$NCPU"

# Merge all static libraries into one fat library for the simulator
echo "==> Creating merged static library (simulator)..."
mkdir -p "$TEMP_DIR/lib-sim"
SIM_LIBS=$(find build-sim -name "*.a" -not -path "*/CMakeFiles/*" 2>/dev/null)
libtool -static -o "$TEMP_DIR/lib-sim/libwhisper.a" $SIM_LIBS

XCFRAMEWORK_ARGS="-library $TEMP_DIR/lib-sim/libwhisper.a -headers $TEMP_DIR/headers"

# ---------- iOS Device (arm64) ----------
if [ "$SIMULATOR_ONLY" = false ]; then
    echo "==> Building for iOS Device..."
    cmake -B build-device \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DGGML_METAL=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF

    cmake --build build-device --config Release -j"$NCPU"

    echo "==> Creating merged static library (device)..."
    mkdir -p "$TEMP_DIR/lib-device"
    DEVICE_LIBS=$(find build-device -name "*.a" -not -path "*/CMakeFiles/*" 2>/dev/null)
    libtool -static -o "$TEMP_DIR/lib-device/libwhisper.a" $DEVICE_LIBS

    XCFRAMEWORK_ARGS="-library $TEMP_DIR/lib-device/libwhisper.a -headers $TEMP_DIR/headers $XCFRAMEWORK_ARGS"
fi

# ---------- Create XCFramework ----------
echo "==> Creating whisper.xcframework..."
mkdir -p "$FRAMEWORK_DIR"

# shellcheck disable=SC2086
xcodebuild -create-xcframework \
    $XCFRAMEWORK_ARGS \
    -output "$FRAMEWORK_DIR/whisper.xcframework"

echo ""
echo "Done! whisper.xcframework created at:"
echo "  $FRAMEWORK_DIR/whisper.xcframework"
echo ""
echo "Headers included:"
ls "$TEMP_DIR/headers/"
