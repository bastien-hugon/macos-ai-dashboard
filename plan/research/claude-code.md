# Recherche technique — Intégration Claude Code pour AgentDash (nom provisoire)

> Date : 3 juillet 2026. Sources : documentation officielle `code.claude.com/docs` (référence hooks téléchargée intégralement en Markdown, 224 Ko), inspection locale de `~/.claude` (transcripts réels, registre de sessions, Keychain), issues GitHub `anthropics/claude-code`, outillage open-source (ccusage, Claude-Code-Usage-Monitor, claude-devtools).
>
> Convention : chaque affirmation est marquée **[VÉRIFIÉ]** (doc officielle ou inspection locale sur cette machine) ou **[HYPOTHÈSE]** (à valider en implémentation). Versions observées localement : CLI `claude` 2.1.89 dans le PATH, sessions récentes en 2.1.199, transcript de juin en 2.1.168.

---

## 1. HOOKS — Référence complète

### 1.1 Où déclarer les hooks **[VÉRIFIÉ]**

| Emplacement | Portée | Notes pour AgentDash |
|---|---|---|
| `~/.claude/settings.json` | Tous les projets de l'utilisateur | **Cible de notre installeur** (comme AgentPeek) |
| `.claude/settings.json` | Un projet (committable) | Ne pas y toucher |
| `.claude/settings.local.json` | Un projet (gitignoré) | Ne pas y toucher |
| Managed policy settings | Organisation | Lecture seule pour nous |
| Plugin `hooks/hooks.json` | Quand le plugin est actif | Alternative de distribution possible |
| Frontmatter de skill/agent | Pendant l'activité du composant | Non pertinent |

- Le fichier `~/.claude/settings.json` local contient actuellement les clés `effortLevel`, `language`, `model`, `permissions`, `voice` — **aucun hook** **[VÉRIFIÉ]**. L'installeur devra **fusionner** une clé `hooks` sans écraser l'existant.
- Les modifications des fichiers de settings sont **détectées à chaud** par un file watcher de Claude Code : les sessions déjà ouvertes récupèrent les hooks sans redémarrage (« If you edit settings files directly while Claude Code is running, the file watcher normally picks up hook changes automatically ») **[VÉRIFIÉ doc]**. C'est ce qui permet le « zéro configuration, les nouvelles sessions récupèrent les hooks » d'AgentPeek.
- `"disableAllHooks": true` désactive tout ; l'événement `ConfigChange` (matcher `user_settings`) permet de détecter qu'un autre process a modifié les settings (utile pour l'onglet Doctor).
- Le menu `/hooks` dans le CLI est en lecture seule (vérification visuelle du statut « Ready »).

### 1.2 Structure JSON de configuration **[VÉRIFIÉ]**

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/path/vers/agentdash-hook",
            "args": [],
            "timeout": 600,
            "statusMessage": "AgentDash…",
            "async": false
          }
        ]
      }
    ]
  }
}
```

Types de handlers : `command` (shell ou exec direct si `args` présent), `http` (POST du JSON vers une URL, la réponse HTTP porte le même JSON de sortie), `mcp_tool`, `prompt`, `agent`. Champs communs : `type`, `if` (filtre par règle de permission, ex. `"Bash(git *)"`, v2.1.85+), `timeout` (secondes), `statusMessage`. Champs `command` : `command`, `args` (exec form sans shell), `async` (tâche de fond non bloquante), `asyncRewake` (fond + réveille Claude sur exit 2), `shell`. Champs `http` : `url`, `headers` (interpolation `$VAR` limitée à `allowedEnvVars`).

> **Option d'architecture clé pour AgentDash** : le type `http` permet de pointer directement les hooks vers un serveur HTTP local de l'app (ex. `http://127.0.0.1:<port>/hook`) **sans binaire compagnon**. Échec de connexion / timeout / non-2xx = erreur **non bloquante** (la session continue normalement si AgentDash n'est pas lancé) **[VÉRIFIÉ doc]**. Alternative : `command` vers un petit binaire qui parle à l'app via socket UNIX (comportement identique, mais nécessite d'installer un exécutable).

### 1.3 Tous les événements **[VÉRIFIÉ doc, tableau complet]**

