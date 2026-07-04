# 03. Intégration Claude Code

> Rédigé le 3 juillet 2026, en stricte conformité avec `plan/01-architecture.md` (modules, IPC, threading, budgets) et `plan/02-data-model.md` (types du domaine). Sources : `plan/research/claude-code.md`, `plan/research/system-integration.md`, et inspection locale de `~/.claude` (registre `sessions/1542.json`, transcript réel `0f8ddc9b-….jsonl`, CLI `claude` 2.1.89 dans le PATH, sessions récentes en 2.1.199).
> Convention : **[VÉRIFIÉ]** = fait établi (doc officielle ou inspection locale) ; **[HYPOTHÈSE — à valider]** = déduction à confirmer en implémentation. Aucune hypothèse n'est présentée comme un fait. Les identifiants de code et noms d'API restent en anglais ; l'interface reproduit les textes anglais d'AgentPeek.

---

## 1. Objectif & périmètre

Ce document spécifie de bout en bout l'intégration **Claude Code** : le module SPM `AgentClaude` (installeur/réparateur de hooks, parseur de transcripts, registre de sessions, lecture Keychain, poller d'usage), sa contribution au binaire `agentdash-hook` (cible `HookRelay`) et au `HookServer`/`EventRouter` de `DashCore`, ainsi que les flux « Watch », « Act » et « Usage » côté Claude Code. Cursor est traité dans `04-integration-cursor.md` ; ici, seul Claude Code.

Sections d'`AGENTPEEK_FEATURES.md` couvertes :
- **§2.1** (système de hooks : installation, réparation, statut « Ready », `~/.claude/settings.json`, `~/.claude/projects`) ;
- **§3.1–3.3** (liste des sessions triées par projet, carte de session, session étendue, timeline, subagents, Kill, Copy as Markdown, dédoublonnage, desktop vs terminal, `/clear`) ;
- **§4.1–4.3** (permissions inline ⌘A/⌘N/⌥A/⌥T, Deny with feedback, plans Approve/Reject, questions) ;
- **§5.1–5.2** (usage 5 h/7 j Claude via `/usage`, jauges batterie, stats journalières, rétention de la dernière valeur, reset au rollover) — la logique commune de jauges vit dans `UsageKit` ; ici, la **source de données** Claude ;
- **§7** (Quick Routes Claude : `~/.claude/{skills,plugins,settings.json,projects}`, `~/.claude`) — la mécanique `NSWorkspace` est dans `11-quick-routes-fast-actions.md` ; ici, uniquement les chemins et leur existence ;
- **§14.1, §14.4, §14.5, §14.6** (périmètre du clone côté Claude Code).

Hors périmètre de ce fichier : rendu UI du notch (`05-notch-ui.md`), logique générique des jauges (`09-token-usage.md`), scan de ports (`10-local-servers.md`).

---

## 2. Exigences détaillées

Priorités : **P0** = MVP (v0.1.0 équivalent), **P1** = complétude, **P2** = confort.

### 2.1 Installation / réparation / désinstallation des hooks

