# Plan AgentDash (nom provisoire) — index du dossier `plan/`

> AgentDash est la reproduction fonctionnelle complète d'**AgentPeek v0.2.11** (https://agentpeek.app) restreinte aux agents **Claude Code** et **Cursor** (Codex hors périmètre). App macOS native Swift/SwiftUI, Apple Silicon, macOS 14+.
> La référence produit exhaustive est **`../AGENTPEEK_FEATURES.md`** (à lire en premier) ; sa section 13 (changelog AgentPeek) a guidé l'ordre de la roadmap.

---

## 1. Comment utiliser ce plan

1. **Lire dans l'ordre 00 → 02** : `00` fixe le périmètre, les principes et le glossaire ; `01` les décisions d'architecture (A1–A11) ; `02` le modèle de données et la machine à états. Tous les autres fichiers s'y réfèrent sans les redéfinir.
2. **Exécuter par jalons** : `16-roadmap-milestones.md` est le point d'entrée de l'implémentation — il ordonne les tâches des fichiers 03–15 en jalons M0 → M8, chacun avec livrable démontrable, critères de sortie et spikes.
3. **Valider les hypothèses avant de coder** : chaque `[HYPOTHÈSE]` conditionnant une feature a un banc dans `scripts/experiments/` à exécuter **avant** l'implémentation (`00 · REQ-VIS-29`). Le résultat est reporté dans le fichier de plan concerné (statut → `[VÉRIFIÉ]` ou conception amendée). La liste consolidée est en §5 ci-dessous.
4. **Structure commune des fichiers 03–15** : chaque fichier suit le même gabarit en 8 sections — 1. Objectif & périmètre · 2. Exigences détaillées (`REQ-*`) · 3. Conception technique · 4. Spécification UX/UI (textes anglais exacts) · 5. Cas limites & gestion d'erreurs · 6. Critères d'acceptation (Given/When/Then) · 7. Dépendances & risques · 8. Découpage en tâches.
5. **Traçabilité** : une matrice features → REQ (`plan/traceability.md`, tâche `00 · T2`) doit être maintenue au fil des jalons ; c'est l'outil de contrôle de la parité (`00 · REQ-VIS-26`).

---

## 2. Table des fichiers