| Événement | Déclenchement | Bloquant ? | Intérêt AgentDash |
|---|---|---|---|
| `SessionStart` | Démarrage/reprise de session (matcher : `startup`, `resume`, `clear`, `compact`) | Non | Détection de session, dédup |
| `Setup` | `--init-only`, `-p --init`/`--maintenance` | Non | — |
| `UserPromptSubmit` | Prompt soumis, avant traitement | Oui | État « executing », prompt actif |
| `UserPromptExpansion` | Expansion d'une commande utilisateur | Oui | — |
| `PreToolUse` | Avant exécution d'un tool call | Oui (allow/deny/ask/defer) | Timeline + réponse aux questions/plans |
| `PermissionRequest` | Quand un dialogue de permission va s'afficher | Oui (allow/deny) | **Cœur du « Act »** |
| `PermissionDenied` | Tool refusé par le classifieur du mode auto | Non (`{retry:true}`) | Info timeline |
| `PostToolUse` | Après un tool réussi | Oui (feedback) | Timeline, compteurs, diffs |
| `PostToolUseFailure` | Après un tool en échec (`error`, `is_interrupt`, `duration_ms`) | Non | Timeline (erreurs) |
| `PostToolBatch` | Après un lot de tools parallèles | Oui | — |
| `Notification` | Notification émise par Claude Code | Non | **Attention requise / idle** |
| `MessageDisplay` | Affichage du texte assistant | Non | (extraits de réponse — préférer le transcript) |
| `SubagentStart` | Subagent lancé (`agent_id`, `agent_type`) | Non | Activité subagents |
| `SubagentStop` | Subagent terminé (`agent_transcript_path`, `last_assistant_message`) | Oui | Activité subagents |
| `TaskCreated` / `TaskCompleted` | Tâches (TaskCreate) | Oui | — |
| `Stop` | Fin de réponse du tour principal (`last_assistant_message`, `background_tasks`, `session_crons`) | Oui | **État « idle » / notification tâche finie** |
| `StopFailure` | Tour terminé sur erreur API (matcher : `rate_limit`, `overloaded`, `authentication_failed`, `billing_error`…) | Non | Alerte session bloquée / limites atteintes |
| `TeammateIdle` | Teammate d'agent team sur le point d'être idle | Oui | — |
| `InstructionsLoaded` | Chargement de CLAUDE.md / rules | Non | — |
| `ConfigChange` | Fichier de config modifié en cours de session (matcher : `user_settings`, `project_settings`, `local_settings`, `policy_settings`, `skills`) | Oui | Doctor (hooks réparés/écrasés) |
| `CwdChanged` | Changement de répertoire courant | Non | Rattacher la session au bon projet |
| `FileChanged` | Fichier surveillé modifié (matcher = noms littéraux) | Non | — |
| `WorktreeCreate` / `WorktreeRemove` | Worktrees | Oui / Non | — |
| `PreCompact` | Avant compaction (matcher : `manual`, `auto`) | Oui | Marqueur compaction |
| `PostCompact` | Après compaction (`compact_summary`) | Non | Marqueur compaction |
| `Elicitation` / `ElicitationResult` | Formulaire MCP | Oui | (prompts MCP inline, v2) |
| `SessionEnd` | Fin de session (matcher/`reason` : `clear`, `resume`, `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other`) | Non | Cycle de vie, `/clear` |

### 1.4 JSON reçu sur stdin **[VÉRIFIÉ doc]**

Champs communs à tous les événements :

```json
{
  "session_id": "abc123",
  "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
  "transcript_path": "/Users/<user>/.claude/projects/<proj>/<session>.jsonl",
  "cwd": "/Users/<user>/mon-projet",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "effort": { "level": "high" }
}
```

- `permission_mode` ∈ `default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`.
- `prompt_id` requiert v2.1.196+. En contexte subagent s'ajoutent `agent_id` et `agent_type`.
- `PreToolUse` ajoute `tool_name`, `tool_input`, `tool_use_id`. `PostToolUse` ajoute `tool_response` et `duration_ms`. `Notification` ajoute `message`, `title` (optionnel), `notification_type`. `Stop` ajoute `stop_hook_active`, `last_assistant_message`, `background_tasks[]`, `session_crons[]` (v2.1.145+).
- `PermissionRequest` ajoute `tool_name`, `tool_input` (sans `tool_use_id`) et `permission_suggestions[]` — les options « always allow » que le dialogue aurait proposées :

```json
{
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf node_modules", "description": "Remove node_modules directory" },
  "permission_suggestions": [
    {
      "type": "addRules",
      "rules": [{ "toolName": "Bash", "ruleContent": "rm -rf node_modules" }],
      "behavior": "allow",
      "destination": "localSettings"
    }
  ]
}
```

### 1.5 Sorties possibles **[VÉRIFIÉ doc]**

**Exit codes** : `0` = pas d'objection, le stdout est parsé comme JSON structuré ; `2` = blocage (stderr renvoyé à Claude ; sur `PermissionRequest` = refus, sur `PreToolUse` = tool bloqué) ; tout autre code = erreur non bloquante. Ne pas mélanger : le JSON est ignoré si exit 2.

**Champs JSON universels** : `continue` (false = stoppe Claude entièrement), `stopReason`, `suppressOutput`, `systemMessage`, `terminalSequence`.