- **REQ-CLA-01** (P0) — Au premier lancement (toggle `claudeHooksEnabled` actif) et à **chaque** démarrage de l'app, `HooksInstaller.installOrRepair()` doit garantir que `~/.claude/settings.json` contient le jeu de hooks d'AgentDash de §4.2 de `01-architecture.md`, en **fusionnant** sans jamais écraser les clés existantes (`permissions`, `model`, `language`, etc. — [VÉRIFIÉ localement : ces clés existent, aucun `hooks`]). Opération **idempotente** : deux appels consécutifs produisent un fichier identique octet pour octet (hors réordonnancement stable).
- **REQ-CLA-02** (P0) — La fusion doit **préserver les hooks tiers** de l'utilisateur : pour chaque événement (`PreToolUse`, `PermissionRequest`, …), les entrées existantes non-AgentDash sont conservées ; seules les entrées portant le marqueur AgentDash (commande `~/.agentdash/bin/agentdash-hook`) sont ajoutées/mises à jour/retirées.
- **REQ-CLA-03** (P0) — Avant la **première** écriture, créer une sauvegarde `~/.agentdash/backups/settings.json.<ISO8601>.bak` [VÉRIFIÉ conception, cf. `02-data-model.md` §8]. L'écriture est **atomique** (fichier temporaire + `rename`) pour ne jamais laisser un `settings.json` tronqué que le file watcher de Claude Code lirait à mi-écriture.
- **REQ-CLA-04** (P0) — Après écriture, le statut par outil affiché dans **Settings → General → Agent hooks** doit passer à **« Ready »** ssi les 4 checks Doctor sont au vert (binaire présent + hash attendu, entrée présente dans `settings.json`, socket joignable, version d'agent supportée). Le même toggle **installe ET répare** (comportement AgentPeek v0.1.1, §2.1).
- **REQ-CLA-05** (P1) — Désinstallation (toggle off) : retrait des **seules** entrées marquées AgentDash ; si un tableau d'événement devient vide, retirer la clé de l'événement ; si `hooks` devient vide, retirer la clé `hooks`. Aucune autre modification.
- **REQ-CLA-06** (P1) — Détecter à chaud qu'un tiers a écrasé nos hooks via l'événement `ConfigChange` (matcher `user_settings`) [VÉRIFIÉ doc] **et** par un re-check périodique du Doctor ; si l'installation n'est plus intacte, afficher une bannière « Install hooks » (cf. `01-architecture.md` §7.2).
- **REQ-CLA-07** (P2) — Le file watcher de Claude Code recharge `settings.json` à chaud : documenter que les sessions ouvertes récupèrent les hooks **sans redémarrage** [VÉRIFIÉ doc] — c'est le « zéro configuration » ; l'app n'a rien à signaler à l'agent.
- **REQ-CLA-08** (P1) — Si `~/.claude` est absent, Claude Code n'est **pas détecté** : carte « Not detected » dans Settings, aucune tentative d'écriture, Quick Routes Claude masquées.

### 2.2 Binaire HookRelay et protocole IPC

- **REQ-CLA-10** (P0) — La commande inscrite dans `settings.json` est `~/.agentdash/bin/agentdash-hook --source claude` (chemin absolu court, sans espace ni quoting [VÉRIFIÉ system-integration §4.4]). Le binaire est **copié** vers `~/.agentdash/bin/` et resynchronisé par comparaison de hash à chaque lancement (= « réparer »).
- **REQ-CLA-11** (P0) — `agentdash-hook` lit **tout** stdin (l'événement JSON de Claude Code, ligne pouvant dépasser 64 Ko [VÉRIFIÉ : ligne max observée 70 007 octets]), l'enveloppe (`HookEnvelope` §3.2), se connecte au socket, envoie une ligne NDJSON, attend au plus une réponse, l'écrit **telle quelle** sur stdout, `exit 0`.
- **REQ-CLA-12** (P0, **fail-open absolu**) — Si le socket est absent (`connect()` en `.waiting`/`ENOENT` [VÉRIFIÉ]), refusé, ou si la réponse tarde au-delà du deadline, ou si le JSON est invalide : `exit 0` **sans rien écrire sur stdout** → Claude Code applique son comportement natif (prompt dans le terminal). **Jamais** d'`exit ≠ 0` sur erreur interne (un code d'erreur pourrait bloquer l'outil côté agent).
- **REQ-CLA-13** (P0) — Classification des événements par l'`EventRouter` [VÉRIFIÉ §4.1 de `01-architecture.md`] :
  - **Décision** (connexion gardée ouverte jusqu'à la réponse) : `PermissionRequest` (matcher `*`), `PreToolUse` matcher `AskUserQuestion|ExitPlanMode`. Deadline hook côté relais = **595 s** (`hookDecisionTimeoutSeconds` 600 s configuré dans `settings.json`, moins 5 s de marge) ; l'auto-libération app à **590 s** (REQ-CLA-46, `expiresAt` du `PendingPrompt`) intervient donc toujours avant. **Invariant** : deadline relais > `expiresAt` du `PendingPrompt` (590 s) et < timeout du hook côté agent (600 s) — le relais ne fait que survivre à l'attente, c'est l'app qui libère.
  - **Télémétrie** (réponse vide immédiate, fire-and-forget) : tout le reste.
- **REQ-CLA-14** (P0) — Latence hook → UI < 150 ms hors décision humaine [VÉRIFIÉ chaîne ≈ 25 ms : spawn 2,7 ms + IPC 0,65 ms + hop MainActor + 1 frame]. L'app ne doit jamais bloquer une session : un hook AgentDash lent retarde la fusion Claude Code (tous les hooks matchés s'exécutent en parallèle, résultats fusionnés après que tous ont fini [VÉRIFIÉ doc]) → réactivité soignée sur les hooks télémétrie.

### 2.3 Tail et parsing des transcripts JSONL

- **REQ-CLA-20** (P0) — Surveiller `~/.claude/projects/**/*.jsonl` par FSEvents récursif (latence 0,3 s [VÉRIFIÉ]) ; lecture **incrémentale par offsets** avec buffer de ligne partielle (`TranscriptTailer` de `DashCore`). Filtrer strictement le suffixe `.jsonl` (ignorer les temporaires `.sb-*` d'écriture atomique [VÉRIFIÉ]). Ne jamais raisonner sur les flags FSEvents ; toujours `stat()` + relire.
- **REQ-CLA-21** (P0) — Parser tolérant : `JSONDecoder` **ligne à ligne**, une ligne illisible ou d'un `type` inconnu est **ignorée sans erreur** (tolérance aux versions ; formats `summary`/`system`/`progress` d'anciennes versions non observés localement [HYPOTHÈSE — à valider]). Types observés localement [VÉRIFIÉ] : `user`, `assistant`, `attachment`, `ai-title`, `last-prompt`, `queue-operation`, `file-history-snapshot`, plus `pr-link` (doc).
- **REQ-CLA-22** (P0) — Mapper chaque bloc `tool_use` d'une entrée `assistant` vers un `ToolCallSummary`, apparié à son `tool_result` (entrée `user` liée) par `tool_use_id`. Résumé en langage clair (« Ran `git status` », « Edited Session.swift (+12/−3) »). Ne **jamais** conserver l'input complet ni les gros `tool_result` en RAM (résumés seulement, budget §6).
- **REQ-CLA-23** (P0) — Dériver `DiffStats` des `structuredPatch` des résultats `Edit|Write` [VÉRIFIÉ] ; `filesTouchedCount` = `tool_use` distincts `Edit|Write|NotebookEdit` par `file_path` ; `commandCount` = `tool_use` `Bash` [VÉRIFIÉ].
- **REQ-CLA-24** (P0) — Tokens par session, **split input/output**, mis à jour **mid-turn** [VÉRIFIÉ] : sommer `message.usage` des entrées `assistant` en **dédupliquant par `requestId`** (garder la dernière entrée du même `requestId` — streaming cumulatif 2 à 10 entrées/requête). Inclure `cache_read_input_tokens` + `cache_creation_input_tokens` dans les totaux de consommation (piège de sous-comptage ×100 [VÉRIFIÉ]). Affichage type « 24.6k / 66 ».
- **REQ-CLA-25** (P1) — Remonter l'activité des **subagents** : transcripts `<session>/subagents/agent-<id>.jsonl` dont **toutes** les entrées portent `isSidechain: true` [VÉRIFIÉ localement : le dossier compagnon existe]. Un subagent n'est **jamais** une session racine ; il est agrégé dans la timeline et la liste `subagents` de la session parente.
- **REQ-CLA-26** (P1) — Extraits de réponse assistant : concaténer les blocs `text` des entrées `assistant` du dernier tour, rendre en `AttributedString(markdown:)`, exposer un repli « Show more / Show less ».
- **REQ-CLA-27** (P1) — Titre de session = dernière entrée `ai-title` [VÉRIFIÉ] ; sous-titre = dernier `TimelineEvent` résumé, avec `last-prompt` en secours. `gitBranch`, `model` (dernier `message.model`), `permission_mode` alimentés depuis les entrées.
- **REQ-CLA-28** (P0) — Au lancement : parse complet des `.jsonl` de `mtime < 48 h`, `offset = taille` pour les plus anciens (recalcul instantané à 2 Mo [VÉRIFIÉ]) ; troncature/réécriture (`size < offset`) → relire depuis 0. Cap de sécurité : ligne > 10 Mo abandonnée.

### 2.4 Détection d'état de session (machine à états)

- **REQ-CLA-30** (P0) — Implémenter exactement les transitions T1–T16 de `02-data-model.md` §3.1, source **primaire = hooks**. `waiting` uniquement sur signal explicite (`PermissionRequest`, `PreToolUse` sur `AskUserQuestion`/`ExitPlanMode`), **jamais** par timeout (un `Bash` de 10 min reste `executing`).
- **REQ-CLA-31** (P0) — Fallback sans hooks (sessions antérieures à l'installation, hooks désactivés) via le transcript uniquement : `executing` (tool_use non apparié + écritures FSEvents < 5 s), `thinking` (dernière entrée `assistant` `stop_reason: null`), `idle` (`stop_reason: end_turn` + pas d'écriture depuis `idleFallbackSeconds` = 10 s). `waiting` **non inféré** (les transcripts ne marquent pas fiablement la demande de permission [VÉRIFIÉ]).
- **REQ-CLA-32** (P0) — Réconciliation hook/fallback : le hook fait autorité pendant `hookAuthorityWindow` (15 s) après son dernier événement ; au-delà, le fallback peut corriger (perte d'événement).
- **REQ-CLA-33** (P1) — `isStale` (flag séparé, ne change **pas** `state`) : `executing`/`thinking` sans événement depuis `stuckThresholdSeconds` (120 s) → notification « stuck-session » ; se résout au prochain événement.
- **REQ-CLA-34** (P1) — `StopFailure` (matcher `rate_limit`, `overloaded`, `billing_error`, `authentication_failed`…) → `idle` + badge d'erreur + alerte limites/session bloquée [VÉRIFIÉ doc].

### 2.5 Flux « Act » — permissions, plans, questions

- **REQ-CLA-40** (P0) — À réception d'un `PermissionRequest`, créer un `PendingPrompt.permission(PermissionRequest)` (≤ 1 prompt actionnable par session), passer la session en `waiting(.permission)`, auto-expand du notch si `autoExpandOnAttention`, poster une notification `PERMISSION_REQUEST` avec actions Allow/Deny.
- **REQ-CLA-41** (P0) — **Allow (⌘A)** → répondre `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` [VÉRIFIÉ doc]. **Deny (⌘N)** → `decision:{"behavior":"deny"}`. **Deny with feedback** → `deny` + `"message":"<texte utilisateur>"` (transmis à Claude) [VÉRIFIÉ doc].
- **REQ-CLA-42** (P0) — **Always Allow (⌥A, Claude uniquement)** → `behavior:"allow"` + `updatedPermissions:[<une des permission_suggestions reçues, renvoyée telle quelle>]` [VÉRIFIÉ doc : « équivalent au choix "always allow" du dialogue »]. Le bouton n'est présent que si `permission_suggestions` est non vide (`PromptCapabilities.canAlwaysAllow`).
- **REQ-CLA-43** (P0) — **Plans (`ExitPlanMode`)** via `PermissionRequest` matcher `ExitPlanMode` : afficher `tool_input.plan` (Markdown, titre H1 stylisé) et `allowedPrompts[]`. **Approve** → `decision:{"behavior":"allow"}`, option `updatedPermissions:[{"type":"setMode","mode":"acceptEdits","destination":"session"}]` [VÉRIFIÉ doc]. **Reject** → `deny` + `message` (feedback) ; Claude reste en plan mode [VÉRIFIÉ doc]. Boutons **Approve / Reject** (pas Allow/Deny).
- **REQ-CLA-44** (P1) — **Questions (`AskUserQuestion`)** via `PreToolUse` : afficher `tool_input.questions[]` (1 à 4, chacune `{question, header, options[], multiSelect}`). Réponse → `permissionDecision:"allow"` **plus** `updatedInput` contenant le tableau `questions` d'origine **et** un objet `answers` mappant le texte de chaque question au(x) label(s) choisi(s) (multiSelect : labels joints par virgules) [VÉRIFIÉ doc]. Un `allow` seul ne suffit pas. ⚠️ La doc ne garantit ce mécanisme qu'en mode `-p` : en interactif, `allow + updatedInput.answers` doit court-circuiter le sélecteur terminal [HYPOTHÈSE — à valider en priorité] ; fallback : `deny` + réponse dans `permissionDecisionReason` (Claude lit et s'adapte).
- **REQ-CLA-45** (P0) — **⌥T Open Terminal** → ouvrir le terminal hôte au `cwd` de la session (via `TERM_PROGRAM` hérité par le hook [VÉRIFIÉ]) ; mécanique d'ouverture (`NSWorkspace`, algorithme §3.5) dans `08-actions-inline.md` (REQ-ACT-30).
- **REQ-CLA-46** (P0) — **Auto-libération** : à `expiresAt = receivedAt + hookDecisionTimeout − promptAutoReleaseMargin` (600 − 10 s), ou sur action « Hand in to terminal », répondre **corps vide** → Claude Code affiche son dialogue natif. L'état reste `waiting` jusqu'au signal suivant (T12). Enregistrer un `PermissionOutcome(.released)`.
- **REQ-CLA-47** (P1) — Prompts « honnêtes » : reformuler `displayTitle` pour les commandes shell qui écrivent des fichiers (analyse locale de `tool_input.command` : redirections `>`/`>>`, `rm`, `mv`, `tee`…) [HYPOTHÈSE produit]. Fallback : description brute de `tool_input`.
- **REQ-CLA-48** (P0) — `PermissionRequest` **ne se déclenche pas en mode `-p`** [VÉRIFIÉ doc] : dans ce cas, seul `PreToolUse` s'applique ; documenter que les prompts inline ciblent les sessions interactives.
- **REQ-CLA-49** (P1) — Les règles `deny`/`ask` des settings restent prioritaires sur un `allow` de hook ; un `deny` d'un hook tiers concurrent gagne sur notre `allow` (précédence `deny > defer > ask > allow` [VÉRIFIÉ doc]). L'UI ne promet donc jamais que « Allow » forcera l'exécution.

### 2.6 Always-Allow — où et comment persister

- **REQ-CLA-50** (P0) — Le choix « Always Allow » n'est **pas** persisté par AgentDash : il est délégué à Claude Code en renvoyant une entrée de `permission_suggestions` dans `updatedPermissions`. La **destination** (`session` / `localSettings` / `projectSettings` / `userSettings`) est celle portée par la suggestion reçue [VÉRIFIÉ]. AgentDash n'écrit **jamais** lui-même dans les fichiers de règles de permission.
- **REQ-CLA-51** (P1) — Enregistrer localement (timeline, mémoire) qu'un « Always Allow » a été émis pour audit UX ; ne pas dupliquer la règle côté AgentDash.

### 2.7 Usage 5 h / 7 jours

- **REQ-CLA-60** (P0) — Source primaire : `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version détectée>` (impératif : sans lui, 429 persistants [VÉRIFIÉ sources]). `accessToken` lu dans le Keychain (item generic password, service `Claude Code-credentials`, account = user macOS [VÉRIFIÉ localement]).
- **REQ-CLA-61** (P0) — Mapper la réponse vers des `UsageWindow` : `five_hour` → `.fiveHour`, `seven_day` → `.sevenDay`, `seven_day_opus`/`seven_day_sonnet` → variantes ; `utilization` (0–100), `resets_at` (ISO 8601 UTC) → « resets in… » (5 h) et « refills Sun at 3:47 PM » (7 j). Polling toutes les **180 s** (rate limit par token [VÉRIFIÉ]) + refresh manuel anti-rafale 10 s.
- **REQ-CLA-62** (P0) — En cas d'échec (401, 429, réseau), **retenir la dernière valeur** avec `isStale = true` (comportement AgentPeek §5.2) ; afficher `--` uniquement si aucune valeur n'a jamais été obtenue. Sur 401 : **relire le Keychain** (Claude Code rafraîchit le token lui-même, `mdat` observé bouge [VÉRIFIÉ]) plutôt qu'implémenter le refresh OAuth (risque de désync du `refreshToken` [HYPOTHÈSE — à valider]).
- **REQ-CLA-63** (P1) — Reset automatique des jauges quand la fenêtre 5 h/7 j bascule (échéance armée à `resets_at`, cf. `01-architecture.md` §5.2).
- **REQ-CLA-64** (P1) — Fallback local (stats journalières §14.6, AgentPeek v0.2.6) : parser tous les `~/.claude/projects/**/*.jsonl`, entrées `assistant` avec `usage`, **dédup `requestId`**, prix par modèle (table LiteLLM) → `DailyUsage` (tokens, coût/jour) [VÉRIFIÉ ccusage]. Non autoritaire (l'endpoint OAuth reste la vérité serveur multi-appareils).
- **REQ-CLA-65** (P2) — Label de compte : extrait du JSON OAuth (email/organisation) si présent [HYPOTHÈSE — à valider] → `UsageAccount.label` affiché sur la carte de session (§3.2).
- **REQ-CLA-66** (P2) — Lecture Keychain refusée (invite déclinée) → usage Claude indisponible (jauges `--`), bouton « Retry » dans Settings → Usage ; tout le reste fonctionne (dégradation par flux).

### 2.8 Desktop vs terminal, cycle de vie

- **REQ-CLA-70** (P1) — Déterminer `SessionHost` via `entrypoint` : `claude-vscode` → `.ide(.vscode/.cursor)` [VÉRIFIÉ localement], `claude-desktop-3p` → `.desktopApp` [VÉRIFIÉ issue GitHub], terminal pur → `.terminal(program)` via `TERM_PROGRAM` du hook (valeur `cli` d'`entrypoint` [HYPOTHÈSE — à valider, aucune session terminal pure locale]).
- **REQ-CLA-71** (P1) — Sessions desktop visibles **dès le lancement** sans attendre d'activité : via le registre `~/.claude/sessions/<pid>.json` + `SessionStart` [HYPOTHÈSE — à valider]. Le fichier registre donne `sessionId`, `cwd`, `startedAt`, `version`, `kind`, `entrypoint`, `pid` [VÉRIFIÉ : `1542.json` inspecté].
- **REQ-CLA-72** (P0) — Déduplication : clé = `SessionID(agent: .claudeCode, rawID: sessionId)`. Un fichier registre n'est pris que si le PID est vivant (`kill(pid,0)`) et `pbi_start_tvsec` cohérent avec `startedAt` (fichiers orphelins de crash possibles [HYPOTHÈSE]). Deux fichiers PID de même `sessionId` (resume ailleurs) → un seul `Session`, `pid` = le plus récent.
- **REQ-CLA-73** (P0) — **`/clear`** : `SessionEnd(reason: clear)` puis `SessionStart(source: clear)` avec **nouveau** `sessionId` [VÉRIFIÉ] → l'ancienne row passe `liveness = .ended(.cleared)` mais **reste listée** (§3.1), chaînée à la nouvelle (`clearedFrom`), devient dismissable.
- **REQ-CLA-74** (P1) — **Resume** : `SessionStart(source: resume)` ; même `sessionId` → même `Session`, état et timeline conservés (« une session relancée en cours de tour ne perd pas son dernier tour »). Marqueur timeline `.sessionMarker(resumed)`. Resume multi-fichiers `.jsonl` [HYPOTHÈSE — à valider].
- **REQ-CLA-75** (P1) — **Compaction** : hooks `PreCompact`/`PostCompact` (avec `compact_summary`) et `SessionStart(source: compact)` → marqueur timeline `.compaction(auto:)` [VÉRIFIÉ doc].
- **REQ-CLA-76** (P0) — **Sessions mortes** : `SessionEnd` (exit/logout) ou PID disparu du registre → `liveness = .ended(.exited)`, row conservée, compteurs figés ; GC après `sessionRetentionHours` (24 h) si `.ended` (§7 data-model).
- **REQ-CLA-77** (P1) — **Kill** (Claude uniquement, PID connu) : re-validation `(pid, start_time, execPath)` puis `SIGTERM` → 3 s → `SIGKILL` [VÉRIFIÉ D5] → `.ended(.killed)` + marqueur.
- **REQ-CLA-78** (P1) — **Copy Session as Markdown** : rendu du transcript (prompts, réponses, tool calls résumés, timeline) en Markdown ; menu contextuel de la row.
- **REQ-CLA-79** (P2) — **Dismiss** : « sessions terminal silencieuses dismissables » → `isDismissed = true`, masquée, données conservées jusqu'à expiration.

---

## 3. Conception technique

### 3.1 `HooksInstaller` — fusion JSON sûre

Signature normative = `00-vision-scope.md` §3.2 (`status()` / `installOrRepair()` / `uninstall()`, `HooksStatus.ready/.notInstalled/.agentMissing/.damaged(reason: String)`) ; ce fichier n'en définit que l'**implémentation** Claude Code. Une installation altérée (entrées manquantes ou écrasées par un tiers) est signalée par `.damaged(reason:)`, la liste des entrées manquantes étant portée par `reason` (ex. « 3 of 12 hook entries are missing », cf. `13-settings.md` REQ-SET-52).

```swift
public protocol HooksInstaller: Sendable {          // DashCore (protocole, cf. 00 §3.2), AgentClaude (impl)
    func status() async -> HooksStatus               // .ready / .notInstalled / .damaged(reason) / .agentMissing
    func installOrRepair() async throws              // installe + répare (idempotent)
    func uninstall() async throws                     // retire les seules entrées AgentDash
}

struct ClaudeHooksInstaller: HooksInstaller {
    let settingsURL: URL        // ~/.claude/settings.json
    let hookCommand: String     // "~/.agentdash/bin/agentdash-hook --source claude" (chemin résolu)
    let marker = "agentdash"    // reconnaissance de NOS entrées

    func installOrRepair() async throws {
        let root = try readJSONObject(settingsURL) ?? [:]          // tolérant : fichier absent = {}
        try backupOnce(settingsURL)                                 // .bak horodaté, une fois
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for spec in Self.desiredHooks {                             // cf. 01-architecture.md §4.2
            var arr = (hooks[spec.event] as? [[String: Any]]) ?? []
            arr.removeAll { isOurEntry($0) && matches($0, spec) }   // purge nos anciennes variantes
            if !arr.contains(where: { isOurEntry($0) && matches($0, spec) }) {
                arr.append(spec.jsonEntry(command: hookCommand))
            }
            hooks[spec.event] = arr
        }
        var out = root; out["hooks"] = hooks
        try writeAtomically(out, to: settingsURL)                   // temp + rename
    }
}

struct HookSpec { let event: String; let matcher: String?; let timeout: Int }
// isOurEntry : au moins un handler dont "command" contient "/.agentdash/bin/agentdash-hook".
```

Points clés : lecture tolérante (fichier absent → `{}`), préservation de toute clé racine et de tout hook tiers, purge idempotente de nos variantes obsolètes avant réinsertion, écriture atomique. La désinstallation applique la purge sans réinsertion et nettoie les clés vides.

### 3.2 Protocole IPC (enveloppe et décision)

```swift
struct HookEnvelope: Codable, Sendable {   // hook → app (1 ligne NDJSON, \n final)
    let v: Int                      // 1
    let id: String                  // uuid (logs)
    let source: String              // "claude"
    let term_program: String?       // ENV hérité → SessionHost.terminal [VÉRIFIÉ]
    let ppid: Int32                 // PID de l'agent
    let event: JSONValue            // stdin brut de Claude Code, non modifié
}
// app → hook : corps écrit TEL QUEL sur stdout. Ex. {"hookSpecificOutput":{…}} ; vide = "pas d'avis".
```

Le `HookRelay` (cible `agentdash-hook`) ne partage aucun code avec l'app (duplication assumée du framing NDJSON, §3.2 architecture). Flux nominal du binaire :

```
lire stdin → envelopper → connect(socket)
  ├─ .waiting / ENOENT / refus  → exit 0 (vide)                 [app fermée : fail-open]
  └─ connecté → envoyer ligne
        ├─ événement décision  → attendre réponse (deadline 595 s, cf. REQ-CLA-13)
        │      ├─ réponse       → stdout(réponse) ; exit 0
        │      └─ deadline/EOF  → exit 0 (vide)
        └─ télémétrie          → send fire-and-forget (deadline 500 ms) ; exit 0 (vide)
```

### 3.3 `EventRouter` — normalisation et dispatch (extrait)

```swift
@MainActor func route(_ env: HookEnvelope, reply: @escaping (Data) -> Void) {
    guard let name = env.event["hook_event_name"]?.stringValue,
          let sid = claudeSessionID(env) else { reply(Data()); return }   // pas d'avis
    switch name {
    case "UserPromptSubmit":  sessions.apply(sid, .userPrompt);            reply(Data())   // T2
    case "PreToolUse":
        let tool = env.event["tool_name"]?.stringValue
        if tool == "AskUserQuestion" { prompts.openQuestion(sid, env, reply) }             // T6
        else if tool == "ExitPlanMode" { prompts.openPlan(sid, env, reply) }               // secours
        else { sessions.apply(sid, .toolStart(tool)); reply(Data()) }                      // T3
    case "PermissionRequest":
        let tool = env.event["tool_name"]?.stringValue
        if tool == "ExitPlanMode" { prompts.openPlan(sid, env, reply) }                     // T7
        else { prompts.openPermission(sid, env, reply) }                                    // T5
    case "PostToolUse", "PostToolUseFailure":
                              sessions.apply(sid, .toolEnd(env)); reply(Data())             // T4
    case "Stop":              sessions.apply(sid, .stop(env)); reply(Data())                // T13
    case "StopFailure":       sessions.apply(sid, .stopFailure(env)); reply(Data())         // T14
    case "Notification":      sessions.apply(sid, .notification(env)); reply(Data())        // T5/T16
    case "SessionStart":      sessions.apply(sid, .start(env)); reply(Data())               // T1
    case "SessionEnd":        sessions.apply(sid, .end(env)); reply(Data())                 // T15
    case "SubagentStart", "SubagentStop": sessions.apply(sid, .subagent(env)); reply(Data())
    case "PreCompact", "PostCompact":     sessions.apply(sid, .compaction(env)); reply(Data())
    case "CwdChanged":        sessions.apply(sid, .cwd(env)); reply(Data())
    case "ConfigChange":      doctor.noteConfigChange(env); reply(Data())
    default:                  reply(Data())      // événement inconnu : pas d'avis
    }
}
```

Les cas « décision » gardent la closure `reply` : `PromptStore` la conserve dans le `PendingPrompt` et la rappelle avec le corps JSON quand l'utilisateur tranche (ou avec `Data()` à l'auto-libération).

Note : l'événement `PostToolBatch` existe dans la doc [VÉRIFIÉ] mais n'est **pas** installé dans le jeu de hooks tranché par `01-architecture.md` §4.2 (seuls `PostToolUse` et `PostToolUseFailure` le sont) ; s'il arrivait malgré tout, il tomberait dans le `default` (pas d'avis, no-op).

### 3.4 Séquence « Act » (permission) complète

```
Claude Code                agentdash-hook            HookServer/EventRouter        PromptStore/NotchUI
   │ dialogue permission        │                          │                              │
   │── spawn hook (stdin JSON) ─►│                          │                              │
   │                            │── connect + ligne ───────►│ route(PermissionRequest)     │
   │                            │   (connexion ouverte)     │── openPermission ───────────►│ waiting(.permission)
   │                            │                           │                              │  auto-expand + notif
   │                            │                           │        ⌘A / ⌘N / ⌥A / feedback│◄─ décision utilisateur
   │                            │◄── réponse JSON (reply) ───│◄─────────────────────────────│
   │◄── stdout: {"…decision…"} ─│ exit 0                    │                              │
   │  applique allow/deny/perm  │                           │                              │
```

Auto-libération (T12) : à `expiresAt`, `PromptStore` appelle `reply(Data())` → le hook sort vide → Claude affiche son dialogue natif ; la session reste `waiting`. App fermée : le hook ne se connecte jamais → `exit 0` vide → dialogue natif immédiat.

### 3.5 Réponses JSON par action (référence exacte)

| Action | Corps renvoyé au hook |
|---|---|
| Allow | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| Deny | `…"decision":{"behavior":"deny"}}}` |
| Deny with feedback | `…"decision":{"behavior":"deny","message":"<feedback>"}}}` |
| Always Allow | `…"decision":{"behavior":"allow","updatedPermissions":[<permission_suggestion écho>]}}}` |
| Approve plan | `…"decision":{"behavior":"allow"}}}` (+ `updatedPermissions:[{"type":"setMode","mode":"acceptEdits","destination":"session"}]` si option) |
| Reject plan | `…"decision":{"behavior":"deny","message":"<feedback>"}}}` |
| Answer question | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[…],"answers":{"<question>":"<label(s)>"}}}}` |
| Hand in to terminal / auto-release | corps vide |

### 3.6 `TranscriptIngestor` — parsing et agrégation

```swift
actor TranscriptIngestor {                      // cf. 01-architecture.md §5.1
    private var requestIdUsage: [String: Usage] = [:]   // dédup : dernière entrée par requestId
    func ingest(line: Data, path: String) -> SessionDelta? { … }
}
```

Règles : entrée `assistant` → mettre à jour `requestIdUsage[requestId]` (écrase la précédente, cumulatif) ; recalculer `TokenTally` = somme des valeurs. Bloc `tool_use` → `ToolCallSummary(status: .running)` ; entrée `user` avec `tool_result` → apparier par `tool_use_id`, statut `succeeded`/`failed` (`is_error`), `DiffStats` depuis `structuredPatch`. Publication par **lots** (1 `SessionDelta` par tick de 250–300 ms), jamais 1 par ligne. Fenêtre timeline plafonnée à 2 000 événements en RAM (`TimelineWindow`), le reste relu à la demande.

### 3.7 Poller d'usage Claude

```swift
actor ClaudeUsagePoller {
    func fetch() async -> Result<[UsageWindow], UsageError> {
        guard let token = try? Keychain.readClaudeOAuthAccessToken() else { return .failure(.noCredentials) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/\(detectedCLIVersion)", forHTTPHeaderField: "User-Agent")
        // 401 → invalider le cache token, relire Keychain une fois, retry ; 429/réseau → .retryLater (retenir).
    }
}
```

Détection de version CLI : lire `version` du registre `~/.claude/sessions/<pid>.json` ou `claude --version` (2.1.89 local [VÉRIFIÉ]) ; défaut prudent si absent.

---

## 4. Spécification UX/UI (surfaces propres à Claude Code)

Le rendu détaillé (dimensions, animations, Liquid Glass) est dans `05-notch-ui.md`. Ici, les **textes exacts** (anglais) et **états** spécifiques Claude Code.

### 4.1 Settings → General → Agent hooks
- Ligne « Claude Code » avec pastille d'état et libellé : **Ready** (vert), **Not installed** (gris + bouton « Install hooks »), **Needs repair** (orange, hooks écrasés + bouton « Repair »), **Not detected** (`~/.claude` absent).
- Toggle unique « Enable Claude Code hooks » (installe **et** répare).

### 4.2 Prompt de permission (notch)
- Titre : reformulation honnête (REQ-CLA-47) ou nom d'outil + résumé d'input.
- Boutons : **Allow** (⌘A), **Deny** (⌘N), **Always Allow** (⌥A, seulement si `canAlwaysAllow`), **Open Terminal** (⌥T), lien **Deny with feedback**.
- Sous-texte discret : chemin/projet (`projectName`), compte (`accountLabel`).

### 4.3 Carte de plan (`ExitPlanMode`)
- Titre H1 du plan stylisé ; corps Markdown replié « Show more/less ».
- Boutons : **Approve** / **Reject** (pas Allow/Deny). Option (case) : « Auto-accept edits » → `setMode acceptEdits`. Reject ouvre un champ feedback.

### 4.4 Carte de question (`AskUserQuestion`)
- 1 à 4 questions successives ; chaque question affiche son `header`, son `text` et ses `options` (boutons radio ; cases si `multiSelect`). Champs documentés du `tool_input` : `question`, `header`, `options[].label`, `multiSelect` **uniquement** [VÉRIFIÉ doc]. Champ texte libre affiché seulement si le payload réel expose une option de réponse libre [HYPOTHÈSE — à valider par T-CLA-X0 : aucun champ `allowsFreeText` n'est documenté dans `tool_input.questions[]` ; le champ `allowsFreeText` du modèle (`02-data-model.md`) est alimenté à `false` par défaut tant que le banc d'essai n'a pas confirmé l'existence et le nom exact du champ dans le JSON réel].
- Bouton **Submit** ; **Answer in terminal** rend la main (corps vide).

### 4.5 Carte de session (données Claude)
- Avatar pixel-grid animé (executing = vague diagonale, waiting = rotation calme).
- Tokens « input / output » live (« 24.6k / 66 »), compteurs fichiers/commandes, `DiffStats` (+X/−Y), host (terminal vs desktop), temps écoulé, `accountLabel`.
- Menu contextuel : **Copy Session as Markdown** ; actions row : **Kill**, **Refresh usage**.

### 4.6 Jauges d'usage (source Claude)
- 5 h : « resets in 2h 14m » ; 7 j : « refills Sun at 3:47 PM ». `--` si jamais obtenu ; teinte figée + « usage health notice » si `isStale`.

---

## 5. Cas limites & gestion d'erreurs

1. **`settings.json` corrompu** (JSON invalide préexistant) → ne pas écraser ; Doctor signale « Cannot parse settings.json », propose d'ouvrir le fichier ; aucune fusion tant que non résolu.
2. **`settings.json` en lecture seule / permissions** → échec d'écriture attrapé, `.bak` conservé, bannière « Cannot write hooks ».
3. **Course avec le file watcher** : écriture atomique (temp + `rename`) garantit qu'aucune lecture ne voit un fichier partiel.
4. **Hooks tiers concurrents** : un `deny` tiers gagne sur notre `allow` [VÉRIFIÉ] → ne jamais présenter « Allow » comme garantie d'exécution.
5. **Version d'agent trop ancienne** (locale 2.1.89 ; `PermissionRequest`/`updatedInput.answers` exigent des versions récentes) → désactiver individuellement les features concernées, Doctor affiche la version plancher [HYPOTHÈSE — plancher à fixer].
6. **`-p` non interactif** : `PermissionRequest` ne tire pas → seul `PreToolUse` s'applique ; prompts inline sans effet (documenté).
7. **Ligne de transcript géante** (> 10 Mo, base64) → abandon de la ligne, poursuite du tail.
8. **Fichier registre orphelin** (crash) → PID mort → ignoré (croisement `kill(pid,0)` + `pbi_start_tvsec`).
9. **Réutilisation de PID** avant Kill → re-validation `(pid, start_time, execPath)` échoue → Kill annulé (garde-fou D5).
10. **Keychain refusé / token expiré** → jauges retiennent/`--`, relecture Keychain sur 401, jamais de refresh OAuth actif.
11. **429 endpoint usage** → backoff, retenir la dernière valeur, badge health notice.
12. **Streaming cumulatif** : sans dédup `requestId`, les tokens seraient surcomptés ×(2..10) → dédup obligatoire avant le store.
13. **App tuée pendant un prompt en attente** → connexion coupée → Claude retombe sur son dialogue natif ; `PendingPrompt` relâché.
14. **`/clear` répété** : chaînage `clearedFrom` en cascade ; la row la plus récente prend la place visuelle, les anciennes restent dismissables.
15. **Transcript sans `ai-title`** → titre = `projectName` + court hash de session ; sous-titre = `last-prompt`.
16. **Types de transcript inconnus** (`summary`/`system`/`progress` d'anciennes versions) → ignorés sans erreur.

---

## 6. Critères d'acceptation (Given/When/Then)

- **AC-01 (REQ-CLA-01/02)** — *Given* un `~/.claude/settings.json` contenant `permissions` et des hooks tiers, *When* `installOrRepair()` s'exécute, *Then* le fichier contient nos entrées **et** les clés/hooks préexistants intacts, et un second `installOrRepair()` ne change plus rien (idempotence, diff vide).
- **AC-02 (REQ-CLA-04)** — *Given* hooks fusionnés + binaire copié + socket ouvert + version supportée, *When* Settings → General s'affiche, *Then* la ligne Claude Code montre « Ready ».
- **AC-03 (REQ-CLA-12)** — *Given* AgentDash fermé, *When* Claude Code déclenche un `PermissionRequest`, *Then* le hook sort en `exit 0` sans stdout et le dialogue natif du terminal apparaît (l'utilisateur garde la main).
- **AC-04 (REQ-CLA-41/42)** — *Given* un prompt de permission dans le notch avec `permission_suggestions`, *When* l'utilisateur presse ⌥A, *Then* la réponse contient `behavior:"allow"` + `updatedPermissions:[<suggestion>]` et Claude Code enregistre la règle à la destination indiquée (le prochain appel identique ne redemande plus).
- **AC-05 (REQ-CLA-43)** — *Given* un `ExitPlanMode`, *When* l'utilisateur clique Reject avec un feedback, *Then* Claude reste en plan mode et le feedback apparaît dans sa réponse suivante.
- **AC-06 (REQ-CLA-44)** — *Given* un `AskUserQuestion` (2 options, `multiSelect:false`), *When* l'utilisateur choisit une option et Submit, *Then* la réponse est `allow` + `updatedInput` avec `questions` d'origine et `answers` mappant la question au label, et l'agent poursuit sans afficher le sélecteur terminal (à valider — sinon fallback `deny+reason`).
- **AC-07 (REQ-CLA-24)** — *Given* un tour Claude en streaming, *When* les entrées `assistant` du même `requestId` sont ingérées, *Then* `TokenTally` compte ce `requestId` une seule fois (dernière valeur) et s'incrémente mid-turn.
- **AC-08 (REQ-CLA-30/33)** — *Given* un `Bash` qui tourne 3 min, *When* aucun autre événement n'arrive, *Then* la session reste `executing` (jamais `waiting`) et `isStale` passe à `true` à 120 s (notification stuck), sans changer `state`.
- **AC-09 (REQ-CLA-73)** — *Given* une session listée, *When* l'utilisateur tape `/clear`, *Then* la row d'origine reste visible en `.ended(.cleared)` et une nouvelle row chaînée apparaît (la session n'est pas retirée).
- **AC-10 (REQ-CLA-60/62)** — *Given* un token OAuth valide, *When* le poller interroge `/api/oauth/usage` avec `User-Agent: claude-code/…`, *Then* les jauges 5 h/7 j affichent `utilization` et `resets_at` ; sur un 401 suivant, l'app relit le Keychain et retente sans afficher `--` (rétention de la dernière valeur).
- **AC-11 (REQ-CLA-25)** — *Given* une session avec subagents (`isSidechain:true`), *When* la session étendue s'ouvre, *Then* l'activité subagent apparaît dans la timeline de la session parente et **aucune** row séparée n'est créée.
- **AC-12 (REQ-CLA-77)** — *Given* une session Claude avec PID connu, *When* l'utilisateur clique Kill après confirmation, *Then* la re-validation `(pid, start_time, execPath)` passe, `SIGTERM` puis `SIGKILL` sont émis, et la row passe `.ended(.killed)`.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances :**
- `01-architecture.md` : modules (`AgentClaude`, `DashCore`, `HookRelay`), contrat IPC (§4.1), jeu de hooks (§4.2), threading (§5), budgets (§6), gestion d'erreurs (§7).
- `02-data-model.md` : `Session`, `SessionState`/machine à états (§3.1), `PendingPrompt`/`PromptDecision` (§4.1), `TokenTally`/`DiffStats`, `UsageWindow`/`UsageAccount`/`DailyUsage`, cycle de vie (§7), invariants (§8.1).
- `04-integration-cursor.md` : partage `HookServer`/`EventRouter`/`SessionStore` — les deux agents doivent produire des `DashEvent` homogènes.
- `09-token-usage.md` : logique générique des jauges (batterie, seuils, rollover, alertes budget) — ce fichier ne fournit que la **source** Claude.
- `05-notch-ui.md` : rendu des prompts/cartes/timeline ; `08-actions-inline.md` : hotkeys ⌘A/⌘N/⌥A/⌥T et mécanique ⌥T Open Terminal (§3.5) ; `11-quick-routes-fast-actions.md` : ouverture `NSWorkspace` des Quick Routes.
- `13-settings.md` (onglet Doctor, DoctorKit) : 4 checks « Ready », version plancher, export logs.

**Risques :**
1. **`PermissionRequest` en interactif** : comportement du terminal pendant l'attente du hook, conflit si l'utilisateur répond des deux côtés (« prompt handling location ») [HYPOTHÈSE claude-code n°1] — banc d'essai prioritaire dans `scripts/experiments/`.
2. **`AskUserQuestion` interactif** : `allow + updatedInput.answers` court-circuite-t-il le sélecteur ? Sinon fallback `deny+reason` [HYPOTHÈSE n°2] — bloquant pour REQ-CLA-44.
3. **Endpoint `/api/oauth/usage` non documenté** : stabilité du schéma selon plan (Pro/Max), champ compte/email, comportement 401 [HYPOTHÈSE n°5].
4. **Version minimale d'agent** : locale 2.1.89 ; features récentes exigent des versions plus hautes [HYPOTHÈSE n°8] — définir un plancher et une dégradation par feature.
5. **Cycle de vie du registre `~/.claude/sessions/`** : suppression à la sortie propre, orphelins de crash, fiabilité comme détecteur « desktop sans activité » [HYPOTHÈSE n°4].
6. **Resume multi-fichiers** `.jsonl` selon `--resume`/`--continue` [HYPOTHÈSE n°7].
7. **Gatekeeper** sur le binaire hook copié hors bundle (build signée réelle) [HYPOTHÈSE system-integration n°4].

---

## 8. Découpage en tâches

| Tâche | Description | Taille |
|---|---|---|
| **T-CLA-A** | `ClaudeHooksInstaller` : fusion/idempotence/`.bak`/écriture atomique/désinstallation + tests fixtures (settings avec hooks tiers) | **L** |
| **T-CLA-B** | Contribution au `HookRelay` (`--source claude`) + tests d'intégration croisés HookRelay↔HookServer (nominal, socket absent, réponse lente, ligne géante, app tuée) | **M** |
| **T-CLA-C** | `EventRouter` Claude : mapping événements → transitions T1–T16, classification décision/télémétrie | **L** |
| **T-CLA-D** | `PromptStore` Claude : permission/plan/question, réponses JSON (§3.5), auto-libération, capabilities | **L** |
| **T-CLA-E** | `TranscriptIngestor` : parseur JSONL tolérant, appariement tool_use/result, `DiffStats`, dédup `requestId`, subagents `isSidechain`, timeline fenêtrée | **XL** |
| **T-CLA-F** | Registre `~/.claude/sessions/` + liveness PID + `SessionHost` (entrypoint/TERM_PROGRAM) + dédup `SessionID` | **M** |
| **T-CLA-G** | Cycle de vie : `/clear` (chaînage), resume, compaction, sessions mortes, Kill (garde-fous), Dismiss, Copy as Markdown | **L** |
| **T-CLA-H** | `ClaudeUsagePoller` : Keychain OAuth, endpoint, headers, rétention/`isStale`, relecture 401, rollover | **L** |
| **T-CLA-I** | Fallback usage local : parsing JSONL, table de prix, `DailyUsage` (stats journalières), cache fichier | **M** |
| **T-CLA-J** | Fallback d'état sans hooks + réconciliation (`hookAuthorityWindow`), `isStale`/stuck | **M** |
| **T-CLA-K** | Contribution Doctor Claude : 4 checks « Ready », version plancher, `ConfigChange`, vérif intégrité | **M** |
| **T-CLA-X0** | Bancs d'essai `scripts/experiments/` : `PermissionRequest` interactif, `AskUserQuestion` answers, cycle registre, resume — **avant** les features dépendantes | **S** |

Ordre recommandé : T-CLA-X0 → T-CLA-B → T-CLA-A → T-CLA-C → (T-CLA-E ∥ T-CLA-F) → T-CLA-D → T-CLA-G → T-CLA-H/I → T-CLA-J → T-CLA-K.
