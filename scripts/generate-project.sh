#!/bin/bash
#
# Generate the Xcode project and workspace from project.yml
#
# Prerequisites:
#   brew install xcodegen
#   sudo gem install cocoapods
#
# Usage:
#   ./scripts/generate-project.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Step 1: Build whisper.xcframework if missing
if [ ! -d "Frameworks/whisper.xcframework" ]; then
    echo "==> whisper.xcframework not found, building..."
    "$SCRIPT_DIR/setup-whisper.sh"
else
    echo "==> whisper.xcframework found"
fi

# Step 2: Generate Xcode project
echo "==> Generating Xcode project from project.yml..."
xcodegen generate

# Step 3: Install CocoaPods
echo "==> Installing CocoaPods dependencies..."
pod install

echo ""
echo "Done! Open VoiceInk-ios.xcworkspace in Xcode:"
echo "  open VoiceInk-ios.xcworkspace"
