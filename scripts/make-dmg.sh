#!/bin/bash
# Packaging one-shot d'AgentDash (14 · REQ-LIC-39..41) : build release → app signée →
# DMG. Notarisation optionnelle (si ASC_* fournis). Aucune infra distante (pas d'appcast).
# Usage : scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/make-app.sh" release
APP="$ROOT/build/AgentDash.app"
DMG="$ROOT/build/AgentDash.dmg"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.1)"

echo "▸ Version $VERSION"

# DMG via create-dmg si disponible, sinon hdiutil brut.
rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
  echo "▸ create-dmg"
  create-dmg \
    --volname "AgentDash" \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "AgentDash.app" 140 180 \
    --app-drop-link 400 180 \
    "$DMG" "$APP" || true
else
  echo "▸ hdiutil (create-dmg absent — brew install create-dmg pour un DMG stylé)"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "AgentDash" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi

# Notarisation optionnelle (REQ-LIC-40) : nécessite ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY.
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY:-}" ]]; then
  echo "▸ notarytool submit"
  xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
else
  echo "▸ notarisation ignorée (ASC_* non fournis) — build utilisable en local ; clic droit → Open à la 1re ouverture"
fi

echo "✓ $DMG ($VERSION)"