| Fichier | Contenu (résumé) |
|---|---|
| `00-vision-scope.md` | Document fondateur : pitch, personas, périmètre exact (Codex exclu), principes invariants (100 % local, fail-open, zéro config), glossaire canonique, couche AgentAdapter, REQ-VIS-01..30. |
| `01-architecture.md` | Architecture complète : 2 exécutables (app + `agentdash-hook`) reliés par socket UNIX NDJSON, modules SPM, threading Swift 6, budgets de performance, décisions fermes A1–A11. |
| `02-data-model.md` | Tous les types du domaine (`Session`, `SessionID`, `PendingPrompt`, `UsageWindow`, `DevServer`, `AppSettings`…), machine à états T1–T16/C1–C9, cycle de vie des sessions, persistance et invariants. |
| `03-integration-claude-code.md` | Intégration Claude Code de bout en bout : installeur de hooks `settings.json`, relais IPC, parsing des transcripts JSONL (dédup `requestId`), registre PID, poller d'usage OAuth. REQ-CLA. |
| `04-integration-cursor.md` | Intégration Cursor : `hooks.json`, lecteur `state.vscdb` (SQLite RO), permissions inline à capacités réduites, usage mensuel via le dashboard live, `CursorCompat`. REQ-CUR. |
| `05-notch-ui.md` | Surface notch : `NSPanel` non-activant, pill/panel, géométrie et fausse encoche, hover à délai d'intention, animations, Liquid Glass + fallback, avatars pixel-grid, accessibilité. REQ-NUI. |
| `06-menubar.md` | Seconde surface : `NSStatusItem` + popover `.transient` à sections plates (usage, serveurs), point orange d'attention, clic droit → Quit, synchronisation par stores partagés. REQ-MBR. |
| `07-sessions.md` | Feature « Watch » : liste triée par projet, carte de session, row étendue (timeline virtualisée, subagents), Kill/Copy as Markdown/Dismiss, déduplication et survie des rows (`/clear`, resume). REQ-SES. |
| `08-actions-inline.md` | Feature « Act » : cycle de vie des `PendingPrompt`, cartes permission/plan/questions, formats de réponse JSON exacts, hotkeys éphémères ⌘A/⌘N/⌥A/⌥T, auto-libération, prompts « honnêtes ». REQ-ACT. |
| `09-token-usage.md` | Usage : jauges batterie 5 h/7 j Claude et mensuel Cursor (Spend/Weighted/Auto/API), rétention sur échec, rollover, alertes de budget, stats journalières, chip de tokens mid-turn, mode usage du pill. REQ-USG. |
| `10-local-servers.md` | Serveurs de dev : scan libproc 3000–9999, identification framework/runtime/runner, uptime, actions open/copy/stop en deux temps avec garde-fous anti-PID-recyclé. REQ-SRV. |
| `11-quick-routes-fast-actions.md` | Quick Routes (raccourcis Finder vers `~/.claude/*` et `~/.cursor/*`, chemins existants seulement) et Fast Actions (commandes shell sauvegardées, runner zsh sécurisé). REQ-QRF. |
| `12-notifications.md` | Notifications macOS natives : permission (actionnable Allow/Deny), budget, stuck, tâche terminée ; déduplication/throttling, retrait actif, hiérarchie des trois canaux d'attention. REQ-NOT. |
| `13-settings.md` | Fenêtre Settings (sidebar 7 onglets, bouton power, effet immédiat) et onglet **Doctor** : 16 checks avec remèdes en un clic, dont le self-test IPC round-trip. REQ-SET. |
| `14-onboarding-licensing-distribution.md` | Onboarding welcome guidé, trial 48 h anti-rollback, licence one-time 15 $ (Worker Cloudflare + Lemon Squeezy, reçu Ed25519 offline), Sparkle, pipeline DMG signé/notarisé + CI. REQ-LIC. |
| `15-testing-qa.md` | Stratégie de test : injection de chemins/horloge, fixtures anonymisées, harnais FakeAgent, snapshots, bancs de performance, checklist QA manuelle, matrice de compatibilité, 10 gates de release. REQ-TST. |
| `16-roadmap-milestones.md` | **Roadmap M0 → M8** calquée sur le changelog AgentPeek : socle/notch → sessions Claude → hooks/Act → usage → serveurs/routes → menu bar/notifications → Settings/Doctor → Cursor → distribution 0.1.0. |
| `research/claude-code.md` | Recherche source : hooks Claude Code (événements, formats de réponse), transcripts JSONL, registre de sessions, Keychain OAuth, endpoint `/api/oauth/usage` — avec hypothèses numérotées n°1–10. |
| `research/cursor.md` | Recherche source : hooks Cursor (`hooks.json`), schéma `state.vscdb` (`composerData`, `bubbleId`), transcripts, endpoints dashboard usage — hypothèses n°1–10. |
| `research/notch-ui.md` | Recherche source : recettes `NSPanel` non-activant, `NSScreen.notchSize`, `NotchShape`, code inspecté de boring.notch/NotchDrop/DynamicNotchKit, `NSStatusItem`/`NSPopover`. |
| `research/system-integration.md` | Recherche source : socket UNIX/IPC mesuré, libproc (scan de ports, identification de process), FSEvents, hotkeys Carbon, garde-fous de kill, notifications — hypothèses numérotées. |
| `research/distribution-licensing.md` | Recherche source : Developer ID/notarisation/staple, Sparkle 2, DMG, anti-rollback d'horloge (`mach_continuous_time`), Lemon Squeezy + Worker — hypothèses n°1–14. |

---

## 3. Conventions

