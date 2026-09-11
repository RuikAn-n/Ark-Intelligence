#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
FRONTEND_DIR="$PROJECT_DIR/frontend"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_DIR="$OUTPUT_DIR/Ark Intelligence.app"

"$PROJECT_DIR/backend/.venv/bin/python" "$SCRIPT_DIR/sync_native_catalog.py"
swift build --package-path "$FRONTEND_DIR" --scratch-path "$OUTPUT_DIR/swift" -c debug -j 2
BIN_DIR=$(swift build --package-path "$FRONTEND_DIR" --scratch-path "$OUTPUT_DIR/swift" -c debug --show-bin-path)

if [[ -d "$APP_DIR" ]]; then
  rm -rf "$APP_DIR"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ArkIntelligence" "$APP_DIR/Contents/MacOS/ArkIntelligence"
if [[ -d "$BIN_DIR/ArkIntelligence_ArkIntelligence.bundle" ]]; then
  cp -R "$BIN_DIR/ArkIntelligence_ArkIntelligence.bundle" "$APP_DIR/Contents/Resources/"
fi
cp "$FRONTEND_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier com.arkintelligence.desktop "$APP_DIR"
echo "$APP_DIR"
