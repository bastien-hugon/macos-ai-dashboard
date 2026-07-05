# AgentDash — Contexte pour agents IA

> Fichier de passation : tout ce qu'il faut savoir pour continuer le travail sur ce repo.
> Dernière mise à jour : 5 juillet 2026. Lis ce fichier EN ENTIER avant de modifier du code.

## 1. Qu'est-ce que ce projet

**AgentDash** (nom provisoire) est un clone de [AgentPeek](https://agentpeek.app) : une app
macOS native (Swift 6 / SwiftUI, Apple Silicon, macOS 14+) qui affiche l'état des agents de
code IA — **Claude Code et Cursor** (Codex volontairement exclu) — dans le **notch du Mac**
et la barre de menus : sessions live, permissions répondables au clavier, usage de tokens,
serveurs de dev locaux.

**Décisions produit gelées (ne pas revenir dessus)** :
- Modèle **« one-shot »** : ni licence, ni trial, ni auto-update (Sparkle), ni site web.
  Mise à jour = remplacer `AgentDash.app`. Voir `plan/14-onboarding-distribution.md`.
- **100 % local, zéro télémétrie**. Réseau limité à 2 destinations opt-out :
  `api.anthropic.com` (usage Claude) et `cursor.com` (usage Cursor).
- **Fail-open absolu** : le binaire hook ne doit JAMAIS bloquer une session d'agent.
  Toute anomalie ⇒ `exit 0` sans stdout ⇒ l'agent affiche son dialogue natif.

## 2. Sources de vérité

| Quoi | Où |
|---|---|
| Spécifications normatives | `plan/00-…` → `plan/16-…` (exigences `REQ-XXX-NN`, jamais renumérotées ; suppressions = pierres tombales datées ; incertitudes = `[HYPOTHÈSE — à valider]`) |
| Recherche technique (formats réels, endpoints, schémas DB) | `plan/research/*.md` — **lis `claude-code.md` et `cursor.md` avant de toucher aux intégrations** |
| Référence produit AgentPeek | `AGENTPEEK_FEATURES.md` |
| Historique des versions | `CHANGELOG.md` |

## 3. Architecture (résumé)

Deux exécutables + un socket UNIX :

```
Claude Code / Cursor ──spawn──► agentdash-hook (~120 Ko, autonome, fail-open)
       │ hooks (settings.json / hooks.json)      │ NDJSON, 1 connexion = 1 requête
       │ transcripts JSONL / state.vscdb         ▼
       └──FSEvents / poll──►  AgentDash.app : HookServer → EventRouter → Stores @Observable
                                                 (MainActor) → NotchUI / MenuBar / Settings
```

Packages SPM locaux (`Packages/`), dépendances orientées vers `DashCore` uniquement :

| Package | Rôle |
|---|---|
| `DashCore` | modèles, stores `@Observable` (MainActor), `HookServer` (socket POSIX), `PromptStore`, `DecisionEncoder`, `TranscriptTailer` (FSEvents), `StateCache`, formats, `HonestCommandAnalyzer`. Produit aussi `TestSupport` (sandbox home, `TestClock`, `FakeAgent`). |
| `AgentClaude` | installeur hooks `~/.claude/settings.json`, parseur transcripts JSONL (dédup `requestId`), registre PID, `ClaudeEventRouter`, poller usage OAuth, stats journalières |
| `AgentCursor` | installeur `~/.cursor/hooks.json`, lecteur SQLite RO `state.vscdb` (sessions + timeline via `composerData`/`bubbleId`), `CursorEventRouter`, poller usage (`usage-summary` + `get-aggregated-usage-events`) |
| `ServersKit` | scan libproc ports 3000–9999, identification framework/runtime, kill sécurisé |
| `NotchUI` | NSPanel non-activant, pill/panel avec morph, cartes sessions/prompts, jauges, disclosure, accessibilité |
| `Apps/AgentDash` | composition root (`AppMain.swift`), contrôleurs (usage, serveurs, doctor, notifications, menu bar, settings, onboarding) |
| `Apps/HookRelay` | le binaire `agentdash-hook` (AUCUN code partagé avec l'app — dupliqué volontairement, contrat garanti par tests croisés) |

## 4. Commandes

```bash
# Build + tests (le binaire hook est requis par les tests d'intégration)
swift build
export AGENTDASH_HOOK_BINARY="$PWD/.build/arm64-apple-macosx/debug/agentdash-hook"
swift build --product agentdash-hook
for pkg in DashCore AgentClaude AgentCursor ServersKit NotchUI; do
  swift test --package-path Packages/$pkg
done
# ⚠️ le compteur agrégé en boucle shell est parfois flaky (sortie vide) → relancer le package seul.

# Bundler, installer, lancer
./scripts/make-app.sh debug          # → build/AgentDash.app (signé Developer ID si dispo)
rm -rf /Applications/AgentDash.app && cp -R build/AgentDash.app /Applications/ && open /Applications/AgentDash.app

# Release
./scripts/bump-version.sh 0.2.0      # SemVer + build counter (Info.plist)
./scripts/make-dmg.sh                # DMG stylé create-dmg ; notarisation si ASC_* exportés
./scripts/uninstall.sh               # désinstallation propre (préserve les hooks tiers)
# CI : .github/workflows/release.yml se déclenche sur tag v*
```

### Variables d'environnement de QA (Debug uniquement)

| Var | Effet |
|---|---|
| `AGENTDASH_FORCE_PANEL=1` | ouvre le panel notch 2 s après le lancement (pour capturer sans hover) |
| `AGENTDASH_OPEN_SETTINGS=1` + `AGENTDASH_SETTINGS_TAB=doctor` | ouvre Settings sur un onglet |
| `AGENTDASH_OPEN_POPOVER=1` | ouvre le popover menu bar sans clic |
| `AGENTDASH_ONBOARDING=1` | force l'onboarding |
| `AGENTDASH_HOME=/tmp/x` | racine home injectée (tests — jamais en Release) |
| `AGENTDASH_SOCKET_OVERRIDE=…` | socket IPC isolé (tests d'intégration) |

### Méthodologie de vérification (« guard »)

Chaque changement significatif : build → tests → **vérification visuelle réelle** :
```bash
pkill -9 -f AgentDash; ./scripts/make-app.sh debug
AGENTDASH_FORCE_PANEL=1 "build/AgentDash.app/Contents/MacOS/AgentDash" & sleep 9
screencapture -x /tmp/s.png   # puis recadrer avec sips et LIRE l'image
```
Pour tester le flux de permissions sans vrai agent, envoyer du **JSON VALIDE** au binaire :
```bash
python3 -c 'import json,sys; sys.stdout.write(json.dumps({...}))' | ~/.agentdash/bin/agentdash-hook --source claude
```
⚠️ Ne PAS utiliser `echo '...\n...'` en zsh : il produit de vrais sauts de ligne → JSON
invalide → fail-open silencieux qu'on prend pour un bug (déjà vécu).
Logs de diagnostic : `~/Library/Logs/AgentDash/agentdash.log` (catégories `usage`, `notif`,
`act`, `hooks`) — `log show` sur le subsystem OSLog est peu fiable sur cette machine.

## 5. Pièges durement appris (NE PAS RÉGRESSER)

1. **Jamais muter un `@Observable` dans du code appelé pendant le rendu SwiftUI**
   (ex. une fonction `gauge(for:)` lue par une vue) → boucle de rendu infinie, beachball.
   Calculer les états dérivés au moment de l'ingestion des données, pas du rendu.
2. **`NWListener` ne sait PAS écouter sur un socket UNIX** (EINVAL) → `HookServer` utilise
   des sockets POSIX + `DispatchSource`. Ne pas « moderniser » vers Network.framework.
3. **`RegisterEventHotKey` est GLOBAL** : sans le garde `panel.isKeyWindow`, un ⌘A tapé
   dans l'éditeur (select-all) déclenche Allow. Le garde est dans
   `NotchSurfaceCoordinator.handleHotkey` — ne pas l'enlever.
4. **`HookServer` doit retenir fortement chaque `HookRequest`** (via `closeMonitor`) :
   un handler qui ne capture pas `request` la désallouerait et casserait la détection de
   fermeture distante (bug réel trouvé par le harnais `FakeAgent`).
5. **Republier un snapshot identique = re-render permanent.** Les lecteurs (Cursor surtout)
   comparent une **signature stable** (sans timestamps volatils) avant de publier.
   Régression vécue : 53 % CPU. Vérifier le CPU après tout changement d'ingestion.
6. **Cursor `plan.used/limit` sont des COMPTES D'UNITÉS, pas des cents.** Les vrais dollars
   sont dans `onDemand.used` (cents). Les % sont dans `plan.*PercentUsed`. Vérifié sur l'API réelle.
7. **macOS résout `python3` → `.../Python.app/.../Python`** (basename ≠ argv[0]) : la
   détection de runtime des serveurs regarde argv[0] ET l'exec path.
8. **NSPopover + SwiftUI : borner la hauteur** (`ScrollView` + `preferredContentSize`),
   sinon un contenu haut déborde au-dessus de l'écran.
9. **Tokens Claude : dédup par `requestId`** (le streaming écrit 2-10 entrées cumulatives
   par requête) et toujours compter `cache_read` + `cache_creation` dans la consommation.
10. **Endpoint usage Claude** : `GET api.anthropic.com/api/oauth/usage`, token du Keychain
    (service `Claude Code-credentials`), header `User-Agent: claude-code/<version>`
    **impératif** (sinon 429). Le premier accès Keychain déclenche une invite macOS.
11. Fusion des configs tierces (`settings.json`, `hooks.json`) : **non destructive**,
    marqueur = chemin `~/.agentdash/bin/agentdash-hook`, backup `.bak` dans
    `~/.agentdash/backups/`, écriture atomique. Tests dans les deux packages agents.

## 6. État machine locale (celle du développeur)

- MacBook notché (notch 220×38 pt), UN SEUL écran → fausse encoche externe non vérifiée visuellement.
- Hooks AgentDash **installés dans les vrais** `~/.claude/settings.json` (8) et `~/.cursor/hooks.json` (8).
- Keychain (usage Claude) **autorisé** ; notifications macOS **autorisées** ; app dans `/Applications` ; certificat Developer ID présent.
- La session Claude Code de développement est elle-même visible dans le panel (dogfooding).

## 7. Ce qui est FAIT et vérifié (ne pas refaire)

Jalons M0→M16 (voir `plan/16-roadmap-milestones.md` pour M0-M8 ; M9-M16 = accessibilité,
appearance/subagents, harnais FakeAgent, boucle Act e2e, parité Cursor, pipeline release,
multi-écrans, persistance). **~121 tests verts.** Vérifié à l'écran : pill/panel + morph,
cartes des 3 prompts (permission/plan/question), file multi-prompts (« +N waiting »),
sessions Claude+Cursor, ligne d'usage inline centrée (`Λ %session tokens · ⬡ $jour tokens`),
serveurs repliables (notch + popover), Doctor 6/6 avec self-test IPC, onboarding, Settings
7 onglets, notifications déclenchées, DMG monté avec app signée. CPU ~5 % sous charge
active, RAM ~60-70 Mo.

## 8. Ce qui RESTE (par ordre de valeur)

1. **Validation avec de vrais agents en interactif** : déclencher une permission depuis une
   vraie session Claude Code / Cursor et répondre depuis le notch (les round-trips ont été
   validés en injectant les événements ; l'hypothèse n°1 de `plan/research/claude-code.md`
   — comportement du dialogue terminal pendant la rétention — reste à observer en réel).
2. **⌘A réel** : la plomberie est vérifiée (panel devient key), mais aucun humain n'a encore
   appuyé sur ⌘A ; risque résiduel de collision select-all à confirmer.
3. **Notarisation** : câblée (`scripts/notarize.sh`, CI) mais jamais exécutée — nécessite
   des identifiants App Store Connect (`ASC_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`).
4. **Écran externe** : fausse encoche + mode « tous les écrans » testés unitairement
   seulement — brancher un écran et vérifier.
5. Polish : calibrage visuel fin vs AgentPeek (valeurs marquées `[HYPOTHÈSE]`), tests
   snapshot UI, VoiceOver audio réel, `beforeSubmitPrompt`/`afterAgentThought` Cursor pour
   affiner la machine à états.
6. Idées produit non commencées : chip tokens « point pulsant » mid-turn (REQ-USG-42),
   actions Allow/Deny dans la notification (catégories déjà enregistrées, handler présent —
   à tester), route « Respond in Cursor » (REQ-ACT-23).

## 9. Règles de contribution

- Français pour la doc/commits (style existant), anglais pour l'UI et les identifiants.
- Un changement = build + tests + guard visuel + commit ciblé (voir l'historique git pour le format).
- Ne jamais affaiblir : fail-open, garde hotkey, signatures stables, fusion non destructive.
- Écritures dans `~/.claude`/`~/.cursor` : uniquement via les installeurs (jamais à la main).
- Les tests qui écrivent utilisent `SandboxHome` (garde anti-destruction) — jamais le vrai home.