**`PreToolUse` → `hookSpecificOutput`** :

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow | deny | ask | defer",
    "permissionDecisionReason": "…",
    "updatedInput": { "…": "remplace TOUT l'input" },
    "additionalContext": "texte injecté dans le contexte de Claude"
  }
}
```

- Précédence entre hooks concurrents : `deny` > `defer` > `ask` > `allow`.
- `deny` : la raison est montrée à Claude (il s'adapte). `allow`/`ask` : la raison est montrée à l'utilisateur.
- `PreToolUse` s'exécute **avant** les vérifications de mode de permission : un `deny` bloque même en `bypassPermissions`. Un `allow` ne contourne jamais les règles deny/ask des settings.
- `defer` : uniquement en mode non interactif `-p` (v2.1.89+) ; le process sort avec `stop_reason: "tool_deferred"` et `deferred_tool_use {id, name, input}`, à reprendre via `--resume`. Ignoré en session interactive (warning).

**`PermissionRequest` → `hookSpecificOutput.decision`** :

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow | deny",
      "updatedInput": { "…": "…" },
      "updatedPermissions": [ { "type": "addRules", "rules": [{ "toolName": "Bash", "ruleContent": "npm test" }], "behavior": "allow", "destination": "localSettings" } ],
      "message": "raison du refus (deny uniquement, transmise à Claude)",
      "interrupt": false
    }
  }
}
```

