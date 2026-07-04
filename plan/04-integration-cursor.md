# 4. Intégration Cursor

> Spécification de l'intégration Cursor de bout en bout, rédigée le 3 juillet 2026. Module concerné : **AgentCursor** (SPM), consommé par `DashCore` via les protocoles `AgentProvider`, `UsageProvider`, `HooksInstaller`. Conforme à `plan/01-architecture.md` (IPC socket UNIX, hooks = source primaire, DB = réconciliation) et `plan/02-data-model.md` (transitions C1–C9, `SessionID`, `PromptCapabilities`).
> Sources : `plan/research/cursor.md` (hooks, `state.vscdb`, endpoints usage) et `plan/research/system-integration.md` (IPC, tail, garde-fous). Toute affirmation non vérifiée est marquée **[HYPOTHÈSE — à valider]** avec renvoi à la liste d'hypothèses de la recherche.

---

## 1. Objectif & périmètre

Reproduire pour Cursor l'intégralité de ce qu'AgentPeek offre depuis la v0.2.9–0.2.11, à savoir (sections d'`AGENTPEEK_FEATURES.md` couvertes) :

- **§2.1 Hooks** : installation, réparation et statut « Ready » de `~/.cursor/hooks.json` ; zéro configuration par session.
- **§3 Monitoring** : sessions Cursor dans la liste unifiée (états, activité récente, diffs, fichiers/commandes, timeline, subagents, environnement hôte, dédoublonnage, `/clear`-équivalents).
- **§4 Actions inline** : permissions Allow / Deny / Deny with feedback dans le notch via hooks bloquants ; questions et plans **affichés** (limites documentées en §2.3).
- **§5 Usage** : fenêtre **mensuelle** Cursor via le dashboard live (token de session local), mesures **Spend / Weighted / Auto / API**, affichage « $X of $Y », barres optionnelles Auto/Composer et API, sélection de compte, stats journalières locales.
- **§7 Quick Routes** (chemins `~/.cursor/*` — la mécanique générique est spécifiée ailleurs ; ce fichier fixe les chemins Cursor), **§10 Settings → Usage/Doctor** (parties Cursor), **§12 Privacy** (réseau `cursor.com` désactivable).

Hors périmètre de ce fichier : l'UI générique du notch/menu bar (fichier NotchUI), la machine à états commune (02), le protocole IPC (01), l'intégration Claude Code (03).

### 1.1 Parité Cursor vs Claude Code — ce qui n'est PAS possible (documenté, assumé)

| Capacité | Claude Code | Cursor | Conséquence produit |
|---|---|---|---|
| Always Allow (⌥A) | Oui (`permission_suggestions`) | **Non** — aucune sortie de hook ne crée de règle persistante [VÉRIFIÉ — doc] | `PromptCapabilities.canAlwaysAllow = false`, ⌥A inactif, bouton absent |
| Réponse inline aux questions | Oui (`updatedInput.answers`) | **Non promis** — `ask_question` observé en DB mais aucun hook documenté pour y répondre [HYPOTHÈSE cursor n°4] | `canAnswerInline = false` ; état `waiting(.question)` affiché + « Answer in Cursor » |
| Approve/Reject de plan | Oui (`ExitPlanMode`) | **Non promis** — `create_plan`/`hasPendingPlan` observés, pas de sortie « approve » documentée [HYPOTHÈSE cursor n°4] | `canApprovePlan = false` ; plan affiché en lecture seule |
| Tokens input/output live par tour | Oui (transcripts, dédup `requestId`) | **Non** — `tokenCount` des bulles ≈ toujours 0 [VÉRIFIÉ — local] | `TokenTally` absent ; la carte affiche `ContextUsage` (`contextTokensUsed/limit`) à la place |
| Kill de session | Oui (PID du registre) | **Non** — pas de PID par session (Cursor est un seul process app) | bouton Kill absent des rows Cursor |
| Fenêtres d'usage 5 h / 7 j | Oui | **Non applicable** — fenêtre **mensuelle** (cycle de facturation) | une seule jauge Cursor, `UsageWindowKind.monthly` |
| Permission à trois issues | allow / deny / always | allow / deny / **ask** (remise à l'UI Cursor) | `ask` = voie d'auto-libération propre |

---

## 2. Exigences détaillées

Priorités : **P0** = MVP, **P1** = confort/parité complète, **P2** = différé.

### 2.1 Installation & réparation des hooks (`~/.cursor/hooks.json`)

- **REQ-CUR-01 (P0)** — Si `~/.cursor/hooks.json` n'existe pas (cas de cette machine, VÉRIFIÉ), AgentDash le crée avec `{"version": 1, "hooks": {…}}` contenant exclusivement les entrées AgentDash, en une écriture atomique (fichier temporaire + `rename`).
- **REQ-CUR-02 (P0)** — Si le fichier existe, la fusion est **non destructive** : décodage en JSON générique (jamais une struct fermée), préservation de toute clé et de tout hook tiers inconnus, ajout/remplacement des seules entrées dont `command` contient le marqueur `/.agentdash/bin/agentdash-hook`. Une sauvegarde `~/.agentdash/backups/hooks.json.<ISO8601>.bak` est écrite avant la première modification.
- **REQ-CUR-03 (P0)** — Le jeu d'événements installé est exactement celui tranché en 01 §4.2 : `beforeSubmitPrompt`, `beforeShellExecution`, `beforeMCPExecution`, `afterShellExecution`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `afterFileEdit`, `afterAgentResponse`, `afterAgentThought`, `subagentStart`, `subagentStop`, `sessionStart`, `sessionEnd`, `stop`. Sont volontairement exclus (bruit/volume) : `beforeReadFile`, `afterMCPExecution`, `preCompact`, `beforeTabFileRead`, `afterTabFileEdit`, `workspaceOpen`.
- **REQ-CUR-04 (P0)** — Chaque entrée référence `command: "<home>/.agentdash/bin/agentdash-hook --source cursor"` (chemin absolu résolu, sans `~`). [HYPOTHÈSE — à valider : acceptation d'arguments dans `command` ; repli : détection de la source par la forme du stdin, `cursor_version` présent ⇒ Cursor.]
- **REQ-CUR-05 (P0)** — Les hooks de **décision** (`beforeShellExecution`, `beforeMCPExecution`) portent `"timeout": 600` ; les hooks de télémétrie `"timeout": 10`. `failClosed` n'est **jamais** posé à `true` (fail-open absolu). [HYPOTHÈSE cursor n°2 — plafond réel du timeout à mesurer.]
- **REQ-CUR-06 (P0)** — Le statut « Ready » (Settings → General → Agent hooks, ligne Cursor) est vrai ssi : (1) `~/.cursor/hooks.json` existe et se parse, (2) les 15 entrées AgentDash sont présentes et pointent vers le bon chemin, (3) `~/.agentdash/bin/agentdash-hook` existe, est exécutable et a le hash attendu, (4) le socket `agentdash.sock` est joignable. Chaque check en échec produit un item Doctor distinct.
- **REQ-CUR-07 (P0)** — Le toggle off (`cursorHooksEnabled = false`) retire **uniquement** les entrées AgentDash, préserve les hooks tiers, et supprime le fichier seulement s'il ne reste que `{"version": 1, "hooks": {}}` vide et qu'AgentDash l'avait créé.
- **REQ-CUR-08 (P0)** — À chaque lancement de l'app (et sur clic « Repair »), la séquence installation/réparation est rejouée de manière idempotente : deux exécutions successives produisent un fichier identique octet pour octet.
- **REQ-CUR-09 (P1)** — Si un `hooks.json` existant est un JSON invalide, AgentDash n'écrase **jamais** silencieusement : statut `damaged`, item Doctor « Cursor hooks file is invalid JSON » avec bouton « Back up & recreate » (sauvegarde `.bak` puis recréation) exigeant une confirmation explicite.
- **REQ-CUR-10 (P1)** — Doctor vérifie périodiquement (au plus toutes les 5 min et à chaque ouverture de l'onglet) que les entrées n'ont pas été écrasées (settings sync, édition manuelle) et signale « Needs repair ». La prise en compte à chaud par Cursor des modifications de `hooks.json` étant non documentée, Doctor affiche « Restart Cursor if hooks don't fire » tant qu'aucun événement n'a été reçu après installation. [HYPOTHÈSE — rechargement à chaud à valider.]

### 2.2 Mapping des événements et sessions (hooks + `state.vscdb`)

- **REQ-CUR-11 (P0)** — Tout événement de hook Cursor reçu par `HookServer` est normalisé : `SessionID(agent: .cursor, rawID: conversation_id)`, `projectPath = workspace_roots[0]` (repli `CURSOR_PROJECT_DIR`), `host = .ide(.cursor)`. L'égalité `conversation_id == composerId` est vérifiée au premier événement réel et journalisée. [HYPOTHÈSE cursor n°1.]
- **REQ-CUR-12 (P0)** — Les transitions C1–C9 de 02 §3.2 sont implémentées telles quelles ; aucun timeout ne fait entrer en `waiting` ; priorité `waiting > executing > thinking > idle`.
- **REQ-CUR-13 (P0)** — La liste des sessions Cursor est lue depuis `ItemTable.composer.composerHeaders.allComposers[]` (VÉRIFIÉ — local) : filtrage `isDraft`, `isArchived`, `isBestOfNSubcomposer` ; les entrées avec `subagentInfo` sont rattachées à `rootParentConversationId` comme `SubagentActivity`, jamais listées comme sessions racines.
- **REQ-CUR-14 (P0)** — `state.vscdb` est ouvert en **lecture seule directe** (`SQLITE_OPEN_READONLY`, WAL = lecteurs concurrents), requêtes ciblées par clé (jamais de scan des 122 k lignes de `cursorDiskKV`), retry borné sur `SQLITE_BUSY`, et **jamais** `immutable=1` sur la base vivante. Une **copie-instantané** (`state.vscdb` + `-wal` + `-shm` copiés dans le scratch AgentDash) n'est utilisée qu'en repli si l'ouverture RO échoue durablement (`SQLITE_READONLY_CANTINIT`/`SQLITE_CANTOPEN`, cf. §5).
- **REQ-CUR-15 (P0)** — Poll adaptatif de la DB : 1,5 s si ≥ 1 session Cursor non idle ou panel ouvert sur une session Cursor ; 10 s sinon ; 0 (arrêt) si Cursor n'est pas installé (`~/Library/Application Support/Cursor` absent). Chaque tick lit `composerHeaders` (1 ligne), diffe avec le snapshot précédent et n'interroge `composerData:<id>` que pour les sessions modifiées ou affichées.
- **REQ-CUR-16 (P0)** — Réconciliation d'état par la DB (source secondaire, fenêtre d'autorité des hooks 15 s — 02 §3.3) : `hasBlockingPendingActions == true` ⇒ `waiting(.permission)` ; `hasPendingPlan == true` ⇒ `waiting(.plan)` ; `status ∈ {completed, aborted}` ⇒ `idle` ; `generatingBubbleIds` non vide ou `toolFormerData.status == "loading"` frais ⇒ `executing`. [HYPOTHÈSE cursor n°5 — fiabilité dynamique de ces flags à corréler en live.]
- **REQ-CUR-17 (P0)** — Enrichissement des cartes depuis `composerHeaders`/`composerData` : `title = name`, `subtitle` (dernière activité en langage clair), `diff = totalLinesAdded/Removed`, `filesTouchedCount = filesChangedCount`, `contextUsage = contextTokensUsed/contextTokenLimit/contextUsagePercent`, `model = modelConfig.modelName`, `todos[]`, `gitBranch = trackedGitRepos[0].branches` la plus récente.
- **REQ-CUR-18 (P0)** — Décodage tolérant : champs inconnus ignorés, champs absents → valeurs neutres ; la version de schéma `_v` de `composerData` est lue et, si `> 16` (dernière validée), un item Doctor « Cursor schema newer than tested » apparaît sans interrompre l'ingestion. [VÉRIFIÉ `_v: 16` local ; hypothèse cursor n°10.]
- **REQ-CUR-19 (P0)** — Table de traduction des noms d'outils vers un `displayName` en langage clair, couvrant les deux espaces de noms : DB (`run_terminal_command_v2` → « Ran command », `read_file_v2` → « Read file », `edit_file_v2` → « Edited file », `ripgrep_raw_search`/`semantic_search_full`/`glob_file_search` → « Searched », `read_lints` → « Checked lints », `todo_write` → « Updated todos », `ask_question` → « Asked a question », `create_plan` → « Proposed a plan », `task_v2` → « Ran subagent », `delete_file` → « Deleted file », `switch_mode`, `await`, `mcp-<serveur>-<tool>` → « MCP: <serveur> <tool> ») et hooks (`Shell`, `Read`, `Write`, `Task`…). Nom inconnu → nom brut humanisé, jamais d'erreur.
- **REQ-CUR-20 (P1)** — Timeline historique (sessions antérieures au lancement d'AgentDash, scroll vers le haut) : jointure `composerData.fullConversationHeadersOnly[]` → `bubbleId:<composerId>:<bubbleId>` par plage de clés, paginée (jamais tout le fil en RAM ; fenêtre de 2 000 événements rendus — 01 §6). `conversationState` et les blobs `agentKv:`/`composer.content.` ne sont **jamais** chargés.
- **REQ-CUR-21 (P1)** — Les transcripts `~/.cursor/projects/<slug>/agent-transcripts/<composerId>/*.jsonl` (quand ils existent — pas systématiques, VÉRIFIÉ) sont surveillés par le même `TranscriptTailer` FSEvents que Claude : lignes `role: user|assistant` → timeline/extraits, ligne `turn_ended` → corroboration `idle`. Source **complémentaire**, jamais unique.
- **REQ-CUR-22 (P1)** — `subagentStart`/`subagentStop` alimentent `SubagentActivity` (type, tâche, durée, `modified_files`, compteurs) sur la session parente `parent_conversation_id`.
- **REQ-CUR-23 (P1)** — `afterAgentResponse.text` alimente `lastAssistantExcerpt` (rendu Markdown, replié « Show more/less ») ; `afterAgentThought` produit un événement `.thinking(durationMs:)`.
- **REQ-CUR-24 (P2)** — Titres/résumés de secours pour les sessions sans `name` : `conversation_summaries` de `~/.cursor/ai-tracking/ai-code-tracking.db` (lecture seule, mêmes règles que REQ-CUR-14).
- **REQ-CUR-25 (P2)** — Sessions du CLI `cursor-agent` : détectées si elles écrivent dans le même `state.vscdb`/`~/.cursor/projects` ; `host` alors distingué via `term_program` de l'enveloppe IPC. [HYPOTHÈSE cursor n°6 — backend partagé à confirmer, CLI non installé sur la machine de référence.]

### 2.3 Permissions inline (« Act »)

- **REQ-CUR-26 (P0)** — `beforeShellExecution` et `beforeMCPExecution` sont des événements **décision** : la connexion IPC reste ouverte, un `PendingPrompt(payload: .permission)` est créé (commande ou `tool_name`+`tool_input`, `cwd`, badge `sandbox`), la session passe `waiting(.permission)`, l'auto-expand du notch se déclenche si activé.
- **REQ-CUR-27 (P0)** — Décisions supportées et sérialisation exacte : **Allow** → `{"permission":"allow"}` ; **Deny** → `{"permission":"deny"}` ; **Deny with feedback** → `{"permission":"deny","agent_message":"<texte>"}` (le feedback revient à l'agent) [HYPOTHÈSE — champ exact `agent_message` vs `user_message` à valider sur un tour réel] ; **remise à Cursor** → `{"permission":"ask"}` (le dialogue natif de Cursor reprend la main).
- **REQ-CUR-28 (P0)** — `PromptCapabilities` pour Cursor : `canAlwaysAllow = false`, `canDenyWithFeedback = true`, `canAnswerInline = false`, `canApprovePlan = false`, `canHandInToTerminal = true` (réponse `ask`). ⌥A ne s'enregistre pas comme hotkey quand le prompt actif est Cursor.
- **REQ-CUR-29 (P0)** — Auto-libération : à `expiresAt = receivedAt + 600 s − 10 s` sans décision, l'app répond `{"permission":"ask"}` et marque le prompt `released` ; l'état reste `waiting` jusqu'au signal suivant (jamais de flip par timeout).
- **REQ-CUR-30 (P0)** — Si le réglage `promptHandling == .terminalOnly`, les hooks de décision Cursor répondent immédiatement `ask` (aucune interception) tout en émettant la télémétrie d'état. Condition symétrique de `05-notch-ui.md` : l'interception reste active pour `.notch` **et** `.both` (sémantique des trois valeurs : 13-settings REQ-SET-13).
- **REQ-CUR-31 (P1)** — Détection `preToolUse` avec `tool_name == ask_question` ou `create_plan` ⇒ `waiting(.question)`/`waiting(.plan)` **affiché seul** : carte non actionnable avec bouton « Answer in Cursor » (active l'app Cursor via `NSWorkspace`). Un banc d'essai (`scripts/experiments/cursor-question-probe`) tranche l'hypothèse n°4 avant toute promesse d'inline.
- **REQ-CUR-32 (P1)** — Une notification système `PERMISSION_REQUEST` est postée pour les permissions Cursor (mêmes réglages que Claude), avec actions Allow/Deny câblées sur le même chemin de décision.

### 2.4 Usage mensuel (dashboard live)

- **REQ-CUR-33 (P0)** — Le token est lu à la demande depuis `ItemTable.cursorAuth/accessToken` (JWT HS256, VÉRIFIÉ — local) ; `userId = sub.split("|")[1]` ; repli `~/Library/Application Support/Cursor/sentry/scope_v3.json` (`scope.user.id`, `scope.user.email`). Cookie construit : `WorkosCursorSessionToken=<userId>%3A%3A<jwt>` (VÉRIFIÉ — OSS).
- **REQ-CUR-34 (P0)** — Le token n'est **jamais** persisté par AgentDash, jamais journalisé, gardé en mémoire le temps de la requête, envoyé exclusivement vers `cursor.com` en HTTPS.
- **REQ-CUR-35 (P0)** — `GET https://cursor.com/api/usage-summary` toutes les 300 s (+ refresh manuel, anti-rafale 10 s) alimente `UsageWindow(kind: .monthly)` : `resetsAt = billingCycleEnd`, jauge selon la mesure choisie, `dollars = (used, limit)` en cents convertis. [VÉRIFIÉ — OSS pour la forme ; hypothèse cursor n°7 sur les variantes par plan.]
- **REQ-CUR-36 (P0)** — Les quatre mesures `CursorUsageMeasure` sont sélectionnables (Settings → Usage) avec le mapping : `spend` → `plan.used/limit` (cents) ; `weighted` → `plan.totalPercentUsed` ; `auto` → `plan.autoPercentUsed` ; `api` → `plan.apiPercentUsed`. Mapping entier [HYPOTHÈSE cursor n°8 — à confirmer sur réponses réelles] ; un champ absent ⇒ mesure masquée du picker avec note « Not available on this plan ».
- **REQ-CUR-37 (P0)** — Affichage « $X of $Y » : format `$12.07 of $20.00` ; si `isUnlimited == true` ou `limit` null ⇒ « **$X spent · Unlimited** » sans dénominateur et jauge remplacée par le texte seul (texte canonique : 09-token-usage REQ-USG-12).
- **REQ-CUR-38 (P0)** — Échec de refresh ⇒ **rétention de la dernière valeur** datée (`isStale = true`), jamais de régression silencieuse ; `--` uniquement si aucune valeur n'a jamais été obtenue. Changement de réglage (mesure, compte) ⇒ mise à jour immédiate de la jauge.
- **REQ-CUR-39 (P0)** — **Dégradation si non connecté** : clé `cursorAuth/accessToken` absente/vide ⇒ état `notSignedIn`, aucune requête réseau, jauge `--`, ligne Settings « Sign in to Cursor to enable usage » ; re-détection à chaque tick (lecture DB locale uniquement). Compte déconnecté en cours de route ⇒ retour à `notSignedIn` sans effacer la dernière valeur affichée.
- **REQ-CUR-40 (P0)** — Toggle `cursorUsageEnabled = false` ⇒ **zéro** octet vers `cursor.com` (contrat privacy §12) ; le poller n'est pas démarré.
- **REQ-CUR-41 (P1)** — Barres optionnelles de la vue détail du notch : « Auto » (`autoPercentUsed`, pool Auto + Composer) et « API » (`apiPercentUsed`), toggles `cursorShowAutoBar`/`cursorShowAPIBar`.
- **REQ-CUR-42 (P1)** — `POST /api/dashboard/get-aggregated-usage-events` (`{teamId: -1, startDate: billingCycleStart, endDate: now}`) fournit le détail par modèle (`aggregations[]`) et le coût agrégé ; utilisé pour la vue détail et les dollars/jour des stats journalières.
- **REQ-CUR-43 (P1)** — Stats jour par jour locales : `ItemTable.aiCodeTracking.dailyStats.v1.5.<YYYY-MM-DD>` (lignes suggérées/acceptées Tab et Composer, VÉRIFIÉ — local) fusionnées dans `DailyUsage` sans réseau.
- **REQ-CUR-44 (P1)** — Sélection de compte : chaque `userId` vu est mémorisé (`UsageAccount{id: userId, label: email, plan: stripeMembershipType}`) ; le picker (Settings → Usage) liste les comptes connus ; seul le compte actuellement connecté dans Cursor est rafraîchissable — un compte sélectionné mais non connecté fige sa jauge avec la note « Not signed in in Cursor ». Le `label` de compte apparaît sur les cartes de session Cursor.
- **REQ-CUR-45 (P1)** — Réponses 401/403 : re-lecture du token depuis la DB (l'utilisateur a pu se reconnecter) puis un seul retry ; échec persistant ⇒ `isStale` + « usage health notice » pointant vers Doctor. L'usage du `refreshToken` est **exclu en v1** (écriture/rotation de secrets tiers = hors périmètre). [HYPOTHÈSE cursor n°7 — comportement exact 401/403.]
- **REQ-CUR-46 (P1)** — En-têtes de requête : `User-Agent` Safari, `Origin: https://cursor.com`, `Referer: https://cursor.com/dashboard?tab=usage`, `Sec-Fetch-*` (recette OSS Raycast). [HYPOTHÈSE — nécessité réelle à valider ; requêtes fonctionnelles sans eux ⇒ les retirer.]

### 2.5 Robustesse, veille et version-pinning

- **REQ-CUR-47 (P0)** — Chaque sous-flux Cursor (hooks, DB, transcripts, usage) a son propre état de santé `healthy/degraded(reason)/unavailable` exposé dans `DoctorStore` ; la panne d'un flux n'éteint jamais les autres, et aucune erreur Cursor ne peut faire crasher l'app (tout parsing sous `do/catch` + décodage tolérant).
- **REQ-CUR-48 (P0)** — `CursorCompat` fige les versions validées : `minSupported` (à fixer, 3.x), `maxTested = "3.7.27"`, `schemaTested = 16`, `hooksAPIVersion = 1`. Au premier événement, `cursor_version` (stdin) est comparé : version > `maxTested` **et** une sonde en échec (décodage headers, clé auth, endpoint usage) ⇒ item Doctor « Cursor <v> is newer than tested (<maxTested>) — some features may degrade », sans désactivation préventive.
- **REQ-CUR-49 (P1)** — Les endpoints `cursor.com/api/*` étant **privés et non documentés officiellement**, le poller journalise (sans contenu) tout changement de forme (champ attendu manquant, code HTTP inattendu) et bascule la jauge en `isStale` avec « usage health notice » — jamais d'affichage de valeurs suspectes. Le legacy `GET /api/usage?user=` est conservé comme repli de dernier recours derrière un flag interne. [VÉRIFIÉ — OSS : AgentPeek a remplacé ce feed en v0.2.10.]
- **REQ-CUR-50 (P1)** — Chaque hypothèse cursor n°1–10 dispose d'un banc de validation dans `scripts/experiments/` (voir §8) exécuté **avant** l'implémentation de la feature dépendante ; le résultat est consigné dans ce fichier (mise à jour du statut [HYPOTHÈSE] → [VÉRIFIÉ]).

---

## 3. Conception technique

### 3.1 Vue d'ensemble du module `AgentCursor`

```
                         ┌────────────────────────── AgentCursor (SPM) ──────────────────────────┐
 hooks.json ◄────────────┤ CursorHooksInstaller (struct, conforme HooksInstaller)                │
                         │                                                                       │
 agentdash-hook ──socket─►(DashCore.HookServer) ─► CursorEventNormalizer ─► DashEvent ─► stores  │
                         │                                                                       │
 state.vscdb ────poll────┤ actor CursorStateReader  ─► [CursorSessionDelta] ─► SessionStore      │
 agent-transcripts ─FSE──┤ CursorTranscriptParser (via DashCore.TranscriptTailer)                │
 ai-code-tracking.db ────┤ CursorDailyStatsReader                                                │
 cursor.com ────HTTPS────┤ actor CursorUsagePoller (conforme UsageProvider) ─► UsageStore        │
                         └───────────────────────────────────────────────────────────────────────┘
```

### 3.2 Installeur de hooks

```swift
public struct CursorHooksInstaller: HooksInstaller {   // protocole DashCore exact (00 §3.2)
    let hooksFileURL: URL      // ~/.cursor/hooks.json
    let relayPath: String      // <home>/.agentdash/bin/agentdash-hook (absolu)

    public func status() async -> HooksStatus      // .ready / .notInstalled / .damaged(reason) / .agentMissing
    public func installOrRepair() async throws     // idempotent : create-or-merge + .bak à la 1re écriture
    public func uninstall() async throws           // retire uniquement les entrées marquées
}
// Pas d'enum Status locale : `HooksStatus` (00 §3.2) est la seule définition canonique.
// La granularité « entrées manquantes » (REQ-CUR-06/10) s'exprime via
// .damaged(reason: "missing entries: <liste>") — affiché « Needs repair » en Settings ;
// un JSON invalide (REQ-CUR-09) donne .damaged(reason: "invalid JSON").

/// Jeu d'événements et timeouts (REQ-CUR-03/05).
let decisionEvents: [String] = ["beforeShellExecution", "beforeMCPExecution"]
let telemetryEvents: [String] = ["beforeSubmitPrompt", "afterShellExecution", "preToolUse",
    "postToolUse", "postToolUseFailure", "afterFileEdit", "afterAgentResponse",
    "afterAgentThought", "subagentStart", "subagentStop", "sessionStart", "sessionEnd", "stop"]

func agentDashEntry(timeout: Int) -> [String: Any] {
    ["command": "\(relayPath) --source cursor", "timeout": timeout]   // jamais failClosed
}
```

Algorithme de fusion (REQ-CUR-02, pseudo-code) :

```
merge(hooks.json):
  root = parseJSON(file) ?? {"version": 1, "hooks": {}}          # invalide → status .damaged, STOP
  root["version"] = root["version"] ?? 1                          # jamais dégradé si supérieur
  for event in decisionEvents + telemetryEvents:
      entries = root.hooks[event] ?? []
      entries.removeAll { $0.command.contains("/.agentdash/bin/agentdash-hook") }   # nos anciennes
      entries.append(agentDashEntry(timeout: decisionEvents.contains(event) ? 600 : 10))
      root.hooks[event] = entries
  if firstWrite: copy(file → ~/.agentdash/backups/hooks.json.<ISO>.bak)
  atomicWrite(root → file)          # temp + rename, préservation de l'ordre des clés tierces
```

### 3.3 Normalisation des événements de hooks

`CursorEventNormalizer` (appelé par `EventRouter` quand `envelope.source == "cursor"`) mappe `hook_event_name` → effets. Classification et transitions (conformes 02 §3.2) :

| Événement | Classe | Effets (SessionStore / PromptStore / timeline) |
|---|---|---|
| `sessionStart` | télémétrie | C1 : créer/rafraîchir `Session` (id, projet, host) ; marqueur `.sessionMarker(started)` ; ignorer si `is_background_agent` |
| `beforeSubmitPrompt` | télémétrie | C2 → `thinking` ; `.userPrompt(excerpt: prompt)` |
| `preToolUse` | télémétrie | C3 → `executing` ; `ToolCallSummary(status: .running)` ; si `tool_name ∈ {ask_question, create_plan}` → C7 `waiting(.question/.plan)` affiché (REQ-CUR-31) |
| `postToolUse` / `postToolUseFailure` | télémétrie | C4 → `thinking` ; clôture du tool call (`succeeded`/`failed`, `duration`, `failure_type`) |
| `beforeShellExecution` | **décision** | C5 → `waiting(.permission)` ; `PendingPrompt` (commande, cwd, sandbox) ; connexion IPC gardée ouverte |
| `beforeMCPExecution` | **décision** | idem avec `tool_name`/`tool_input` |
| `afterShellExecution` | télémétrie | `commandCount += 1` ; timeline « Ran command » (+ durée) |
| `afterFileEdit` | télémétrie | `filesTouchedCount` (par `file_path` distinct) ; diff approximé par `edits[]` en attendant la DB |
| `afterAgentResponse` | télémétrie | `lastAssistantExcerpt` (Markdown) ; `.assistantText` |
| `afterAgentThought` | télémétrie | C4 ; `.thinking(durationMs: duration_ms)` |
| `subagentStart` / `subagentStop` | télémétrie | `SubagentActivity` sur `parent_conversation_id` (running → completed/failed, `modified_files`, compteurs) |
| `stop` | télémétrie | C8 → `idle` ; notification `TASK_COMPLETE` si `status == completed` ; jamais de `followup_message` en réponse |
| `sessionEnd` | télémétrie | C9 → `idle` + `liveness = .ended(reason mappée)` |

### 3.4 Lecteur `state.vscdb`

```swift
public actor CursorStateReader {
    public struct Paths: Sendable {
        var globalDB: URL      // ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
        var cursorHome: URL    // ~/.cursor
    }
    private var db: OpaquePointer?          // connexion RO persistante (réouverte sur erreur)
    private var headersSnapshot: [String: ComposerHeader] = [:]   // par composerId

    public func start(onDelta: @escaping @Sendable ([CursorSessionDelta]) async -> Void)
    public func setActivity(_ hasActiveSessions: Bool)            // ajuste 1,5 s ↔ 10 s
    public func timelinePage(for id: SessionID, beforeIndex: Int, limit: Int)
        async throws -> ([TimelineEvent], olderAvailable: Bool)   // REQ-CUR-20
    public func readAuthCredentials() throws -> CursorAuthCredentials?   // REQ-CUR-33
    public func readDailyStats(days: Int) throws -> [DailyUsage]         // REQ-CUR-43
}
```

Requêtes SQL (toutes indexées — les colonnes `key` sont `UNIQUE`) ; le `LIKE` est proscrit au profit d'une **plage** pour garantir l'usage de l'index :

```sql
-- Registre des sessions (1 ligne, ~centaines de Ko)
SELECT value FROM ItemTable WHERE key = 'composer.composerHeaders';
-- Détail d'une session
SELECT value FROM cursorDiskKV WHERE key = 'composerData:' || ?1;
-- Bulles d'une session (plage : ':' < ';' en binaire)
SELECT key, value FROM cursorDiskKV
 WHERE key > 'bubbleId:' || ?1 || ':' AND key < 'bubbleId:' || ?1 || ';'
 ORDER BY key;                       -- l'ordre d'affichage vient de fullConversationHeadersOnly
-- Auth et stats
SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';
SELECT key, value FROM ItemTable
 WHERE key > 'aiCodeTracking.dailyStats.v1.5.' AND key < 'aiCodeTracking.dailyStats.v1.5/';
```

Boucle de poll (REQ-CUR-15/16/17) :

```
tick():
  headers = decode(SELECT composer.composerHeaders)              # tolérant, _v inconnu ⇒ Doctor
  visibles = headers.allComposers.filter(!isDraft && !isArchived && !isBestOfNSubcomposer
                                          && subagentInfo == nil)
  deltas = []
  for h in visibles:
      prev = headersSnapshot[h.composerId]
      if prev == nil || h.lastUpdatedAt != prev.lastUpdatedAt || flagsChanged(h, prev):
          delta = CursorSessionDelta(from: h)                    # title, subtitle, diff, flags…
          if isDisplayedOrActive(h.composerId):                  # panel ouvert / session non idle
              delta.detail = decode(SELECT composerData:h.composerId)   # contexte, todos, model
          deltas.append(delta)
  headersSnapshot = index(visibles)
  if !deltas.isEmpty: await onDelta(deltas)                      # hop MainActor, coalescé 250 ms
  reschedule(active ? 1.5 s : 10 s)
```

Réconciliation avec la machine à états : le délai d'autorité des hooks (15 s) est appliqué **dans `SessionStore`**, pas dans le reader — le reader émet des faits bruts (`hasBlockingPendingActions`, `status`…), le store arbitre.

### 3.5 Flux de permission inline (séquence complète)

```
Cursor            agentdash-hook        HookServer         PromptStore/UI              Cursor UI
  │ beforeShell     │                      │                    │                          │
  │ Execution       │                      │                    │                          │
  ├─spawn──────────►│ stdin JSON           │                    │                          │
  │                 ├─connect+ligne───────►│                    │                          │
  │                 │   (connexion         ├─DashEvent─────────►│ waiting(.permission)     │
  │                 │    gardée ouverte)   │                    │ notch auto-expand        │
  │                 │                      │                    │ hotkeys ⌘A/⌘N (pas ⌥A)   │
  │                 │                      │                    │                          │
  │                 │                      │◄──decision─────────┤ ⌘A → allow               │
  │                 │◄─{"permission":…}────┤ (même connexion)   │ ⌘N → deny                │
  │◄─stdout─────────┤ exit 0               │                    │ « Deny with feedback »   │
  │ exécute/refuse  │                      │                    │   → deny+agent_message   │
  │                 │                      │                    │ timeout−10 s → "ask" ────┼─► dialogue
  │                 │                      │                    │                          │   natif
  App fermée : connect() → .waiting (ENOENT) → exit 0 SANS sortie → Cursor applique son prompt natif.
```

### 3.6 Poller d'usage

```swift
public struct CursorAuthCredentials: Sendable {
    let userId: String            // sub JWT après « | » ; repli sentry/scope_v3.json
    let email: String?            // cursorAuth/cachedEmail
    let membershipType: String?   // cursorAuth/stripeMembershipType
    let jwt: String               // JAMAIS persisté ni journalisé (REQ-CUR-34)
}

public actor CursorUsagePoller: UsageProvider {
    public func refresh(force: Bool) async -> CursorUsageSnapshot?   // anti-rafale 10 s si force
}

public struct CursorUsageSnapshot: Sendable {
    var account: UsageAccount
    var window: UsageWindow                    // .monthly ; dollars, subBars, resetsAt
    var perModel: [ModelUsageLine]             // aggregations[] (REQ-CUR-42)
    var raw: UsageSummaryDecoded               // conservé pour le picker de mesures
}

/// Décodage 100 % optionnel — aucune forme de réponse ne doit jeter (REQ-CUR-47/49).
struct UsageSummaryDecoded: Decodable, Sendable {
    var billingCycleStart: FlexibleDate?; var billingCycleEnd: FlexibleDate?
    var membershipType: String?; var isUnlimited: Bool?
    var individualUsage: Individual?
    struct Individual: Decodable, Sendable { var plan: Pool?; var onDemand: Pool? }
    struct Pool: Decodable, Sendable {
        var enabled: Bool?; var used: Double?; var limit: Double?; var remaining: Double?
        var autoPercentUsed: Double?; var apiPercentUsed: Double?; var totalPercentUsed: Double?
    }
}
// FlexibleDate : accepte ISO 8601 ou epoch millisecondes (string) — les deux observés en OSS.

func utilization(_ m: CursorUsageMeasure, _ s: UsageSummaryDecoded) -> Double? {
    guard let plan = s.individualUsage?.plan else { return nil }
    switch m {                                        // [HYPOTHÈSE cursor n°8]
    case .spend:    guard let u = plan.used, let l = plan.limit, l > 0 else { return nil }
                    return u / l * 100
    case .weighted: return plan.totalPercentUsed
    case .auto:     return plan.autoPercentUsed
    case .api:      return plan.apiPercentUsed
    }
}
```

Cycle d'un refresh : `readAuthCredentials()` (DB locale) → absent ⇒ `notSignedIn`, stop → `GET usage-summary` (cookie + en-têtes REQ-CUR-46) → décodage tolérant → jauge + « $X of $Y » → si détail requis, `POST get-aggregated-usage-events` → publication `UsageStore`. 401/403 ⇒ relecture du token + 1 retry ⇒ sinon `isStale` + health notice.

---

## 4. Spécification UX/UI (textes en anglais, comme AgentPeek)

### 4.1 Settings → General → Agent hooks (ligne Cursor)

- États : `Ready` (pastille verte) · `Not installed` (bouton **Install**) · `Needs repair` (bouton **Repair**, détail dans Doctor) · `Cursor not detected` (ligne grisée, lien « Get Cursor »).
- Sous-texte après installation sans événement reçu : `Waiting for first event — restart Cursor if hooks don't fire.`

### 4.2 Carte de session Cursor (row)

- Badge agent « Cursor » ; avatar pixel-grid commun ; états par couleur + mouvement (identiques aux autres agents).
- Métriques : diff `+A −R`, fichiers, commandes, **chip de contexte** à la place des tokens : `ctx 72%` (tooltip `217.2k of 300k context tokens`) — jamais de compteur input/output Cursor (REQ absence, §1.1).
- Pas de bouton **Kill** ; actions : ouvrir, **Copy Session as Markdown**, dismiss.
- Label de compte (email) si `cursorUsageEnabled` et compte connu.

### 4.3 Prompt de permission Cursor (notch)

- Titre : `Cursor wants to run:` + commande en monospace (ou `Cursor wants to call <tool>:` pour MCP) ; badge `sandboxed` si `sandbox == true`.
- Boutons : `Allow ⌘A` · `Deny ⌘N` · `Deny with feedback…` (champ texte inline) · `Handle in Cursor` (répond `ask`). **Pas** de `Always Allow` (⌥A inactif, non affiché).
- Compte à rebours discret quand `expiresAt − now < 60 s` : `Hands back to Cursor in 42s`.
- Question/plan détectés : carte informative `Cursor is waiting for you` + extrait, bouton unique `Answer in Cursor` / `Review in Cursor` (active l'app).

### 4.4 Usage (notch détail, pill mode usage, menu bar)

- Jauge batterie `Cursor · Monthly`, valeur selon la mesure ; ligne dollars : `$12.07 of $20.00` · reset : `Resets Aug 1` (format `Resets <MMM d>`, canonique : 09 REQ-USG-10) ; `isUnlimited` ⇒ `$12.07 spent · Unlimited` (canonique : 09 REQ-USG-12).
- Barres optionnelles sous la jauge : `Auto ▮▮▮▯ 62%` et `API ▮▯▯▯ 23%`.
- Indisponible : `--` ; échec de refresh : dernière valeur + point ambre (tooltip `Last updated 3:12 PM — refresh failed`) ; shimmer pendant refresh.
- Settings → Usage : toggle `Cursor usage` ; picker `Measure: Spend / Weighted / Auto / API` ; toggles `Show Auto/Composer bar`, `Show API bar` ; picker `Account` ; état déconnecté : `Sign in to Cursor to enable usage` (aucun bouton de login — la session vient du Mac).

---

## 5. Cas limites & gestion d'erreurs

1. **`~/.cursor` absent** (Cursor non installé) : provider inerte, aucune ligne Settings active, Quick Routes filtrées, zéro poll.
2. **`hooks.json` invalide** : jamais d'écrasement silencieux (REQ-CUR-09) ; statut `damaged` + réparation confirmée.
3. **Hooks écrasés** (sync, édition manuelle, autre outil) : re-check Doctor 5 min → `Needs repair` ; sessions continuent en lecture seule via la DB.
4. **Configs hooks de niveau supérieur** (Enterprise/Team/Projet, fusion prioritaire documentée) : peuvent neutraliser nos hooks utilisateur ⇒ symptôme « aucun événement reçu » → item Doctor dédié, jamais d'erreur.
5. **App AgentDash fermée/crashée** : `connect()` en `.waiting`/ENOENT ⇒ exit 0 silencieux, dialogue natif Cursor — l'utilisateur ne perd jamais la main (fail-open absolu).
6. **Timeout du hook de décision atteint côté Cursor** : auto-libération à −10 s avec `ask` ; si Cursor tue le hook avant (plafond réel inconnu, hypothèse n°2) le fail-open par défaut s'applique — comportement identique vu de l'utilisateur.
7. **Réponses contradictoires de plusieurs scripts de hooks** (hooks tiers sur le même événement) : comportement d'arbitrage de Cursor non documenté ⇒ ne jamais supposer la victoire d'AgentDash ; l'état est re-réconcilié par la DB dans les 2 s.
8. **`SQLITE_BUSY`** : retry ×3 avec backoff 50/150/400 ms puis abandon du tick (le suivant rattrape).
9. **Ouverture RO impossible durablement** (`SQLITE_READONLY_CANTINIT` sur WAL sans écrivain, `SQLITE_CANTOPEN`) : repli copie-instantané `db + -wal + -shm` dans le scratchpad puis lecture de la copie ; recopie au plus toutes les 10 s ; item Doctor `degraded`.
10. **DB de 1 Go** : jamais de scan complet ; uniquement les requêtes par clé/plage de §3.4 ; `conversationState` (~115 Ko/session) et blobs chiffrés jamais chargés.
11. **`composerHeaders` énorme ou corrompu** : taille > 20 Mo ou JSON invalide ⇒ tick abandonné + compteur d'échecs ; 3 échecs consécutifs ⇒ flux `degraded` (les hooks continuent de fournir l'état).
12. **Champs à présence partielle** (64/124 `lastUpdatedAt`, 86/124 `contextUsagePercent`…, VÉRIFIÉ) : tout champ optionnel a une valeur neutre ; tri de fraîcheur par `max(lastUpdatedAt, conversationCheckpointLastUpdatedAt, createdAt)`.
13. **`toolFormerData.status == "loading"` résiduel au repos** (5 occurrences observées) : filtré par fraîcheur (< 30 s) avant d'induire `executing`.
14. **`transcript_path` null ou dossier `agent-transcripts` absent** : source simplement ignorée (REQ-CUR-21 : jamais unique).
15. **Slug de projet ambigu** (`/` → `-`, collisions possibles) : le rattachement projet passe par `workspace_roots`/`workspaceIdentifier.uri.fsPath`, jamais par le slug.
16. **Non connecté / déconnexion en cours de route** : REQ-CUR-39 ; jamais de requête sans token ; dernière valeur conservée.
17. **JWT malformé ou `sub` sans `|`** : repli `sentry/scope_v3.json` ; sinon `notSignedIn` (pas d'erreur visible hors Settings).
18. **`membershipType` sans limite dollars** (`enterprise` de la machine de référence, `isUnlimited`) : affichage « $X spent · Unlimited », mesures en % masquées si champs absents (REQ-CUR-36/37).
19. **429 / 5xx / captcha anti-bot sur cursor.com** : `isStale` + backoff exponentiel (max 30 min) + « usage health notice » ; jamais de retry agressif.
20. **Horloge/cycle** : bascule de `billingCycleEnd` ⇒ reset de jauge au rollover (échéance armée à date exacte, réévaluée au réveil `didWakeNotification`).
21. **Deux fenêtres Cursor sur le même workspace** : même `state.vscdb` global, sessions distinctes par `composerId` — la déduplication structurelle par `SessionID` suffit.
22. **Événement de hook > 64 Ko** (gros `tool_input`) : framing NDJSON en boucle jusqu'au `\n`, plafond de sécurité 10 Mo/ligne.
23. **Montée de version Cursor** (schéma `_v` > 16, nouveau nom d'outil, endpoint modifié) : décodage tolérant + sondes + Doctor (REQ-CUR-18/48/49) — dégradation ciblée, jamais de crash ni de valeur fausse affichée.

---

## 6. Critères d'acceptation

1. **Installation vierge** — Given `~/.cursor` existe sans `hooks.json`, When j'active le toggle Cursor hooks, Then `~/.cursor/hooks.json` est créé avec `version: 1` et les 15 événements pointant vers `~/.agentdash/bin/agentdash-hook --source cursor`, et Settings affiche `Ready`.
2. **Fusion non destructive** — Given un `hooks.json` contenant un hook tiers sur `stop`, When AgentDash installe puis désinstalle ses hooks, Then le hook tiers est intact octet pour octet et un `.bak` horodaté existe dans `~/.agentdash/backups/`.
3. **Idempotence** — Given des hooks installés, When je relance l'app trois fois, Then `hooks.json` est identique après chaque lancement (hash inchangé).
4. **Session visible** — Given Cursor ouvert sur un projet, When je lance un tour d'agent, Then une row Cursor apparaît (≤ 150 ms après le premier hook), triée sous le bon projet, avec titre, état `thinking` puis `executing`, et chip de contexte — sans compteur de tokens input/output.
5. **Permission inline** — Given un tour qui déclenche une commande shell, When le prompt apparaît dans le notch et que je presse ⌘A, Then Cursor exécute la commande sans que je touche à sa fenêtre, et la timeline enregistre `granted(via: hotkey)` ; ⌥A ne produit aucun effet et n'est pas affiché.
6. **Deny with feedback** — Given le même prompt, When je choisis « Deny with feedback » avec un message, Then Cursor n'exécute pas la commande et l'agent reçoit le message (visible dans sa réponse suivante).
7. **Auto-libération** — Given un prompt Cursor ignoré, When `timeout − 10 s` est atteint, Then AgentDash répond `ask`, le dialogue natif de Cursor apparaît, et la row reste `waiting` jusqu'à ma décision dans Cursor.
8. **Fail-open** — Given AgentDash quitté, When Cursor déclenche `beforeShellExecution`, Then le prompt natif Cursor apparaît sans délai perceptible ni erreur dans le canal Hooks de Cursor.
9. **Sessions préexistantes** — Given trois conversations agent menées avant le premier lancement d'AgentDash, When je lance l'app, Then elles apparaissent (titre, diff, subtitle) via `composerHeaders`, sans hooks, avec timeline historique paginée au clic.
10. **Usage connecté** — Given un compte Cursor connecté dans l'app, When j'active `Cursor usage`, Then la jauge mensuelle affiche une valeur et « $X of $Y » (ou « $X spent · Unlimited » si illimité) avec la date de reset, en ≤ 10 s.
11. **Mesures** — Given la jauge affichée, When je change `Measure` de Weighted à Auto, Then la jauge se met à jour immédiatement sans nouvelle requête réseau (valeurs issues du même snapshot).
12. **Dégradation réseau** — Given une valeur d'usage affichée, When je coupe le réseau et force un refresh, Then la valeur précédente reste affichée avec indicateur stale, jamais `--` ni 0 %.
13. **Non connecté** — Given Cursor déconnecté (pas de `cursorAuth/accessToken`), When j'ouvre Settings → Usage, Then je lis `Sign in to Cursor to enable usage`, la jauge montre `--`, et aucune requête vers cursor.com n'est émise (vérifiable au proxy).
14. **Privacy** — Given `cursorUsageEnabled = false`, When j'utilise l'app une journée, Then zéro connexion sortante vers cursor.com (vérifiable au proxy), hooks et sessions fonctionnant normalement.
15. **Doctor** — Given des entrées AgentDash supprimées manuellement de `hooks.json`, When le re-check Doctor passe, Then la ligne Cursor affiche `Needs repair` et un clic sur Repair restaure exactement les entrées manquantes.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances** : `plan/01-architecture.md` (IPC, HookServer, jeu de hooks §4.2, budgets) ; `plan/02-data-model.md` (SessionID, transitions C1–C9, PendingPrompt/PromptCapabilities, UsageWindow/CursorUsageMeasure, invariants) ; fichier 03 (intégration Claude Code — parité des prompts et du EventRouter) ; fichiers NotchUI/MenuBarUI (rendu des cartes, jauges, prompts) ; fichier Usage/jauges (agrégation UsageKit, alertes de budget) ; fichier Doctor (checks REQ-CUR-06/10/47/48) ; fichier Settings (onglets General/Usage).

**Risques et mitigations** :

| # | Risque | Gravité | Mitigation |
|---|---|---|---|
| R1 | **Endpoints dashboard privés** (`cursor.com/api/*`) : rupture sans préavis, anti-bot, zone grise ToS | Élevée | décodage 100 % optionnel, sondes + health notice + rétention (REQ-CUR-38/49), repli legacy `/api/usage`, opt-out réseau ; releases correctives installées par remplacement manuel de l'app (modèle one-shot) ; documenter dans la FAQ que l'usage Cursor est « best effort » |
| R2 | **Schéma `state.vscdb` non contractuel** (`_v: 16` observé, migrations passées avérées workspace → global) | Élevée | requêtes par clé uniquement, tolérance aux champs inconnus, `CursorCompat` + Doctor (REQ-CUR-18/48), fixtures de test par version de schéma |
| R3 | Hooks de décision : timeout par défaut inconnu, arbitrage multi-scripts non documenté | Moyenne | timeout explicite 600 s + auto-libération `ask` ; banc d'essai dédié avant MVP (hypothèse n°2) |
| R4 | `conversation_id ≠ composerId` (casserait la déduplication) | Moyenne | vérification au premier événement réel + corrélation par `workspace_roots`+fraîcheur en secours (hypothèse n°1) |
| R5 | Questions/plans finalement actionnables (ou pas) via `preToolUse` | Faible (produit) | promesse minimale (affichage seul) alignée AgentPeek ; upgrade si le banc n°4 est positif |
| R6 | Verrouillage/lecture WAL de la DB de 1 Go pendant une écriture lourde de Cursor | Moyenne | RO + retry + repli copie-instantané (§5.9) ; jamais `immutable=1` |
| R7 | JWT très longue durée lisible dans la DB : manipulation d'un secret sensible | Moyenne | lecture à la demande, zéro persistance/log, envoi exclusif à cursor.com (REQ-CUR-34) |
| R8 | Divergence des mesures Spend/Weighted/Auto/API selon les plans (free/pro/ultra/business/enterprise) | Moyenne | mesures masquées si champ absent (REQ-CUR-36), tests sur plusieurs comptes réels avant release |

**Stratégie de veille / version-pinning** : (1) `CursorCompat` versionné dans le code, mis à jour à chaque validation manuelle d'une nouvelle version de Cursor ; (2) surveillance hebdomadaire du changelog Cursor et de la page docs hooks (la doc hooks est officielle et versionnée — les hooks sont la surface la plus stable ; la DB et les endpoints sont les plus fragiles) ; (3) les sondes runtime (REQ-CUR-48/49) transforment toute rupture en item Doctor explicite au lieu d'un bug silencieux ; (4) aucun kill-switch distant (zéro télémétrie) — la réponse à une rupture est une release corrective installée par remplacement manuel de l'app (modèle one-shot, décision du 3 juillet 2026).

---

## 8. Découpage en tâches

| # | Tâche | Contenu | Taille |
|---|---|---|---|
| T1 | Bancs d'hypothèses Cursor | `scripts/experiments/` : n°1 (`conversation_id`==`composerId`), n°2 (timeout hooks + blocage long), n°4 (`preToolUse` sur `ask_question`/`create_plan`), n°5 (fraîcheur DB pendant un tour), n°7-8 (réponses réelles `usage-summary` par plan) | **M** |
| T2 | `CursorHooksInstaller` | create/merge/uninstall idempotents, `.bak`, statut 4 checks, tests sur fixtures (fichier absent, tiers, invalide, ré-entrée) | **M** |
| T3 | `CursorEventNormalizer` | mapping §3.3 complet vers `DashEvent`, classification décision/télémétrie, tests unitaires par événement | **M** |
| T4 | Pont de permissions | PendingPrompt Cursor, sérialisation allow/deny/feedback/ask, auto-libération, capacités réduites, intégration hotkeys (⌥A exclu) | **M** |
| T5 | `CursorStateReader` — cœur | ouverture RO + retry + repli copie, décodage `composerHeaders`, boucle de poll adaptative, deltas vers SessionStore, fixtures `state.vscdb` générées (`_v: 16`) | **L** |
| T6 | `CursorStateReader` — détail | `composerData` (contexte, todos, diffs, model), timeline historique paginée `bubbleId:`, table de traduction des outils, réconciliation d'état | **L** |
| T7 | Transcripts Cursor | parseur `agent-transcripts/*.jsonl` branché sur `TranscriptTailer`, corroboration `turn_ended` | **S** |
| T8 | `CursorUsagePoller` | credentials (JWT/sentry), cookie, `usage-summary` + `get-aggregated-usage-events`, mapping 4 mesures, « $X of $Y », rétention/stale, 401/403, opt-out | **L** |
| T9 | Stats journalières & comptes | `aiCodeTracking.dailyStats`, `conversation_summaries` (P2), `UsageAccount` + picker + label sur cartes | **M** |
| T10 | UX Cursor | textes/états §4 dans NotchUI/SettingsKit (chip contexte, prompt sans ⌥A, cartes question/plan, jauge mensuelle + barres) | **M** |
| T11 | Doctor Cursor | checks hooks/DB/usage/version (`CursorCompat`), items et actions guidées (Repair, Back up & recreate) | **M** |
| T12 | Tests d'intégration bout en bout | scénarios §6 scriptés en checklist + fixtures multi-versions ; passe manuelle sur machine avec Cursor 3.7.x connecté | **L** |

Ordre recommandé : T1 → T2/T3 (parallèles) → T4 + T5 → T6/T7/T8 (parallèles) → T9/T10/T11 → T12. Chemin critique MVP (P0) : T1, T2, T3, T4, T5, T8, T11 (checks P0), T12 partiel.