- **Identifiants d'exigences** : `REQ-<DOMAINE>-NN`, uniques par fichier — VIS (vision, 00), CLA (Claude Code, 03), CUR (Cursor, 04), NUI (notch, 05), MBR (menu bar, 06), SES (sessions, 07), ACT (actions inline, 08), USG (usage, 09), SRV (serveurs, 10), QRF (Quick Routes/Fast Actions, 11), NOT (notifications, 12), SET (Settings/Doctor, 13), LIC (onboarding/licence/distribution, 14), TST (tests, 15). Références croisées sous la forme `fichier · REQ-XX-NN`.
- **Priorités** : **P0** = indispensable au MVP (parité v0.1.0) · **P1** = parité complète AgentPeek v0.2.11 · **P2** = raffinement/différé.
- **Statuts factuels** : **[VÉRIFIÉ]** = adossé à une doc officielle, une source primaire ou une inspection/mesure locale · **[HYPOTHÈSE — à valider]** = déduction à confirmer par un banc `scripts/experiments/` avant l'implémentation dépendante · **[TRANCHÉ produit]** = valeur choisie par nous quand AgentPeek ne documente pas la sienne (ajustable). Aucune hypothèse ne doit jamais être présentée comme un fait — ni dans le plan, ni dans l'UI.
- **Décisions d'architecture** : `A1`–`A11` (fichier 01 §10), fermes sauf mention « à calibrer ».
- **Tâches** : chaque fichier numérote ses tâches en §8 (ex. `T-CLA-E`, `N3`, `A5`, `U9`, `S10`) ; la roadmap (16) les référence telles quelles.
- **Langues** : documents du plan en français ; identifiants de code, API et textes d'interface en anglais (les textes UI canoniques sont fixés dans `00 · §4` et les §4 de chaque fichier).

---

## 4. Décisions d'architecture clés (rappel — détail dans `01-architecture.md` §10)

| # | Décision |
|---|---|
| A1 | Deux exécutables (app + `agentdash-hook` ~56 Ko) reliés par socket UNIX NDJSON, 1 connexion = 1 requête. |
| A2 | Binaire hook copié vers `~/.agentdash/bin/`, resynchronisé par hash à chaque lancement (= fonction « réparer »). |
| A3 | Hooks = source d'état **primaire** ; transcripts/DB = timeline, tokens, historique et fallback. |
| A4 | SwiftUI hébergé dans AppKit : `NSPanel` non-activant key-able pour le notch, `NSStatusItem` AppKit (pas de `MenuBarExtra`). |
| A5 | Swift 6 strict concurrency ; stores `@Observable` sur MainActor ; toute l'ingestion en actors. |
| A6 | macOS 14+, arm64 pur ; Liquid Glass via `agentGlass()` avec fallback `NSVisualEffectView` (macOS 26 non exigé). |
| A7 | Pas de sandbox ; hardened runtime + Developer ID + notarisation ; DMG + Sparkle (checks horaires). |
| A8 | Un projet Xcode + packages SPM locaux ; dépendances orientées `DashCore`, aucun import transverse (UI agnostique agent). |
| A9 | Budgets : RAM < 150 Mo, CPU idle < 0,5 %, hook → UI < 150 ms, démarrage < 1 s / 100 Mo ; auto-mesure vers Doctor. |
| A10 | **Fail-open absolu** : AgentDash ne peut jamais bloquer un agent ; santé par flux ; jauges qui retiennent la dernière valeur. |
| A11 | Licence : Lemon Squeezy + Worker Cloudflare + reçu Ed25519 vérifié offline ; trial 48 h anti-rollback ; le tout isolé derrière `LICENSING_ENABLED`. |

Principes transverses complémentaires : déduplication structurelle par `SessionID` (`02 · §1.1`) ; `waiting` uniquement sur signal explicite, jamais par timeout (`02 · §3.3`) ; fusion **non destructive** des configs tierces + sauvegardes `.bak` (`00 · REQ-VIS-16/17`) ; réseau limité à 4 destinations désactivables (`00 · REQ-VIS-12`) ; testabilité imposée dès le squelette (`DashPaths`, `ClockProvider`, `15 · REQ-TST-01..04`).

---

## 5. Hypothèses à valider (liste consolidée, avec jalon de validation)

