#!/bin/bash
# Bundle AgentDash.app depuis le build SPM (14 · REQ-LIC-39 : signature Developer ID
# si disponible, sinon ad hoc). Usage : scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/build/AgentDash.app"

echo "▸ swift build -c $CONFIG"
swift build --package-path "$ROOT" -c "$CONFIG"

echo "▸ bundle → $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/AgentDash" "$APP_DIR/Contents/MacOS/AgentDash"
cp "$BUILD_DIR/agentdash-hook" "$APP_DIR/Contents/Helpers/agentdash-hook"
cp "$ROOT/Apps/AgentDash/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Signature : Developer ID si présent dans le trousseau, sinon ad hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
if [[ -n "$IDENTITY" ]]; then
  echo "▸ codesign (Developer ID : $IDENTITY)"
  codesign --force --options runtime --sign "$IDENTITY" "$APP_DIR/Contents/Helpers/agentdash-hook"
  codesign --force --options runtime --sign "$IDENTITY" "$APP_DIR"
else
  echo "▸ codesign (ad hoc — ouverture par clic droit à la première exécution)"
  codesign --force --sign - "$APP_DIR/Contents/Helpers/agentdash-hook"
  codesign --force --sign - "$APP_DIR"
fi

echo "✓ $APP_DIR"
