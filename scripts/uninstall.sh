#!/bin/bash
# Désinstallation propre d'AgentDash (14 · REQ-LIC-54) : retire nos hooks des configs
# tierces (sans toucher aux hooks de l'utilisateur), supprime ~/.agentdash, l'app et les
# réglages. Ne touche JAMAIS aux transcripts ni aux données des agents.
set -euo pipefail

echo "▸ Arrêt d'AgentDash"
pkill -f "AgentDash.app/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "▸ Retrait des hooks AgentDash (préserve vos hooks tiers)"
python3 - <<'PY'
import json, os
home = os.path.expanduser("~")
for path in [f"{home}/.claude/settings.json", f"{home}/.cursor/hooks.json"]:
    if not os.path.exists(path):
        continue
    try:
        cfg = json.load(open(path))
    except Exception:
        continue
    hooks = cfg.get("hooks", {})
    changed = False
    for event in list(hooks.keys()):
        entries = hooks[event]
        if not isinstance(entries, list):
            continue
        kept = [e for e in entries if "agentdash-hook" not in json.dumps(e)]
        if len(kept) != len(entries):
            changed = True
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        cfg.pop("hooks", None)
    if changed:
        json.dump(cfg, open(path, "w"), indent=2)
        print(f"  nettoyé : {path}")
PY

echo "▸ Suppression de ~/.agentdash (binaire hook + sauvegardes)"
rm -rf "$HOME/.agentdash"
rm -rf "$HOME/Library/Application Support/AgentDash"
rm -rf "$HOME/Library/Logs/AgentDash"

echo "▸ Suppression des réglages"
defaults delete com.agentdash.app 2>/dev/null || true

echo "▸ Suppression de l'app"
rm -rf "/Applications/AgentDash.app"

echo "✓ AgentDash désinstallé. Vos sessions Claude Code / Cursor sont intactes."