Chaque ligne renvoie au banc `scripts/experiments/` correspondant ; « jalon » = moment où le banc doit être exécuté (spike d'ouverture du jalon, cf. `16-roadmap-milestones.md`). Les hypothèses **bloquantes** conditionnent la conception de la feature.

### Claude Code (`research/claude-code.md`, fichiers 03/08/09)

| Hypothèse | Fichiers | Jalon | Bloquante |
|---|---|---|---|
| n°1 — `PermissionRequest` en session interactive : le dialogue terminal attend-il le hook ? conflit terminal/notch (« prompt handling location ») | 03, 08 | **M2** | Oui — toute l'UX « Act » |
| n°2 — `AskUserQuestion` : `allow + updatedInput.answers` court-circuite-t-il le sélecteur terminal en interactif ? (fallback `deny + reason`) | 03, 08 | **M2** | Oui — REQ-CLA-44/REQ-ACT-21 |
| n°4 — Cycle de vie du registre `~/.claude/sessions/<pid>.json` (desktop visible dès le lancement, orphelins de crash) | 03, 07 | M1 | Non (dégradé : row retardée) |
| n°5 — Endpoint `/api/oauth/usage` : stabilité du schéma par plan, comportement 401, présence email/organisation (label de compte) | 03, 09 | M3 | Partielle (jauges `--` sinon) |
| n°7 — Resume multi-fichiers `.jsonl` (`--resume`/`--continue`) : fusion vers la même row | 03, 07 | M1 | Non |
| n°8 — Version plancher de Claude Code (features récentes : `PermissionRequest`, `updatedInput.answers`) | 03, 13 | M2 (plancher), M6 (check Doctor) | Non |
| Relecture Keychain sur 401 suffisante (jamais de refresh OAuth actif — risque de désync `refreshToken`) | 03, 09 | M3 | Non |
| Reformulation « honnête » des commandes shell : comportement exact d'AgentPeek inconnu (heuristique propre assumée) | 03, 08 | M2 | Non (produit) |

### Cursor (`research/cursor.md`, fichiers 04/09)

| Hypothèse | Fichiers | Jalon | Bloquante |
|---|---|---|---|
| n°1 — `conversation_id` (hooks) == `composerId` (DB) : clé de déduplication | 02, 04 | **M7** | Oui — dédup des sessions |
| n°2 — Plafond réel du `timeout` des hooks Cursor (600 s demandés) | 01, 04, 08 | **M7** | Oui — actionnabilité des permissions |
| n°3 — Aucune source fiable de tokens par tour (`tokenCount` ≈ 0) : chip de contexte à la place | 02, 04, 07, 09 | M7 | Non (promesse réduite actée) |
| n°4 — `ask_question`/`create_plan` actionnables via `preToolUse` ? (sinon affichage seul, aligné AgentPeek) | 04, 08 | M7 | Non (upgrade éventuel) |
| n°5 — Fiabilité dynamique de `hasBlockingPendingActions`/`generatingBubbleIds` pendant un tour réel | 02, 04 | **M7** | Oui — réconciliation d'état |
| n°6 — Sessions du CLI `cursor-agent` : backend `state.vscdb` partagé ? | 04 | M7 (P2) | Non |
| n°7 — Variantes de `usage-summary` par plan (free/pro/ultra/enterprise), comportement 401/403, nécessité des en-têtes anti-bot | 04, 09 | **M7** | Oui — jauge mensuelle |
| n°8 — Mapping Spend/Weighted/Auto/API ↔ champs `usage-summary` | 04, 09, 13 | **M7** | Oui — picker de mesure |
| n°10 — Schéma `composerData` `_v > 16` : dégradation propre | 04 | M7 | Non (Doctor) |
| Champ de feedback lu par l'agent : `user_message` vs `agent_message` (les deux renseignés en attendant) | 04, 08 | M7 | Non |
| Acceptation d'arguments dans `command` de `hooks.json` (repli : détection par la forme du stdin) | 04 | M7 | Non |
| Rechargement à chaud de `hooks.json` par Cursor (sinon « Restart Cursor if hooks don't fire ») | 04 | M7 | Non |

### Système & intégration (`research/system-integration.md`, fichiers 01/08/10)

| Hypothèse | Fichiers | Jalon | Bloquante |
|---|---|---|---|
| n°4 — **Gatekeeper/quarantaine sur le binaire hook copié hors bundle** (le « zéro config » en dépend ; plan B : hooks `type:"http"` Claude) | 01, 03, 13, 14 | M2 (1ᵉʳ passage), **M8 (verdict en build Developer ID)** | Oui |
| n°8 — Chargement initial > 1 s sur gros historiques → activer le snapshot d'offsets | 01, 02, 09 | M1/M3 | Non |
| `npm_config_user_agent` présent pour npm/yarn/bun (vérifié pnpm seulement) ; chaîne de parents des runners après `exec` | 10 | M4 | Non |
| Chaîne `ppid` pour ⌥T (reparentage possible des runners) | 08 | M2 | Non (fallback Terminal.app) |
| Consommation de ⌘A depuis un `NSPanel` non-activant (hotkeys Carbon en relais) | 05, 08 | M2 | Partielle |

### UI (fichiers 05/06/12/13)

| Hypothèse | Fichiers | Jalon | Bloquante |
|---|---|---|---|
| VoiceOver × `NSPanel` non-activant (plan B : activation temporaire de l'app) | 05 | **M0** | Partielle (accessibilité) |
| Niveau `.statusBar + 3` vs overlays système (Spotlight, Centre de notifications) | 05 | M0 | Non |
| Dimensions/wording exacts d'AgentPeek (largeurs, densités, textes, couleurs d'état) — calibrage sur captures publiques | 05, 06, 07, 12 | M0 → M6 (continu, `05 · N11`) | Non |
| Sémantiques « hide when idle » / « expanded only » du pill | 05, 13 | M6 | Non |
| `NSPopover` de status item : activation/vol de focus (plan B : `NSPanel` ancré) | 06 | **M5** | Oui — surface menu bar |
| Auto-dimensionnement `NSHostingView` dans le bouton de barre (`variableLength`) | 06 | M5 | Non |
| `performClick` programmatique pour ouvrir le popover (clic sur notification) | 06, 12 | M5 | Non |
| Deep link `x-apple.systempreferences` (panneau Notifications) sur macOS 14+ | 12, 13 | M5 | Non |
| Action de notification livrée à une app `LSUIElement` quittée | 12 | M5 | Non |
| Heuristique anti-faux-positif « stuck » au réveil de veille | 12 | M5 | Non |
| Sémantique exacte des 3 valeurs de « prompt handling location » (interprétation propre) | 08, 13 | M2 (définie), M6 (validée) | Non |
| Key equivalents ⌘W/⌘, sans barre de menus visible (`LSUIElement`) | 13 | M6 | Non |
| API delegate Sparkle pour mémoriser « pas de mise à jour trouvée » | 13, 14 | M8 | Non |

### Licence & distribution (`research/distribution-licensing.md`, fichier 14)

| Hypothèse | Fichiers | Jalon | Bloquante |
|---|---|---|---|
| n°1/n°18 — Format exact des clés Lemon Squeezy (UUID v4 attendu) | 14 | M8 | Non (champ tolérant) |
| n°3 — License API LS appelable sans clé API ? (la clé vit dans le Worker de toute façon) | 14 | M8 | Non |
| n°5 — Keychain silencieux entre builds Debug/Release et après réinstallation | 14 | M8 | Non (repli fichier) |
| n°9 — Prompt notifications/fenêtre au premier plan en `LSUIElement` sur macOS 26 | 12, 14 | M5/M8 | Non |
| n°11 — `stapler staple` après signature EdDSA : ordre de la chaîne ①–⑧ | 14 | **M8** | Oui — chaîne d'update |
| n°12 — Stabilité des URL d'assets GitHub pour `/download/latest` | 14 | M8 (P2) | Non |
| n°13 — Suppression manuelle d'instance dans le dashboard LS | 14 | M8 | Non |
| REQ-LIC-16 — En-tête HTTP `Date` comme high-water mark opportuniste | 14 | M8 (P2) | Non |

---

## 6. Points d'attention connus

- **Décision business ouverte** : distribution publique payante vs privée gratuite (`00 · T8/R8`) — à trancher avant le travail LicensingKit de M8 ; l'architecture est fermée quel que soit le choix (`14 · REQ-LIC-28`).
- **Nom définitif** : « AgentDash » est un nom de code ; le renommage (bundle id, tagline, marque) est la tâche `00 · T1`, à boucler avant toute distribution (risque juridique `00 · R6`).