- `updatedPermissions` (allow uniquement) accepte les entrées : `addRules`, `replaceRules`, `removeRules`, `setMode` (`default`/`auto`/`acceptEdits`/`dontAsk`/`bypassPermissions`/`plan`), `addDirectories`, `removeDirectories` ; `destination` ∈ `session` (mémoire), `localSettings`, `projectSettings`, `userSettings`.
- **« Always Allow » (⌥A d'AgentPeek)** = renvoyer telle quelle une entrée de `permission_suggestions` dans `updatedPermissions` : « équivalent au choix de l'option "always allow" dans le dialogue » **[VÉRIFIÉ doc, citation]**.
- `message` + `behavior: "deny"` = **« Deny with feedback »**.
- ⚠️ `PermissionRequest` **ne se déclenche pas en mode `-p` non interactif** (utiliser `PreToolUse` dans ce cas) **[VÉRIFIÉ doc]**.

**Autres décisions** : `PostToolUse` : `decision:"block"` + `reason`, `updatedToolOutput` ; `Stop`/`SubagentStop` : `decision:"block"` + `reason` (cap : 8 blocages consécutifs, champ `stop_hook_active` en entrée) ; `UserPromptSubmit`/`PreCompact`/`ConfigChange` : `decision:"block"` + `reason` ; `SessionStart` : `additionalContext`, `initialUserMessage`, `sessionTitle`, `watchPaths`, `reloadSkills`.

### 1.6 Matchers **[VÉRIFIÉ doc]**

- `"*"`, `""` ou omis = tout. Identifiant simple = match exact (`Bash`, `Edit|Write`, `,` et `|` interchangeables v2.1.191+). Présence de caractères regex = regex non ancrée (`^Notebook`, `mcp__memory__.*`).
- Événements tool (`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied`) matchent `tool_name` — y compris `AskUserQuestion` et `ExitPlanMode`.
- Matchers spécifiques : `SessionStart` (source), `SessionEnd` (raison), `Notification` (type), `SubagentStart/Stop` (type d'agent), `PreCompact/PostCompact` (`manual`/`auto`), `StopFailure` (type d'erreur), `ConfigChange` (source), etc. `UserPromptSubmit`, `Stop`, `CwdChanged`, `MessageDisplay`… : pas de matcher.
- Outils MCP : `mcp__<server>__<tool>`.

### 1.7 Timeouts et exécution **[VÉRIFIÉ doc]**

| Contexte | Timeout par défaut |
|---|---|
| `command`, `http`, `mcp_tool` | **600 s** (surchargeable par hook via `timeout`) |
| Hooks `UserPromptSubmit` | 30 s |
| Hooks `MessageDisplay` | 10 s |
| `prompt` / `agent` | 30 s / 60 s |
| Hooks `SessionEnd` | budget global **1,5 s** (élevé jusqu'au plus grand `timeout` configuré, max 60 s ; env `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS`) |

- Tous les hooks qui matchent un événement s'exécutent **en parallèle**, dédupliqués s'ils sont identiques ; les résultats sont fusionnés après que **tous** ont fini (le plus restrictif gagne). Conséquence : un hook AgentDash lent retarde la fusion — soigner la réactivité.
- Debug : `claude --debug-file /tmp/claude.log`, ou `/debug` en session ; le transcript (Ctrl+O) résume chaque hook.

---

## 2. RÉPONDRE AUX PROMPTS DEPUIS UNE APP EXTERNE — le point critique

### 2.1 Validation de l'hypothèse centrale

**L'hypothèse est validée, avec une précision importante : pour les sessions interactives, le bon événement est `PermissionRequest` (pas seulement `PreToolUse`).**

Flux recommandé (permissions classiques, ex. Bash/Edit) :

1. Hook `PermissionRequest` (matcher `*`) de type `http` vers le serveur local d'AgentDash (ou `command` vers un binaire compagnon connecté en socket UNIX — les deux transports sont équivalents fonctionnellement).
2. AgentDash reçoit `tool_name`, `tool_input`, `permission_suggestions`, `session_id`, `cwd`, `transcript_path` → affiche la demande dans le notch.
3. Le hook **reste en attente** (jusqu'au timeout configuré, défaut 600 s) pendant que l'utilisateur décide.
4. Réponse :
   - **Allow (⌘A)** → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` — le transcript CLI affiche « Allowed by PermissionRequest hook » **[VÉRIFIÉ doc]**.
   - **Deny (⌘N)** → `decision:{"behavior":"deny"}` ; **Deny with feedback** → + `"message":"<texte utilisateur>"` (transmis à Claude).
   - **Always Allow (⌥A)** → `behavior:"allow"` + `updatedPermissions:[<une des permission_suggestions reçues>]` (persistance selon `destination`).
   - **Laisser la main au terminal** → exit 0 sans décision (ou 2xx avec corps vide côté http) : le dialogue normal s'affiche.

Points de vigilance vérifiés dans la doc : les règles deny/ask des settings restent prioritaires sur un `allow` de hook ; `PermissionRequest` ne se déclenche pas en `-p` ; exit code 2 = deny.

### 2.2 Questions (`AskUserQuestion`) **[VÉRIFIÉ doc]**

- `AskUserQuestion` est un nom de tool matchable par `PreToolUse` **et** `PermissionRequest` (« Matches on tool name, same values as PreToolUse », liste incluant `AskUserQuestion` et `ExitPlanMode`).
- `tool_input.questions[]` : 1 à 4 questions, chacune `{question, header, options:[{label,…}], multiSelect}`.
- **Pour répondre programmatiquement** : renvoyer `permissionDecision: "allow"` **plus** `updatedInput` contenant le tableau `questions` d'origine **et** un objet `answers` mappant le texte de chaque question vers le label choisi (multi-select : labels joints par des virgules). Citation doc : « For `AskUserQuestion`, echo back the original `questions` array and add an `answers` object mapping each question's text to the chosen answer. » Un `allow` seul ne suffit pas.

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": {
      "questions": [ { "question": "Which framework?", "header": "Framework", "options": [{"label": "React"}, {"label": "Vue"}], "multiSelect": false } ],
      "answers": { "Which framework?": "React" }
    }
  }
}
```

- ⚠️ La doc décrit ce mécanisme dans le contexte du mode non interactif `-p` (« normally block in non-interactive mode… satisfies that requirement »). **[HYPOTHÈSE]** : en session interactive, le même `allow + updatedInput` via `PreToolUse` ou `PermissionRequest` court-circuite le sélecteur du terminal. À valider en priorité ; sinon, fallback : réponse texte libre via `deny` + `permissionDecisionReason`/`message` contenant la réponse de l'utilisateur (Claude la lit et s'adapte) — pattern éprouvé mais moins propre.
- Historique utile : l'issue GitHub #12605 (nov. 2025) demandait exactement ce support et est **fermée** ; le support `answers`/`updatedInput` documenté ci-dessus y a répondu.

### 2.3 Plans (`ExitPlanMode`) **[VÉRIFIÉ doc]**

- `tool_input` reçu par les hooks : `plan` (Markdown, injecté depuis le fichier plan sur disque), `planFilePath`, `allowedPrompts[]` (`{tool, prompt}` — permissions demandées pour exécuter le plan). De quoi afficher le plan complet dans le notch avec titre stylisé.
- **Approve** : hook `PermissionRequest` matcher `ExitPlanMode` → `decision:{"behavior":"allow"}`. Exemple officiel d'auto-approbation dans le guide. Après approbation, Claude Code sort du plan mode et restaure le mode de permission antérieur ; possibilité de forcer `acceptEdits` via `updatedPermissions:[{"type":"setMode","mode":"acceptEdits","destination":"session"}]`.
- **Reject** : `decision:{"behavior":"deny","message":"<feedback>"}` — Claude reste en plan mode et lit le feedback.
- Limitation notée par la doc : la voie hook « garde toujours la conversation courante » (pas d'option « nouvelle session » comme dans le dialogue natif).

### 2.4 Événement `Notification` (attention requise) **[VÉRIFIÉ doc]**

Entrée : `message`, `title` (optionnel), `notification_type`. Types : `permission_prompt` (agent attend une approbation), `idle_prompt` (Claude attend le prochain prompt — base des « stuck sessions » et du point orange), `auth_success`, `elicitation_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed` (v2.1.198+, agent view uniquement). Non bloquant, aucune modification possible — parfait comme signal push d'état vers AgentDash (waiting/idle) en plus de `PermissionRequest`.

### 2.5 Ce qui reste incertain **[HYPOTHÈSE]**

- Comportement exact du terminal **pendant** qu'un hook `PermissionRequest` est en attente : dialogue différé jusqu'à résolution du hook (probable, la doc dit « when a permission dialog is about to be shown ») ; que se passe-t-il si l'utilisateur répond dans le terminal pendant ce temps ? Le réglage AgentPeek « prompt handling location » suggère qu'on ne peut pas avoir les deux simultanément. À tester (deux sessions, chronométrage).
- Timeout ergonomique : garder le hook en attente 600 s bloque le dialogue natif ; stratégie AgentDash : timeout court configurable + « pas de décision » pour rendre la main au terminal.
- Interaction avec d'autres hooks utilisateur en parallèle (un `deny` tiers gagne sur notre `allow`).

---

## 3. TRANSCRIPTS `~/.claude/projects`

### 3.1 Organisation des fichiers **[VÉRIFIÉ localement]**

```
~/.claude/projects/<cwd encodé>/<sessionId>.jsonl          # transcript principal
~/.claude/projects/<cwd encodé>/<sessionId>/               # dossier compagnon de session
    subagents/agent-<id>.jsonl + agent-<id>.meta.json       # transcripts des subagents
    subagents/workflows/wf_<id>/…, journal.jsonl            # subagents de workflows
    tool-results/toolu_<id>.txt                             # sorties volumineuses persistées
~/.claude/sessions/<pid>.json                               # registre des sessions VIVANTES
~/.claude/ide/<port>.lock                                   # extensions IDE connectées
```

- Encodage du dossier projet : chemin absolu avec `/` (et caractères non alphanumériques) remplacés par `-` : `/Users/bastien/Documents/macos-ai-dashboard` → `-Users-bastien-Documents-macos-ai-dashboard` **[VÉRIFIÉ]**.
- **Registre de sessions vivantes** (découverte importante) : `~/.claude/sessions/1542.json` observé :

```json
{"pid":1542,"sessionId":"0f8ddc9b-…","cwd":"/Users/bastien/Documents/macos-ai-dashboard","startedAt":1783105086643,"procStart":"Fri Jul  3 18:58:05 2026","version":"2.1.199","peerProtocol":1,"kind":"interactive","entrypoint":"claude-vscode","name":"macos-ai-dashboard-0b","nameSource":"derived"}
```

  Nom de fichier = PID → liveness vérifiable (`kill -0`/`proc_pidinfo`). Champs : `sessionId`, `cwd`, `startedAt` (ms epoch), `version`, `kind`, `entrypoint`, `name`. **[HYPOTHÈSE]** : le fichier est supprimé à la sortie propre ; des fichiers orphelins (crash) sont possibles — croiser avec l'existence du process.

### 3.2 Types d'entrées observés (2 transcripts réels, v2.1.168 et v2.1.199) **[VÉRIFIÉ]**

| `type` | Rôle | Champs spécifiques |
|---|---|---|
| `user` | Message utilisateur OU résultat de tool | `message.role/content`, `promptId`, `promptSource` (`sdk` observé), `permissionMode`, `toolUseResult`, `sourceToolAssistantUUID`, `isMeta` |
| `assistant` | Réponse du modèle (souvent plusieurs entrées par requête, streaming) | `message` complet façon API Anthropic, `requestId` |
| `attachment` | Injections système | `attachment.type` : `todo_reminder`, `skill_listing`, `agent_listing_delta`, `deferred_tools_delta`, `plan_mode_exit`, `ultra_effort_enter` |
| `file-history-snapshot` | Sauvegarde pour rewind | `messageId`, `snapshot.trackedFileBackups`, `isSnapshotUpdate` |
| `ai-title` | Titre auto de la session (réémis) | `aiTitle` (ex. « Examiner le nettoyage du projet avec K… ») |
| `last-prompt` | Dernier prompt (tronqué ~200 c.) | `lastPrompt`, `leafUuid` |
| `pr-link` | PR GitHub liée | `prNumber`, `prUrl`, `prRepository` |
| `queue-operation` | File d'attente de prompts | `operation` : `enqueue` / `dequeue` |

**[HYPOTHÈSE]** : d'anciens formats/communautés documentent aussi `summary` (résumé pour `/resume` + compaction, avec `leafUuid`), `system` et `progress` ; non observés dans ces deux fichiers récents — prévoir un parseur tolérant (ignorer les types inconnus).

Enveloppe commune (`user`/`assistant`) : `uuid`, `parentUuid` (chaînage ; `null` en début de fil), `sessionId`, `timestamp` (ISO 8601 UTC), `cwd`, `gitBranch`, `version`, `entrypoint`, `userType` (`"external"`), `isSidechain` (bool).

### 3.3 Exemples réels (anonymisés)

Entrée `user` (prompt) :

```json
{"parentUuid":null,"isSidechain":false,"promptId":"fb4c2943-…","type":"user",
 "message":{"role":"user","content":[{"type":"text","text":"<prompt utilisateur>"}]},
 "uuid":"47138393-…","timestamp":"2026-06-09T13:42:47.091Z","permissionMode":"auto",
 "promptSource":"sdk","userType":"external","entrypoint":"claude-vscode",
 "cwd":"/Users/<user>/Documents/<projet>","sessionId":"df0bfbb7-…","version":"2.1.168","gitBranch":"<branche>"}
```

Entrée `assistant` avec `usage` (les champs clés pour les tokens) :

```json
{"type":"assistant","requestId":"req_011Cbs…","uuid":"3d992bdc-…","parentUuid":"9962afa1-…",
 "timestamp":"2026-06-09T13:42:51.012Z",
 "message":{"model":"claude-opus-4-8","id":"msg_015v…","role":"assistant",
   "content":[{"type":"thinking","thinking":"…","signature":"…"}],
   "stop_reason":"tool_use",
   "usage":{"input_tokens":5381,"cache_creation_input_tokens":4995,"cache_read_input_tokens":7926,
            "output_tokens":243,"service_tier":"standard",
            "cache_creation":{"ephemeral_1h_input_tokens":4995,"ephemeral_5m_input_tokens":0},
            "iterations":[{"input_tokens":5381,"output_tokens":243,"…":"…"}],"speed":"standard"}}}
```

Tool call (bloc `content[]` d'une entrée `assistant`) :

```json
{"type":"tool_use","id":"toolu_01JH…","name":"Bash",
 "input":{"command":"git log --oneline main..HEAD","description":"Show branch commits"},
 "caller":{"type":"direct"}}
```

Résultat de tool (entrée `user` liée) : `message.content[0] = {type:"tool_result", tool_use_id, is_error}` + champ top-level `toolUseResult` riche :
- Bash → `{stdout, stderr, interrupted, isImage, noOutputExpected}` (+ `persistedOutputPath/Size` si sortie volumineuse persistée dans `tool-results/`) ;
- Edit/Write → `{filePath, content?, originalFile?, structuredPatch[], userModified, type}` — **`structuredPatch` = hunks de diff → stats lignes ajoutées/supprimées** ;
- WebFetch → `{bytes, code, codeText, durationMs, result, url}` ; Read → `{file, type}` ; erreur → `toolUseResult` est une **string**.

Subagents : `meta.json = {"agentType":"workflow-subagent","spawnDepth":1}` ; toutes les entrées du transcript subagent ont `isSidechain: true` **[VÉRIFIÉ]**. `stop_reason` observés : `tool_use`, `end_turn` (souvent `null` sur les entrées partielles streamées).

### 3.4 Déductions pour AgentDash

- **État de session** (fallback sans hooks, via FSEvents sur le `.jsonl`) :
  - *executing* : dernière entrée = `assistant` avec `tool_use` sans `tool_result` correspondant, ou écritures fréquentes du fichier ;
  - *thinking* : dernière entrée `assistant` avec bloc `thinking`/texte partiel, `stop_reason` null ;
  - *waiting* : `tool_use` en suspens + signal `Notification permission_prompt` (les transcripts seuls ne marquent pas la demande de permission de façon fiable → **les hooks sont la source d'état primaire**, le transcript le fallback) ;
  - *idle* : `stop_reason:"end_turn"` + pas de nouvelle écriture ; confirmé par hook `Stop`.
- **Timeline des tool calls** : séquence des blocs `tool_use` (nom + input résumable en langage clair) appariés aux `tool_result` par `tool_use_id`, horodatés par `timestamp` ; `duration_ms` disponible via hooks `PostToolUse`.
- **Compteurs** : fichiers = `tool_use` distincts `Edit|Write|NotebookEdit` (par `file_path`) ; commandes = `tool_use` `Bash` ; diffs = somme des `structuredPatch`.
- **Tokens par session (split input/output)** : sommer `message.usage` des entrées `assistant` **en dédupliquant par `requestId` (garder la dernière entrée du même `requestId`)** — le streaming écrit 2 à 10 entrées à `output_tokens` cumulatifs par requête (source : ccusage + issue claude-devtools #74) **[VÉRIFIÉ sources croisées]**. Affichage type AgentPeek « 24.6k / 66 » : input = `input_tokens` (+ éventuellement caches séparés), output = `output_tokens` ; mise à jour mid-turn = lire les entrées partielles au fil de l'eau.
- **Compaction** : hooks `PreCompact`/`PostCompact` (avec `compact_summary`) ; `SessionStart` source `compact`.
- **/clear** : `SessionEnd` reason `clear` puis nouvelle session (`SessionStart` source `clear`, nouveau `sessionId`) — garder la row historique côté UI.
- **Resume** : `SessionStart` source `resume` ; le `sessionId` repris continue d'écrire dans le même fichier ; `SessionEnd` reason `resume` quand on change de session dans le même process. **[HYPOTHÈSE]** : un resume peut créer un nouveau fichier `.jsonl` référant l'ancien via le chaînage `parentUuid`/résumés — à vérifier.
- **Dédoublonnage** : clé = `sessionId` (registre `~/.claude/sessions` + transcripts + hooks donnent tous ce champ) ; ignorer les fichiers de registre dont le PID est mort.

---

## 4. USAGE 5 h / 7 jours

### 4.1 Source primaire : endpoint OAuth (méthode AgentPeek « via /usage ») 

- **Credentials** **[VÉRIFIÉ localement]** : Keychain macOS, item *generic password*, service **`Claude Code-credentials`**, account = nom d'utilisateur (`bastien`), mis à jour aujourd'hui (`mdat 2026-07-03`). Pas de `~/.claude/.credentials.json` sur macOS (ce fichier est utilisé sous Linux/Windows). Contenu **[VÉRIFIÉ sources]** : JSON `{"claudeAiOauth":{"accessToken":"…","refreshToken":"…","expiresAt":<ms epoch>,…}}`. Lecture : `security find-generic-password -s "Claude Code-credentials" -w` ou API Security framework — déclenchera une **invite Keychain à autoriser** pour AgentDash (UX d'onboarding à prévoir).
- **Endpoint** **[VÉRIFIÉ sources — non documenté officiellement]** : `GET https://api.anthropic.com/api/oauth/usage` avec headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, et **impérativement** `User-Agent: claude-code/<version>` (sans lui : 429 persistants). Réponse :

```json
{
  "five_hour":  { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
  "seven_day":  { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
  "seven_day_opus": null,
  "seven_day_sonnet": { "utilization": 1.0, "resets_at": "2026-04-16T03:00:00.951719+00:00" },
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
}
```

  `utilization` = pourcentage 0–100 (0 si pas de fenêtre active) ; `resets_at` = ISO 8601 UTC → exactement les jauges 5 h (« resets in… ») et 7 j (« refills Sun at 3:47 PM ») d'AgentPeek. Polling sûr ≈ toutes les 180 s ; rate limit par access token. Source principale : issue #202 de Claude-Code-Usage-Monitor (« authoritative window state », mêmes données que `/usage`).
- **Cycle du token** : `expiresAt` ≈ 60 min ; Claude Code rafraîchit lui-même le token dans le Keychain (le `mdat` observé bouge). Stratégie AgentDash : relire le Keychain quand le token expire plutôt que d'implémenter le refresh OAuth nous-mêmes (le refresh consommerait le `refreshToken` et risquerait de désynchroniser Claude Code) **[HYPOTHÈSE sur le risque ; à valider]**.
- **Multi-comptes** : un seul item Keychain par utilisateur macOS observé ; le « label de compte » d'AgentPeek vient probablement du JSON OAuth (email/organisation) **[HYPOTHÈSE]**.
- La commande `/usage` du CLI affiche ces mêmes fenêtres en interactif ; elle n'est pas scriptable proprement (pas de sortie JSON documentée) — l'endpoint est la voie programmatique.

### 4.2 Fallback local : calcul depuis les transcripts (méthode ccusage)

- Parser tous les `~/.claude/projects/**/*.jsonl`, entrées `assistant` avec `usage`, **dédup par `requestId`** (et `message.id`), prix par modèle (table LiteLLM) → coût/jour, coût/session, **stats jour par jour** (feature AgentPeek v0.2.6).
- Fenêtres 5 h « blocks » à la ccusage : regrouper l'activité en blocs de 5 h (début = heure pleine UTC du premier message du bloc) — utile pour visualiser, mais **non autoritaire** (l'endpoint OAuth reste la vérité serveur, surtout multi-appareils).
- Outils étudiés : **ccusage** (parsing JSONL local, modes de coût auto/calculate/display, dédup), **Claude-Code-Usage-Monitor** (monitor temps réel, a migré vers l'endpoint OAuth pour l'exactitude), **CCSeva** (menu bar macOS basé ccusage), **claude-powerline** (statusline avec jauges). Tous confirment : JSONL local pour le détail, endpoint OAuth pour les pourcentages officiels.
- ⚠️ Piège documenté (article « JSONL undercount ») : `input_tokens` seul sous-estime ~100× l'usage réel — toujours inclure `cache_read_input_tokens` + `cache_creation_input_tokens` dans les totaux de consommation.

---

## 5. DESKTOP vs TERMINAL

- **Champ `entrypoint`** présent dans chaque entrée de transcript ET dans `~/.claude/sessions/<pid>.json` :
  - `"claude-vscode"` = extension VS Code/Cursor **[VÉRIFIÉ localement]** ;
  - `"claude-desktop-3p"` = sessions créées par l'app Claude Desktop **[VÉRIFIÉ via issue GitHub #59736]** — transcripts stockés dans le **même** arbre `~/.claude/projects` ;
  - `"cli"` (ou équivalent) pour le terminal **[HYPOTHÈSE — aucune session terminal pure sur cette machine à l'instant T ; à vérifier en lançant `claude` dans un terminal]**.
- Le registre `~/.claude/sessions/<pid>.json` donne en plus `kind` (`"interactive"` observé) et le PID → on peut remonter au process parent (Terminal.app, iTerm, Cursor, Claude.app) via `proc_pidpath`/`sysctl` pour l'étiquette « environnement hôte » **[VÉRIFIÉ pour la mécanique PID ; mapping parent à implémenter]**.
- `~/.claude/ide/<port>.lock` **[VÉRIFIÉ localement]** : `{"pid":…,"workspaceFolders":[…],"ideName":"Cursor","transport":"ws","authToken":"…"}` — identifie les IDE connectés (beaucoup de locks périmés persistent : vérifier la vivacité du PID).
- Les hooks déclarés dans `~/.claude/settings.json` s'appliquent à **toutes** les surfaces (CLI, VS Code/Cursor ext, Desktop) puisque c'est le même moteur Claude Code — cohérent avec le « hooks partagés CLI + desktop » d'AgentPeek **[VÉRIFIÉ par construction ; à confirmer empiriquement pour Desktop]**.
- Les sessions Desktop « apparaissent dès le lancement » (AgentPeek) : plausiblement via le registre `~/.claude/sessions/` + `SessionStart`, sans attendre le premier prompt **[HYPOTHÈSE]**.

---

## Décisions d'implémentation recommandées

1. **Double canal d'ingestion** : (a) hooks = source primaire temps réel des états et des prompts à traiter ; (b) parsing incrémental des transcripts (FSEvents + offset par fichier) = timeline, tokens, diffs, historique, récupération après redémarrage d'AgentDash.
2. **Transport des hooks** : privilégier `type: "http"` vers `http://127.0.0.1:<port fixe>/hook/<event>` — zéro binaire à installer, fail-open natif (app éteinte ⇒ non-bloquant), réponse JSON directe. Garder l'option binaire compagnon + socket UNIX si on constate des limites (latence de spawn négligeable côté http).
3. **Jeu de hooks à installer dans `~/.claude/settings.json`** (fusion non destructive, idempotente, avec marqueur pour le Doctor) : `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse` (matcher `AskUserQuestion|ExitPlanMode`), `PermissionRequest` (matcher `*`), `PostToolUse` (matcher `*`), `PostToolUseFailure`, `SubagentStart`, `SubagentStop`, `Notification`, `Stop`, `StopFailure`, `PreCompact`, `PostCompact`, `ConfigChange`. Timeout court par hook (ex. 2–5 s) pour tout ce qui est télémétrie ; timeout long uniquement sur `PermissionRequest`/`PreToolUse` interactifs.
4. **Actions inline** : Allow/Deny/Deny-with-feedback/Always-Allow via `PermissionRequest.decision` (+ `updatedPermissions` en écho des `permission_suggestions`) ; plans via matcher `ExitPlanMode` (Approve/Reject = allow/deny+message) ; questions via `AskUserQuestion` + `updatedInput.answers`.
5. **Usage** : Keychain (`Claude Code-credentials`) → `GET /api/oauth/usage` toutes les ~180 s avec `User-Agent: claude-code/<version détectée>` ; retenir la dernière valeur en cas d'échec (comportement AgentPeek) ; fallback + stats journalières via parsing JSONL (dédup `requestId`).
6. **Identité de session** : clé = `sessionId` ; vivacité = `~/.claude/sessions/<pid>.json` + liveness PID ; surface = `entrypoint` ; titre = dernière entrée `ai-title`, sous-titre = `last-prompt` ; projet = `cwd` (mis à jour par `CwdChanged`).
7. **Kill session** : `SIGTERM` sur le PID du registre (pas de mécanisme doc dédié) ; « Copy as Markdown » = rendu depuis le transcript.

## Hypothèses restant à valider (en implémentation)

1. `PermissionRequest` en session interactive : le dialogue terminal attend-il la fin du hook ? Que se passe-t-il si l'utilisateur répond dans le terminal pendant que le hook AgentDash est en attente ? (Design du réglage « prompt handling location ».)
2. `AskUserQuestion` en interactif : `allow + updatedInput.answers` supprime-t-il bien le sélecteur du terminal (la doc ne le garantit que pour `-p`) ? Sinon, fallback `deny + reason`.
3. Valeur exacte d'`entrypoint` pour une session terminal pure (`cli` ?) et pour Claude Desktop sur cette machine (`claude-desktop-3p` à confirmer localement) ; liste complète des valeurs.
4. Cycle de vie de `~/.claude/sessions/<pid>.json` (suppression à la sortie ? fichiers orphelins après crash ?) et fiabilité comme détecteur « session desktop lancée sans activité ».
5. Stabilité de l'endpoint `/api/oauth/usage` (non documenté officiellement) : schéma exact selon plan (Pro/Max), champ compte/email pour le « label de compte », comportement 401 (token expiré) → relecture Keychain suffisante sans refresh OAuth actif ?
6. Types d'entrées `summary`/`system`/`progress` dans les transcripts d'anciennes versions et forme exacte du marqueur de compaction dans le fichier (en plus des hooks).
7. Resume : nouveau fichier `.jsonl` ou continuation du même fichier selon les cas (`--resume`, `/resume`, `--continue`) ; gestion des sessions dupliquées côté fichiers.
8. Événements disponibles dans de vieilles versions de Claude Code (ex. 2.1.89 locale) : `PermissionRequest` et `updatedInput` pour `AskUserQuestion` exigent des versions récentes (`defer` v2.1.89+, `if` v2.1.85+, `prompt_id` v2.1.196+) → définir une version minimale supportée et un check dans le Doctor.
9. Lecture Keychain depuis une app sandboxée/notariée (prompt utilisateur, entitlements) — tester le flux d'autorisation.
10. Latence réelle de la boucle hook → notch → réponse (objectif < 100 ms hors décision humaine) et impact des hooks parallèles tiers.
