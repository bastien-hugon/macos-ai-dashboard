#!/bin/bash
# Packaging one-shot d'AgentDash (14 · REQ-LIC-39..41) : build release → app signée →
# DMG stylé. Notarisation optionnelle (scripts/notarize.sh). Aucune infra distante.
# Usage : scripts/make-dmg.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" # create-dmg (Homebrew)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/make-app.sh" release
APP="$ROOT/build/AgentDash.app"
DMG="$ROOT/build/AgentDash.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.1)"

echo "▸ Version $VERSION"
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  echo "▸ create-dmg (stylé)"
  create-dmg \
    --volname "AgentDash $VERSION" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "AgentDash.app" 140 190 \
    --app-drop-link 400 190 \
    --hide-extension "AgentDash.app" \
    --no-internet-enable \
    "$DMG" "$APP"
else
  echo "▸ hdiutil (create-dmg absent — brew install create-dmg pour un DMG stylé)"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "AgentDash" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi

# Notarisation optionnelle (no-op si ASC_* absents).
"$ROOT/scripts/notarize.sh" "$DMG"

echo "✓ $DMG ($VERSION, $(du -h "$DMG" | cut -f1))"
