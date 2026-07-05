# AgentDash

Tout le contexte du projet (architecture, commandes, pièges, état, reste à faire) est dans
**@AGENTS.md** — lis-le en entier avant de modifier du code.

Rappels critiques (détails dans AGENTS.md §5) :
- Fail-open absolu du binaire hook — ne jamais bloquer une session d'agent.
- Jamais de mutation d'`@Observable` pendant le rendu SwiftUI.
- `HookServer` = sockets POSIX (NWListener ne supporte pas les sockets UNIX).
- Vérification « guard » obligatoire : build + tests + capture d'écran réelle
  (`AGENTDASH_FORCE_PANEL=1` + `screencapture`).
