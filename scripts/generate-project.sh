#!/bin/bash
#
# Generate the Xcode project and workspace from project.yml
#
# Prerequisites:
#   brew install xcodegen
#   brew install cocoapods   (or: sudo gem install cocoapods)
#
# Usage:
#   ./scripts/generate-project.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ── Check prerequisites ──────────────────────────────────────
missing=()
command -v xcodegen >/dev/null 2>&1 || missing+=("xcodegen (brew install xcodegen)")
command -v pod      >/dev/null 2>&1 || missing+=("cocoapods (brew install cocoapods)")
command -v cmake    >/dev/null 2>&1 || missing+=("cmake (brew install cmake)")

if [ ${#missing[@]} -ne 0 ]; then
    echo "Error: missing required tools:"
    for tool in "${missing[@]}"; do
        echo "  - $tool"
    done
    echo ""
    echo "Install them and re-run this script."
    exit 1
fi

# ── Step 1: Build whisper.xcframework if missing ─────────────
if [ ! -d "Frameworks/whisper.xcframework" ]; then
    echo "==> whisper.xcframework not found, building..."
    "$SCRIPT_DIR/setup-whisper.sh"
else
    echo "==> whisper.xcframework found"
fi

# ── Step 2: Generate Xcode project ──────────────────────────
echo "==> Generating Xcode project from project.yml..."
xcodegen generate

# ── Step 3: Install CocoaPods ────────────────────────────────
echo "==> Installing CocoaPods dependencies..."
pod install

echo ""
echo "Done! Open VoiceInk-ios.xcworkspace in Xcode:"
echo "  open VoiceInk-ios.xcworkspace"
