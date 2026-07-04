#!/bin/bash
# Notarisation Apple (14 · REQ-LIC-40) — OPTIONNELLE. Nécessite des identifiants App Store
# Connect : ASC_KEY (chemin .p8), ASC_KEY_ID, ASC_ISSUER_ID. Sans eux, ce script s'arrête
# proprement (la build ad hoc / Developer ID reste utilisable en local).
# Usage : scripts/notarize.sh build/AgentDash.dmg
set -euo pipefail

TARGET="${1:?usage: notarize.sh <app-or-dmg>}"

if [[ -z "${ASC_KEY:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
  echo "▸ Notarisation ignorée : ASC_KEY / ASC_KEY_ID / ASC_ISSUER_ID non fournis."
  echo "  (Créez une clé API dans App Store Connect → Users and Access → Integrations.)"
  exit 0
fi

echo "▸ notarytool submit --wait"
xcrun notarytool submit "$TARGET" \
  --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

echo "▸ stapler staple"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
echo "✓ Notarisé et agrafé : $TARGET"
