#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-/private/tmp/cantonese-transcriptor-release}"
DIST_DIR="${DERIVED_DATA}/Transcriptor-distribution"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Transcriptor.app"
RESOURCES_DIR="$APP_PATH/Contents/Resources"

cd "$ROOT_DIR"

# Build the app
xcodebuild \
  -project macos/Transcriptor.xcodeproj \
  -scheme Transcriptor \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  build

mkdir -p "$RESOURCES_DIR"

# Remove legacy bundled envs from earlier packaging experiments. This package
# intentionally ships a small app and installs Python envs in Application Support.
rm -rf "$RESOURCES_DIR/python-env" "$RESOURCES_DIR/pyannote-env"

# Copy helper into app bundle
rsync -a --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  helper/ "$RESOURCES_DIR/helper/"

# Build distribution folder (portable: app + setup script, no repo needed)
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Copy app
cp -a "$APP_PATH" "$DIST_DIR/Transcriptor.app"

# Copy setup script, making it self-contained: it will find requirements.txt
# either next to the script (repo layout) or inside the bundled app (distribution layout)
cp scripts/setup_transcriptor_env.sh "$DIST_DIR/setup_transcriptor_env.sh"
chmod +x "$DIST_DIR/setup_transcriptor_env.sh"

echo ""
echo "=== Summary ==="
echo "Distribution folder: $DIST_DIR"
echo "  Transcriptor.app/  (small — helper scripts only, no Python bundled)"
echo "  setup_transcriptor_env.sh"
echo ""
echo "To set up environments on this Mac:"
echo "  cd \"$DIST_DIR\""
echo "  ./setup_transcriptor_env.sh"
echo ""
echo "To install pyannote (optional, for diarization):"
echo "  ./setup_transcriptor_env.sh --with-pyannote"
echo ""
echo "The app will look for envs at:"
echo "  ~/Library/Application Support/Transcriptor/envs/main/bin/python"
echo "  ~/Library/Application Support/Transcriptor/envs/pyannote/bin/python"
