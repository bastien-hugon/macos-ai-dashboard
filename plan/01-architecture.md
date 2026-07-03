# AgentDash (nom provisoire) — Architecture

> Document d'architecture, rédigé le 3 juillet 2026, à partir de `AGENTPEEK_FEATURES.md` (v0.2.11 analysée) et des cinq recherches de `plan/research/` (claude-code, cursor, notch-ui, system-integration, distribution-licensing).
> Convention : les choix marqués **[TRANCHÉ]** sont fermes et justifiés par des faits **VÉRIFIÉS** dans les recherches ; les points marqués **[HYPOTHÈSE]** reposent sur une déduction à valider en implémentation (renvoi vers la liste d'hypothèses de la recherche concernée). Aucune hypothèse n'est présentée comme un fait.

---

## 1. Vue d'ensemble

AgentDash est une app macOS native (Swift/SwiftUI, Apple Silicon, macOS 14+) qui observe et pilote les agents Claude Code et Cursor depuis le notch et la barre de menus. Elle se compose de **deux exécutables** et d'un **canal IPC local** :

1. **AgentDash.app** — l'application principale (agent app `LSUIElement`, sans icône Dock), qui héberge toutes les surfaces UI, les stores d'état, les pollers et le serveur IPC.
2. **agentdash-hook** (cible `HookRelay`) — binaire Swift autonome (~56 Ko, spawn médian mesuré 2,7 ms — VÉRIFIÉ), copié vers `~/.agentdash/bin/agentdash-hook` et référencé dans `~/.claude/settings.json` et `~/.cursor/hooks.json`. Il relaie chaque événement de hook vers l'app et retourne la décision.
3. **Socket UNIX** `~/Library/Application Support/AgentDash/agentdash.sock` (repli `$TMPDIR` si le chemin dépasse ~100 octets ; limite `sun_path` 104 octets VÉRIFIÉE) — protocole NDJSON, **1 connexion = 1 requête**, aller-retour mesuré 0,65 ms (VÉRIFIÉ).

### 1.1 Diagramme des processus et des flux de données

```
                    PROCESSUS EXTERNES                                 AGENTDASH.APP (1 processus)
┌────────────────────────────────────────────┐        ┌─────────────────────────────────────────────────────────┐
│ Claude Code (CLI / ext. VS Code / Desktop) │        │                    COUCHE INGESTION                     │
│   hooks: ~/.claude/settings.json ────┐     │        │  ┌───────────────┐   événements + décisions             │
│   transcripts: ~/.claude/projects/   │     │        │  │ HookServer    │◄───────────────┐                     │
│   registre: ~/.claude/sessions/      │     │        │  │ (NWListener,  │                │                     │
│   Keychain: Claude Code-credentials  │     │        │  │  socket UNIX) │        agentdash.sock (0600)         │
├──────────────────────────────────────┼─────┤        │  └──────┬────────┘                │                     │
│ Cursor (app / cursor-agent)          │     │ spawn  │  ┌──────▼────────┐         ┌──────┴───────┐             │
│   hooks: ~/.cursor/hooks.json ───────┼─────┼───────►│  │ EventRouter   │         │ agentdash-   │◄── stdin    │
│   DB: state.vscdb (SQLite WAL)       │     │        │  │ (normalise    │         │ hook (spawné │    JSON du  │
│   transcripts: ~/.cursor/projects/   │     │        │  │  Claude+Cursor│         │ par l'agent) │    hook     │
└──────────────────────────────────────┼─────┘        │  │  → DashEvent) │         └──────────────┘             │
                                       │              │  └──────┬────────┘   stdout JSON = décision             │
   FICHIERS SURVEILLÉS / SOURCES       │              │         │                                               │
┌──────────────────────────────────────▼─────┐        │  ┌──────▼──────────────────────────────────────┐        │
│ ~/.claude/projects/**/*.jsonl  ─ FSEvents ─┼───────►│  │ TranscriptIngestor (actor) ─ parseur JSONL  │        │
│ state.vscdb                    ─ poll RO ──┼───────►│  │ CursorStateReader  (actor) ─ SQLite lecture │        │
│ ports 3000–9999 (libproc)      ─ poll ─────┼───────►│  │ PortScanner        (actor) ─ scan 1,3 ms    │        │
│ api.anthropic.com /oauth/usage ─ poll ─────┼───────►│  │ ClaudeUsagePoller / CursorUsagePoller       │        │
│ cursor.com /api/usage-summary  ─ poll ─────┼───────►│  └──────┬──────────────────────────────────────┘        │
└────────────────────────────────────────────┘        │         │  deltas typés (Sendable)                      │
                                                      │  ┌──────▼──────────────────────────────────────┐        │
                                                      │  │           STORES @Observable (@MainActor)   │        │
                                                      │  │ SessionStore · PromptStore · UsageStore ·   │        │
                                                      │  │ ServerStore · SettingsStore · LicenseStore ·│        │
                                                      │  │ NotificationCenter interne · DoctorStore    │        │
                                                      │  └──────┬───────────────────┬──────────────────┘        │
                                                      │         │ observation      │ observation               │
                                                      │  ┌──────▼───────┐   ┌──────▼───────┐  ┌─────────────┐  │
                                                      │  │ NotchUI      │   │ MenuBarUI    │  │ SettingsUI  │  │
                                                      │  │ (NSPanel non │   │ (NSStatusItem│  │ Onboarding  │  │
                                                      │  │  activant)   │   │  + NSPopover)│  │ What's New  │  │
                                                      │  └──────────────┘   └──────────────┘  └─────────────┘  │
                                                      └─────────────────────────────────────────────────────────┘

Flux « Act » (permission/question/plan) :
  agent → spawn agentdash-hook → socket → HookServer → PromptStore → NotchUI (auto-expand + hotkeys ⌘A/⌘N/⌥A)
  → décision utilisateur → HookServer répond sur la MÊME connexion → agentdash-hook → stdout → agent.
  App fermée : connect() passe en .waiting (ENOENT, VÉRIFIÉ) → le hook sort exit 0 sans sortie → fail-open,
  l'agent affiche son prompt natif. L'utilisateur ne perd jamais la main.
```

### 1.2 Les quatre flux de données

| Flux | Source | Transport | Consommateur | Rôle |
|---|---|---|---|---|
| **Hooks (temps réel)** | événements Claude Code + Cursor | spawn `agentdash-hook` → socket UNIX NDJSON | `EventRouter` → `SessionStore`/`PromptStore` | état des sessions, prompts actionnables (source d'état **primaire**) |
| **Transcripts (historique + tokens)** | `~/.claude/projects/**/*.jsonl` (+ transcripts Cursor `~/.cursor/projects/*/agent-transcripts/`) | FSEvents récursif (latence 0,3 s, VÉRIFIÉ) → lecture incrémentale par offsets | `TranscriptIngestor` → `SessionStore` | timeline, tokens mid-turn (dédup `requestId`), diffs, récupération après relance d'AgentDash |
| **État Cursor (réconciliation)** | `state.vscdb` (`composerHeaders`, `composerData:`, `bubbleId:`) | SQLite lecture seule, poll 1–2 s si session active / 10 s sinon | `CursorStateReader` → `SessionStore` | liste des sessions Cursor, `hasBlockingPendingActions`, diffs, timeline historique |
| **Pollers** | endpoint OAuth usage Anthropic (180 s), endpoints dashboard Cursor (300 s), scan de ports libproc (2 s panel ouvert / 10 s sinon) | HTTPS / libproc | `UsageStore`, `ServerStore` | jauges 5 h/7 j, mensuel Cursor, serveurs dev |

---

## 2. Choix de stack **[TRANCHÉS]**

| Sujet | Décision | Justification |
|---|---|---|
| UI | **SwiftUI hébergé dans AppKit** : `NSPanel` custom (notch), `NSStatusItem` + `NSPopover` (menu bar), `NSWindow` (Settings/Onboarding), contenu 100 % SwiftUI via `NSHostingView` | Le notch exige un `NSPanel` `[.borderless, .nonactivatingPanel]`, `canBecomeKey = true` + `becomesKeyOnlyIfNeeded = true` (recette Cindori, VÉRIFIÉE) — impossible en pur SwiftUI. `MenuBarExtra` est écarté : label template monochrome (pas de point orange) et clic droit indifférenciable (VÉRIFIÉ). |
| Langage | **Swift 6, strict concurrency (`SWIFT_STRICT_CONCURRENCY=complete`)**, actors partout hors UI | Le projet est intrinsèquement concurrent (IPC, FSEvents, SQLite, pollers) ; la vérification à la compilation élimine les data races. Toolchain locale : Swift 6.3 (VÉRIFIÉ). |
| Cible de déploiement | **macOS 14.0, arm64 uniquement** | C'est le contrat produit d'AgentPeek (§1 features). macOS 14 donne `@Observable`, `SMAppService` (13+), CryptoKit, Network.framework. **Liquid Glass (`glassEffect`/`NSGlassEffectView`) exige macOS 26** (VÉRIFIÉ) : on ne monte PAS la cible pour un matériau — fallback `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `.active`) + couche `Color.black.opacity(slider)` derrière un modificateur maison `agentGlass()` avec branche `#available(macOS 26.0, *)`. Décision documentée ici, comme demandé. |
| Sandbox | **Pas d'App Sandbox** ; hardened runtime + Developer ID + notarisation | libproc, `kill()`, écriture de `~/.claude/settings.json`, socket partagé : tous incompatibles sandbox (VÉRIFIÉ — tous les prototypes ont tourné sans aucune permission TCC). Distribution hors Mac App Store, DMG signé/notarisé (comme AgentPeek). |
| Gestion de projet | **Un projet Xcode `AgentDash.xcodeproj`** (2 cibles : app + `agentdash-hook`) + **packages SPM locaux** dans `Packages/` pour tout le reste | Compile incrémentale par module, frontières de dépendances imposées par SPM, testabilité (chaque package a sa cible de tests), et le binaire hook reste une cible Xcode pour être signé/embarqué dans le bundle (`Contents/Helpers/`). |
| Dépendances tierces | **Sparkle 2 (SPM, version épinglée `exact:`)**, **KeyboardShortcuts** (raccourcis personnalisables, Carbon sans TCC), **SQLite3 système** (module map, pas de wrapper lourd type GRDB) | Minimalisme : chaque dépendance est un risque de notarisation et de poids. SQLite en C direct suffit pour des lectures ciblées par clé sur `state.vscdb`. |
| Transport des hooks | **Binaire compagnon + socket UNIX pour les DEUX agents** (pas de hooks `type:"http"` Claude) | Cursor ne supporte que des hooks `command` : le binaire est de toute façon obligatoire pour Cursor. Un canal unique = un seul protocole, un seul point de panne, un seul check Doctor. Latences mesurées (spawn 2,7 ms + IPC 0,65 ms) rendent l'avantage du HTTP négligeable. Le type `http` de Claude Code reste un plan B documenté si le binaire posait un problème Gatekeeper (hypothèse n°4 de system-integration). |
| Rendu Markdown | `AttributedString(markdown:)` natif + fallback texte brut | Suffisant pour les extraits de réponses ; pas de dépendance de rendu. À réévaluer si les tableaux/code blocks exigent mieux (cmark-gfm en plan B). |

---

## 3. Découpage en modules

### 3.1 Cibles et packages

| Module | Type | Responsabilités | Dépend de |
|---|---|---|---|
| **AgentDashApp** | cible app Xcode | `@main`, AppDelegate, composition root (injection des stores), cycle de vie fenêtres, Sparkle (`SPUStandardUpdaterController`), notifications `UNUserNotificationCenter`, hotkeys éphémères | tous les packages |
| **HookRelay** | cible CLI Xcode (`agentdash-hook`) | lire stdin JSON → envelopper (`{v, id, source, event, term_program, ppid, cwd}`) → socket → écrire la réponse sur stdout ; `.waiting`/erreur → exit 0 sans sortie. **Zéro logique de décision.** Ne dépend que de Darwin/Foundation (taille et spawn minimaux) | — (autonome) |
| **DashCore** | SPM | modèles du domaine (cf. `02-data-model.md`), protocole IPC (`HookEnvelope`, `HookDecision`), `EventRouter`, machine à états `SessionState`, stores `@Observable`, `HookServer` (NWListener), `TranscriptTailer` générique (FSEvents + offsets), logging (`DashLog`), protocoles `AgentProvider`/`UsageProvider` | — |
| **AgentClaude** | SPM | installeur/réparateur de hooks `~/.claude/settings.json` (fusion non destructive, marqueur), parseur des transcripts JSONL (dédup `requestId`, `structuredPatch`, subagents `isSidechain`), registre `~/.claude/sessions/<pid>.json` + liveness PID, lecture Keychain `Claude Code-credentials`, poller `GET /api/oauth/usage` (headers `anthropic-beta` + `User-Agent: claude-code/<version>`) | DashCore |
| **AgentCursor** | SPM | installeur/réparateur `~/.cursor/hooks.json` (fusion, version 1), lecteur `state.vscdb` (RO, requêtes par clé, retry `SQLITE_BUSY`, jamais `immutable=1`), parseur transcripts `agent-transcripts/*.jsonl`, table de traduction des noms d'outils (`run_terminal_command_v2` → « Ran command »), poller usage (cookie `WorkosCursorSessionToken`, `usage-summary`, `get-aggregated-usage-events`), stats locales `aiCodeTracking.dailyStats` | DashCore |
| **ServersKit** | SPM | scan libproc (`PROC_UID_ONLY` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, `TSI_S_LISTEN`), identification (`proc_pidpath`, `KERN_PROCARGS2` argv+env, cwd, `pbi_start_tvsec`), tables frameworks/runtimes, `npm_config_user_agent`, kill sécurisé (garde-fous D5) | DashCore |
| **UsageKit** | SPM | agrégation des fenêtres (5 h/7 j/mensuel), logique de jauges batterie et de seuils, rétention de la dernière valeur en cas d'échec, reset au rollover, stats journalières (parsing JSONL Claude + dailyStats Cursor), alertes de budget | DashCore (consomme les `UsageProvider` de AgentClaude/AgentCursor via injection) |
| **NotchUI** | SPM | `NotchPanel` (NSPanel), `NotchShape` animable, pill/panel, hover à délai d'intention, fermeture au clic extérieur, avatars pixel-grid (`TimelineView`+`Canvas`), cartes de session, timeline, prompts inline, Quick Routes, Fast Actions, `agentGlass()` | DashCore |
| **MenuBarUI** | SPM | `NSStatusItem` variableLength + `NSHostingView`, point orange, clic droit → Quit, `NSPopover` `.transient` | DashCore |
| **SettingsKit** | SPM | fenêtre Settings (sidebar : General/Notifications/Appearance/Usage/Shortcuts/Doctor/About), onboarding welcome, fenêtre What's New, écran d'achat | DashCore, DoctorKit, LicensingKit |
| **LicensingKit** | SPM | trial 48 h (double stockage Keychain+fichier, HMAC, high-water mark + `mach_continuous_time()`), activation licence (Worker → reçu Ed25519, vérif offline CryptoKit), `LicenseManager` réactif | DashCore |
| **DoctorKit** | SPM | checks : hooks présents/intacts, binaire copié + hash, socket joignable, versions minimales des agents, vérification croisée `lsof -F`, budgets RAM/CPU (`task_info`), export de logs | DashCore, AgentClaude, AgentCursor, ServersKit |

### 3.2 Règles de dépendances **[TRANCHÉ]**

- `DashCore` ne dépend de **rien** (hors SDK). Tous les types partagés y vivent.
- `AgentClaude` et `AgentCursor` ne se connaissent pas et ne dépendent d'aucun module UI. Ils implémentent les protocoles de `DashCore` (`AgentProvider`, `UsageProvider`, `HooksInstaller`).
- Les modules UI (`NotchUI`, `MenuBarUI`, `SettingsKit`) ne dépendent **que** de `DashCore` (+ DoctorKit/LicensingKit pour SettingsKit) : ils observent les stores, jamais les providers directement.
- Seul `AgentDashApp` assemble tout (composition root). Interdiction d'import transverse (vérifiée mécaniquement par SPM).
- `HookRelay` ne partage **pas de code** avec l'app (duplication assumée de ~30 lignes de framing NDJSON) pour garder un binaire de 56 Ko sans dépendance — le protocole est contractualisé par des tests d'intégration croisés.

### 3.3 Arborescence du repo

```
macos-ai-dashboard/
├── AGENTPEEK_FEATURES.md
├── plan/                          # documents de conception (ce dossier)
├── AgentDash.xcodeproj
├── Apps/
│   ├── AgentDash/                 # cible app : @main, AppDelegate, Info.plist, entitlements,
│   │   ├── Sources/               #   composition root, Sparkle, notifications, hotkeys
│   │   └── Resources/             # Assets.xcassets, CHANGELOG.md embarqué (What's New)
│   └── HookRelay/
│       └── Sources/main.swift     # agentdash-hook (autonome)
├── Packages/
│   ├── DashCore/       Sources/ + Tests/
│   ├── AgentClaude/    Sources/ + Tests/   (fixtures : transcripts JSONL anonymisés)
│   ├── AgentCursor/    Sources/ + Tests/   (fixtures : state.vscdb minimal généré)
│   ├── ServersKit/     Sources/ + Tests/
│   ├── UsageKit/       Sources/ + Tests/
│   ├── NotchUI/        Sources/ + Tests/
│   ├── MenuBarUI/      Sources/
│   ├── SettingsKit/    Sources/
│   ├── LicensingKit/   Sources/ + Tests/
│   └── DoctorKit/      Sources/ + Tests/
├── ci/                            # ExportOptions.plist, workflow release (macos-26)
├── scripts/                       # create-dmg, notarisation, generate_appcast
└── worker/                        # Cloudflare Worker d'activation (TypeScript)
```

---

## 4. Contrat IPC et installation des hooks

### 4.1 Protocole socket (NDJSON, version 1) **[TRANCHÉ]**

Chaque connexion transporte exactement une requête et au plus une réponse, terminées par `\n` (lecture en boucle jusqu'au `\n`, pas de buffer fixe — événements > 64 Ko possibles, ligne max observée 70 007 octets VÉRIFIÉ).

```jsonc
// hook → app (enveloppe écrite par agentdash-hook)
{ "v": 1,
  "id": "<uuid>",                    // corrélation pour les logs uniquement (la connexion corrèle déjà)
  "source": "claude" | "cursor",     // argument --source inscrit dans la config du hook
  "term_program": "iTerm.app",       // ENV hérité de l'agent → étiquette « environnement hôte » [VÉRIFIÉ]
  "ppid": 12345,                     // PID de l'agent (parent du hook)
  "event": { …stdin brut de l'agent, non modifié… } }

// app → hook (réponse) : le corps est écrit TEL QUEL sur stdout du hook.
// Claude Code : {"hookSpecificOutput": …} ; Cursor : {"permission": …}. Corps vide = « pas d'avis ».
```

Classification des événements côté `EventRouter` :
- **Décision** (connexion gardée ouverte jusqu'à la réponse) : `PermissionRequest`, `PreToolUse` matcher `AskUserQuestion|ExitPlanMode` (Claude) ; `beforeShellExecution`, `beforeMCPExecution` (Cursor).
- **Télémétrie** (réponse vide immédiate, fire-and-forget) : tout le reste.

Cas d'échec, tous en fail-open : app fermée → `connect()` en `.waiting`/ENOENT → exit 0 sans sortie (VÉRIFIÉ) ; app qui crashe pendant l'attente → connexion coupée → idem ; timeout côté agent → l'app détecte la fermeture de connexion et relâche le `PendingPrompt` (état `released`).

### 4.2 Jeu de hooks installé **[TRANCHÉ, syntaxes VÉRIFIÉES dans les recherches]**

**`~/.claude/settings.json`** (fusion non destructive de la clé `hooks`, entrées marquées par le chemin `~/.agentdash/bin/agentdash-hook`) :

| Événement | Matcher | Timeout | Rôle |
|---|---|---|---|
| `PermissionRequest` | `*` | 600 s | permissions + plans (`ExitPlanMode`) — cœur du « Act » |
| `PreToolUse` | `AskUserQuestion\|ExitPlanMode` | 600 s | questions inline (+ plans en secours) |
| `PreToolUse` | `*` | 5 s | télémétrie executing (déclenchement d'outil) |
| `PostToolUse`, `PostToolUseFailure` | `*` | 5 s | timeline, compteurs, durées |
| `UserPromptSubmit`, `Stop`, `StopFailure`, `Notification` | — | 5 s | machine à états, attention, notifications |
| `SessionStart`, `SessionEnd`, `CwdChanged` | — | 5 s | cycle de vie, /clear, rattachement projet |
| `SubagentStart`, `SubagentStop` | — | 5 s | activité subagents |
| `PreCompact`, `PostCompact`, `ConfigChange` | — | 5 s | marqueurs compaction ; Doctor (hooks écrasés) |

Le file watcher de Claude Code recharge les settings à chaud → les sessions déjà ouvertes récupèrent les hooks sans redémarrage (VÉRIFIÉ doc) : c'est le « zéro config » du produit.

**`~/.cursor/hooks.json`** (créé s'il n'existe pas — c'est le cas sur cette machine —, fusionné sinon, `"version": 1`) : `beforeSubmitPrompt`, `beforeShellExecution`, `beforeMCPExecution` (avec `timeout` explicite long — plafond réel à mesurer, hypothèse cursor n°2), `afterShellExecution`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `afterFileEdit`, `afterAgentResponse`, `afterAgentThought`, `subagentStart`, `subagentStop`, `sessionStart`, `sessionEnd`, `stop`. Jamais `failClosed: true` (fail-open partout).

### 4.3 Séquence de démarrage de l'app

1. `LicenseManager.load()` (Keychain + fichier, fusion pessimiste) — détermine l'UI d'accueil (onboarding / achat / normal).
2. Suppression du socket périmé, démarrage de `HookServer` (le canal doit être prêt **avant** tout le reste : des hooks peuvent arriver immédiatement).
3. Resynchronisation de `~/.agentdash/bin/agentdash-hook` (comparaison de hash = « réparer »).
4. Vérification/fusion des hooks (si toggles actifs) + snapshot Doctor.
5. Chargement initial : registre `~/.claude/sessions/` (+ liveness PID) → `allComposers` Cursor → parse des transcripts récents (`mtime` < 48 h) → démarrage FSEvents, pollers, scan de ports.
6. Création des fenêtres (notch par écran via `displayUUID`, status item), abonnement `didChangeScreenParametersNotification` et `didWakeNotification`.

---

## 5. Threading et concurrence

### 5.1 Répartition **[TRANCHÉ]**

| Contexte d'exécution | Contenu | Notes |
|---|---|---|
| **@MainActor** | tous les stores `@Observable` (`SessionStore`, `PromptStore`, `UsageStore`, `ServerStore`, `SettingsStore`, `LicenseStore`, `DoctorStore`), fenêtres/panels, hotkeys, `EventRouter` (mutation d'état finale) | Les stores sont la **seule** source de vérité UI ; mutations uniquement sur MainActor → SwiftUI observe sans verrous. |
| **`HookServer`** (queue dédiée `NWListener`) | accept/framing NDJSON des connexions du hook | Chaque événement est transformé en `DashEvent: Sendable` puis `await`é sur MainActor. La **réponse** (closure `reply`) capture la connexion : la décision de l'utilisateur, prise sur MainActor, est renvoyée sur la queue réseau. |
| **`actor TranscriptIngestor`** | callback FSEvents (queue dédiée), `stat()` + lecture incrémentale, parsing `JSONDecoder` ligne à ligne, agrégation en `SessionDelta` | Debounce par chemin : max 1 drain / 250 ms / fichier (la latence FSEvents de 0,3 s coalesce déjà). Publication par **lots** vers MainActor (1 `SessionDelta` groupé par tick, jamais 1 par ligne). |
| **`actor CursorStateReader`** | connexion SQLite RO persistante, requêtes ciblées, diff avec le snapshot précédent | Poll adaptatif : 1,5 s si ≥ 1 session Cursor non idle, 10 s sinon, 0 si Cursor absent. |
| **`actor PortScanner`** | scan libproc (1,3 ms mesuré), cache d'identification par `(pid, start_time)` | Tick 2 s (panel ouvert, section serveurs visible) / 10 s (sinon) ; scan immédiat à l'ouverture du panel. |
| **`actor ClaudeUsagePoller` / `actor CursorUsagePoller`** | requêtes HTTPS, parsing, relecture Keychain sur 401 | 180 s (Claude, rate limit VÉRIFIÉ sources) / 300 s (Cursor) + refresh manuel (bouton) avec anti-rafale 10 s. |
| **Tâches détachées courtes** | kill de serveur (SIGTERM → 3 s → SIGKILL), copie du binaire hook, Copy as Markdown (rendu du transcript) | `Task.detached(priority: .userInitiated)`, résultat rapporté sur MainActor. |

### 5.2 Règles

- Tout type traversant une frontière d'actor est `Sendable` (structs valeur du modèle — cf. `02-data-model.md`).
- **Aucun** parsing, I/O disque, SQLite ou libproc sur MainActor. Le MainActor ne fait que muter les stores et rendre l'UI.
- Debounce UI : les compteurs de tokens mid-turn sont mis à jour au plus toutes les **300 ms** par session (coalescence dans `TranscriptIngestor`) — au-delà, imperceptible et coûteux en re-render.
- Les hooks « décision » (`PermissionRequest`, `PreToolUse` sur `AskUserQuestion`/`ExitPlanMode`, `beforeShellExecution`/`beforeMCPExecution` Cursor) gardent leur connexion **ouverte** jusqu'à la décision, l'auto-libération (réponse vide à `timeout − 10 s`) ou la fermeture du prompt. Les hooks « télémétrie » sont fire-and-forget (réponse vide immédiate).
- Timers : un seul `DispatchSourceTimer` mutualisé par fréquence (1 s pour l'horloge/countdowns, 30 s pour l'auto-mesure, échéances armées à date exacte pour trial et rollover de fenêtres d'usage), plus `NSWorkspace.didWakeNotification` pour réévaluer après sommeil (les timers ne tirent pas pendant le sommeil — VÉRIFIÉ).

---

## 6. Budget de performance **[TRANCHÉ, à calibrer]**

| Métrique | Budget | Stratégies pour le tenir |
|---|---|---|
| RAM (`phys_footprint`) | **< 150 Mo** en régime établi | Timeline plafonnée en mémoire par session (fenêtre glissante de 2 000 événements rendus, le reste relu à la demande depuis le transcript — « sans limite d'historique » côté données, fenêtré côté RAM) ; pas de rétention des `tool_result` volumineux (résumés seulement) ; `conversationState` Cursor jamais chargé ; images/base64 ignorées au parsing. |
| CPU au repos (aucune session active, notch fermé) | **< 0,5 %** | FSEvents (0 CPU sans écriture) ; polls SQLite/ports ralentis à 10 s ; pollers usage 180/300 s ; avatars `TimelineView` **en pause** quand le notch est fermé ou la session idle ; pas de `NSVisualEffectView` actif sur le pill (noir pur). |
| CPU en activité (2 sessions actives, panel ouvert) | < 5 % | parsing incrémental par offsets (jamais de relecture complète), coalescence 250–300 ms, diffs de listes (`Identifiable` stables) pour éviter les re-render globaux. |
| Latence hook → UI | **< 150 ms** (hors décision humaine) | chaîne mesurée : spawn 2,7 ms + IPC 0,65 ms + hop MainActor + 1 frame SwiftUI ≈ 25 ms ; l'auto-expand (animation 420 ms) démarre dans le même tick. Marge ×5 conservée pour les hooks tiers en parallèle (fusion « tous doivent finir » côté Claude Code — VÉRIFIÉ doc). |
| Latence état de session (fallback sans hooks) | < 1 s (Claude, FSEvents 0,3 s) / < 2 s (Cursor, poll DB) | assumé et documenté : les hooks restent la voie nominale. |
| Chargement initial | < 1 s pour 100 Mo de transcripts | au lancement : parse complet des `.jsonl` avec `mtime` < 48 h, `offset = taille` pour les anciens (VÉRIFIÉ : 2 Mo locaux instantanés ; extrapolation hypothèse n°8 system-integration). |
| Auto-surveillance | échantillon `task_info` toutes les 30 s | dépassement persistant (3 échantillons) → signal dans Doctor (« performance ») — c'est le mécanisme derrière les « réductions RAM/CPU » v0.2.6–0.2.7 d'AgentPeek. |

---

## 7. Gestion des erreurs et logging

### 7.1 Principes

- **Fail-open absolu côté agents** : `agentdash-hook` ne retourne jamais un exit ≠ 0 sur erreur interne ; app fermée/timeout/JSON invalide ⇒ silence ⇒ l'agent applique son comportement natif. AgentDash ne doit **jamais** pouvoir bloquer une session de l'utilisateur.
- **Dégradation par flux, jamais globale** : chaque flux (hooks, transcripts, DB Cursor, usage, ports) a son propre état de santé (`healthy / degraded(reason) / unavailable`) exposé dans `DoctorStore`. La panne d'un flux n'éteint pas les autres (ex. endpoint usage en 429 → jauges figées sur la dernière valeur avec horodatage, badge « usage health notice », le reste vit).
- **Jauges** : en cas d'échec de refresh, **retenir la dernière valeur** (comportement AgentPeek explicite) ; afficher `--` uniquement quand aucune valeur n'a jamais été obtenue.

### 7.2 Modes dégradés

| Situation | Comportement |
|---|---|
| Agent non installé (`~/.claude` ou `~/.cursor` absent) | l'agent n'apparaît ni dans les sessions ni dans Settings→hooks (carte « Non détecté » avec lien d'installation) ; Quick Routes filtrées par existence des chemins. |
| Agent installé mais hooks non installés/écrasés | sessions détectées en mode « lecture seule » (transcripts/DB), prompts inline indisponibles → bannière + bouton « Install hooks » ; détection via `ConfigChange` (Claude) et re-check périodique du Doctor. |
| Version d'agent trop ancienne (ex. `PermissionRequest` ou `updatedInput.answers` absents) | Doctor affiche la version minimale supportée ; les features concernées se désactivent individuellement (hypothèse n°8 claude-code : version plancher à fixer). |
| Keychain refusé (invite déclinée) | usage Claude indisponible (jauges `--`), bouton « réessayer » dans Settings→Usage ; tout le reste fonctionne. |
| Cursor sans `hasBlockingPendingActions` fiable / hooks question-plan impossibles | permissions Cursor uniquement via hooks bloquants ; questions/plans Cursor **affichés** mais non actionnables (aligné AgentPeek : ⌥A et réponses réservés à Claude Code) — hypothèses n°4-5 cursor.md. |

### 7.3 Logging

- **OSLog** (`Logger`, subsystem `com.<org>.agentdash`, catégories : `hooks`, `ipc`, `claude`, `cursor`, `servers`, `usage`, `ui`, `licensing`, `doctor`) — niveau `.debug` non persistant, `.info`+ persistant.
- **Fichier exportable** : miroir des niveaux `.notice`+ vers `~/Library/Logs/AgentDash/agentdash.log` (rotation 5 × 2 Mo), via un `actor LogSink`. Bouton « Export logs » (Settings→About et Doctor) : zip du dossier + `OSLogStore` des dernières 24 h + rapport Doctor JSON. **Aucun contenu de prompt/réponse/diff dans les logs** — uniquement des identifiants, tailles et codes d'erreur (promesse privacy).
- `agentdash-hook` ne logge rien par défaut (stdout est le canal de décision !) ; mode debug opt-in via `~/.agentdash/debug` (fichier drapeau) → append vers `~/Library/Logs/AgentDash/hook.log`.

---

## 8. Sécurité et vie privée by design

1. **Tout local** : transcripts, diffs, prompts, état des sessions ne quittent jamais la machine. Aucune télémétrie, aucun compte, aucun analytics (contrat AgentPeek §12 repris à l'identique).
2. **Réseau limité à 4 destinations**, chacune désactivable : `api.anthropic.com` (usage Claude, opt-out dans Settings→Usage), `cursor.com` (usage Cursor, opt-out), l'appcast Sparkle (checks horaires), le Worker de licence (activation/revalidation ; transmet uniquement clé + `SHA-256(IOPlatformUUID + sel)` + version d'app).
3. **Socket IPC** : dossier `0700`, socket `0600` → seul l'utilisateur courant se connecte (permissions POSIX, VÉRIFIÉ en principe). Le protocole n'exécute rien : données + décisions typées.
4. **Périmètre processus** : libproc en `PROC_UID_ONLY`, garde-fous de kill (PID ≥ 100, uid == user, re-validation `(start_time, execPath)` anti-réutilisation de PID, jamais soi-même/ancêtre, confirmation UI en 2 temps, jamais `killpg`).
5. **Écritures de config tierces minimales et réversibles** : fusion non destructive de `~/.claude/settings.json` et `~/.cursor/hooks.json` (préservation des hooks tiers, marqueur `agentdash` pour identifier nos entrées), sauvegarde `.bak` horodatée avant première écriture, désinstallation propre (toggle off = retrait de nos entrées uniquement).
6. **Secrets** : tokens Claude/Cursor lus à la demande, jamais persistés par AgentDash, jamais envoyés ailleurs que vers leur service d'origine ; clés privées (Sparkle EdDSA, licence Ed25519) jamais dans le repo ni dans l'app.
7. **Pas d'API privées** (CGSSpace/SkyLight écartés — VÉRIFIÉ notch-ui), pas de permission TCC requise (ni Accessibility ni Full Disk Access — VÉRIFIÉ), hotkeys via `RegisterEventHotKey` **éphémères** (enregistrées uniquement pendant qu'un prompt est visible).
8. Option `sharingType = .none` (« masquer le notch des enregistrements d'écran ») offerte dans Appearance.

---

## 9. Stratégie de tests

- **DashCore** : tests unitaires de la machine à états (chaque transition de `02-data-model.md` §3 = un cas), du framing NDJSON, de la déduplication `requestId` et `SessionID`.
- **AgentClaude / AgentCursor** : tests sur fixtures — transcripts JSONL réels anonymisés (types `user`/`assistant`/`attachment`/`ai-title`…, lignes de 70 Ko, entrées streaming dupliquées) et `state.vscdb` minimal généré (schéma `_v: 16`, `bubbleId:`/`composerData:`) ; le parseur doit **ignorer les types inconnus** sans erreur (tolérance aux versions).
- **HookRelay ↔ HookServer** : tests d'intégration croisés (le protocole n'est pas partagé en code — cf. §3.2) : nominal, socket absent (`.waiting` → exit 0 silencieux), réponse lente, ligne géante, app tuée en cours d'attente.
- **ServersKit** : test de conformité contre `lsof -F` sur la machine de CI (le même check que Doctor).
- **LicensingKit** : simulation d'horloge injectée (`ClockProvider` protocolisé) — rollback, sommeil, reboot, divergence Keychain/fichier.
- **UI** : smoke tests manuels scriptés (checklist par release) ; les tests automatisés d'un `NSPanel` non-activant sont peu fiables — assumé.
- **Bancs d'hypothèses** : chaque hypothèse numérotée des recherches reçoit un mini-programme de validation dans `scripts/experiments/` (ex. `PermissionRequest` interactif, `updatedInput.answers`, timeout hooks Cursor) exécuté AVANT de construire la feature dépendante.

---

## 10. Récapitulatif des décisions structurantes

| # | Décision | Statut |
|---|---|---|
| A1 | 2 exécutables (app + `agentdash-hook`) reliés par socket UNIX NDJSON, 1 connexion = 1 requête | Ferme (mesuré) |
| A2 | Binaire hook copié vers `~/.agentdash/bin/`, resynchronisé à chaque lancement (= « réparer ») | Ferme |
| A3 | Hooks = source d'état primaire ; transcripts/DB = timeline, tokens, historique, fallback | Ferme |
| A4 | SwiftUI dans AppKit ; `NSPanel` non-activant key-able ; `NSStatusItem` AppKit (pas `MenuBarExtra`) | Ferme |
| A5 | Swift 6 strict concurrency ; stores `@Observable` sur MainActor ; ingestion en actors | Ferme |
| A6 | macOS 14+, arm64 ; Liquid Glass via `agentGlass()` avec fallback `NSVisualEffectView` | Ferme |
| A7 | Pas de sandbox ; Developer ID + notarisation ; DMG + Sparkle (checks 3600 s) | Ferme |
| A8 | Xcode + packages SPM locaux, dépendances orientées `DashCore` sans imports transverses | Ferme |
| A9 | Budgets : RAM < 150 Mo, CPU idle < 0,5 %, hook → UI < 150 ms, auto-mesure Doctor | Cibles à calibrer |
| A10 | Fail-open partout ; santé par flux ; jauges qui retiennent la dernière valeur | Ferme |
| A11 | Licence : Lemon Squeezy + Worker Cloudflare + reçu Ed25519 offline ; trial 48 h anti-rollback (`mach_continuous_time` + high-water mark + accumulateur) | Ferme (hypothèses LS n°3-4 distribution-licensing à valider) |

### Hypothèses majeures suivies (voir les listes détaillées des recherches)

1. `PermissionRequest` en session interactive : le dialogue terminal attend-il le hook ; conflit terminal/notch (« prompt handling location ») — claude-code n°1.
2. `AskUserQuestion` interactif : `allow + updatedInput.answers` court-circuite-t-il le sélecteur terminal (fallback `deny + message`) — claude-code n°2.
3. `conversation_id` Cursor == `composerId` ; timeout par défaut des hooks Cursor ; fiabilité dynamique de `hasBlockingPendingActions`/`generatingBubbleIds` — cursor n°1, 2, 5.
4. Gatekeeper sur le binaire hook copié hors bundle (build signée réelle) — system-integration n°4.
5. Correspondance Spend/Weighted/Auto/API ↔ champs `usage-summary` — cursor n°8.
