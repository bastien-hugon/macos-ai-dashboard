# Recherche technique — Intégration Cursor dans AgentDash (nom provisoire)

> Date de la recherche : 3 juillet 2026.
> Machine d'inspection : macOS (Darwin 25.5.0), Cursor **3.7.27** installé (`/Applications/Cursor.app`), utilisateur connecté (signup type « Google », `stripeMembershipType` = « enterprise »).
> Convention : chaque affirmation est marquée **[VÉRIFIÉ — doc]** (documentation officielle), **[VÉRIFIÉ — local]** (inspection directe de cette machine), **[VÉRIFIÉ — OSS]** (code open-source lu), ou **[HYPOTHÈSE]** (à valider en implémentation).
> Aucune requête authentifiée n'a été émise vers cursor.com pendant cette recherche. Aucun contenu privé de conversation n'est reproduit ici : uniquement des structures.

---

## 1. Hooks Cursor

Source principale : https://cursor.com/docs/agent/hooks (récupérée le 3 juillet 2026). **[VÉRIFIÉ — doc]** sauf mention contraire.

### 1.1 Fichier `hooks.json`

Emplacements (fusionnés par priorité décroissante : **Enterprise → Team → Project → User**) :

| Portée | Chemin (macOS) |
|---|---|
| Enterprise | `/Library/Application Support/Cursor/hooks.json` |
| Projet | `<racine-projet>/.cursor/hooks.json` |
| Utilisateur | `~/.cursor/hooks.json` |

État local : `~/.cursor/hooks.json` **n'existe pas** sur cette machine. **[VÉRIFIÉ — local]** AgentDash devra le créer (c'est exactement le fichier qu'AgentPeek installe, cf. `AGENTPEEK_FEATURES.md` §2.1 et Quick Routes).

Format minimal :

```json
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [{ "command": "/chemin/vers/script.sh" }],
    "stop": [{ "command": "/chemin/vers/script.sh" }]
  }
}
```

Options par script :

| Option | Type | Défaut | Rôle |
|---|---|---|---|
| `command` | string | requis | Chemin de script ou commande shell |
| `type` | `"command"` \| `"prompt"` | `"command"` | `prompt` = évaluation d'une condition en langage naturel par LLM (retourne `{ ok, reason? }`) |
| `timeout` | number (secondes) | « platform default » (valeur numérique **non documentée** → **[HYPOTHÈSE]** à mesurer) | Timeout d'exécution |
| `loop_limit` | number \| null | 5 | Pour `stop` / `subagentStop` (boucles de relance via `followup_message`) |
| `failClosed` | boolean | false | Par défaut **fail-open** : crash/timeout/JSON invalide ⇒ l'action passe. `true` ⇒ bloque |
| `matcher` | string | — | Filtre : type d'outil (`preToolUse`/`postToolUse`/`postToolUseFailure`), type de subagent (`subagentStart`/`subagentStop`), ou chaîne de la commande shell (`beforeShellExecution`/`afterShellExecution`) |

### 1.2 Événements disponibles (liste complète)

Hooks « agent » : `sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `preCompact`, `stop`, `afterAgentResponse`, `afterAgentThought`.
Hooks « Tab » (complétions inline) : `beforeTabFileRead`, `afterTabFileEdit`.
Cycle de vie app : `workspaceOpen`.

### 1.3 JSON stdin commun à tous les hooks

```json
{
  "conversation_id": "string",
  "generation_id": "string",
  "model": "string",
  "model_id": "string (optionnel)",
  "model_params": [{ "id": "string", "value": "string" }],
  "hook_event_name": "string",
  "cursor_version": "string",
  "workspace_roots": ["/chemin/projet"],
  "user_email": "string | null",
  "transcript_path": "string | null"
}
```

Points clés pour AgentDash :
- `conversation_id` = le `composerId` retrouvable dans `state.vscdb` (**[HYPOTHÈSE]** forte : mêmes UUID observés côté DB, à confirmer en croisant un hook réel) ;
- `workspace_roots` = le lien session → projet, sans lecture DB ;
- `transcript_path` pointe vers le JSONL décrit en §2.6.

### 1.4 Entrées/sorties par événement (champs additionnels)

| Événement | stdin (ajouts) | stdout attendu |
|---|---|---|
| `beforeShellExecution` | `command`, `cwd`, `sandbox` (bool) | `{ "permission": "allow"\|"deny"\|"ask", "user_message"?, "agent_message"? }` |
| `afterShellExecution` | `command`, `output`, `duration` (ms), `sandbox` | — (observation) |
| `beforeMCPExecution` | `tool_name`, `tool_input` (JSON string), `url`? ou `command`? | `{ "permission": "allow"\|"deny"\|"ask", "user_message"?, "agent_message"? }` |
| `afterMCPExecution` | `tool_name`, `tool_input`, `result_json`, `duration` | — |
| `preToolUse` | `tool_name` (`Shell`/`Read`/`Write`/MCP/`Task`…), `tool_input`, `tool_use_id`, `cwd`, `agent_message` | `{ "permission": "allow"\|"deny", "user_message"?, "agent_message"?, "updated_input"? }` (pas de `ask` documenté ici) |
| `postToolUse` | `tool_name`, `tool_input`, `tool_output` (JSON string), `tool_use_id`, `cwd`, `duration` | `{ "updated_mcp_tool_output"?, "additional_context"? }` |
| `postToolUseFailure` | idem + `error_message`, `failure_type` (`timeout`\|`error`\|`permission_denied`), `duration`, `is_interrupt` | — |
| `beforeReadFile` | `file_path`, `content`, `attachments[] {type: file\|rule, file_path}` | `{ "permission": "allow"\|"deny", "user_message"? }` |
| `afterFileEdit` | `file_path`, `edits[] {old_string, new_string}` | — |
| `beforeSubmitPrompt` | `prompt`, `attachments[]` | `{ "continue": bool, "user_message"? }` |
| `stop` | `status` (`completed`\|`aborted`\|`error`), `loop_count` | `{ "followup_message"? }` (relance l'agent, borné par `loop_limit`) |
| `afterAgentResponse` | `text` (message assistant complet) | — |
| `afterAgentThought` | `text`, `duration_ms`? | — |
| `sessionStart` | `session_id`, `is_background_agent`, `composer_mode`? (`agent`\|`ask`\|`edit`) | `{ "env"?, "additional_context"? }` |
| `sessionEnd` | `session_id`, `reason` (`completed`\|`aborted`\|`error`\|`window_close`\|`user_close`), `duration_ms`, `is_background_agent`, `final_status`, `error_message`? | fire-and-forget |
| `subagentStart` | `subagent_id`, `subagent_type` (`generalPurpose`\|`explore`\|`shell`…), `task`, `parent_conversation_id`, `tool_call_id`, `subagent_model`, `is_parallel_worker`, `git_branch`? | `{ "permission": "allow"\|"deny", "user_message"? }` |
| `subagentStop` | `subagent_type`, `status`, `task`, `description`, `summary`, `duration_ms`, `message_count`, `tool_call_count`, `loop_count`, `modified_files[]`, `agent_transcript_path` | `{ "followup_message"? }` |
| `preCompact` | `trigger` (`auto`\|`manual`), `context_usage_percent`, `context_tokens`, `context_window_size`, `message_count`, `messages_to_compact`, `is_first_compaction` | `{ "user_message"? }` (observation seule) |
| `beforeTabFileRead` | `file_path`, `content` | `{ "permission": "allow"\|"deny" }` |
| `afterTabFileEdit` | `file_path`, `edits[] {old_string, new_string, range{...}, old_line, new_line}` | — |
| `workspaceOpen` | — | `{ "pluginPaths"?: [string] }` |

### 1.5 Modèle d'exécution

- Script shell : JSON sur stdin → JSON sur stdout.
- Codes de sortie : `0` = succès (utiliser le JSON stdout) ; `2` = bloquer l'action ; autre = échec (fail-open par défaut).
- Variables d'environnement fournies : `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`, `CURSOR_CODE_REMOTE`, et un alias `CLAUDE_PROJECT_DIR`.
- Debug : onglet **Hooks** dans « Customize » + canal de sortie « Hooks » dans Cursor.
- Cloud agents : seuls certains hooks tournent (depuis `.cursor/hooks.json` du repo) ; `stop`, `sessionStart/End`, `beforeSubmitPrompt`, `beforeMCPExecution`… ne sont **pas** supportés en cloud. Hors scope AgentDash (sessions locales), mais à savoir.

### 1.6 Limites par rapport à Claude Code (impact produit)

| Capacité | Claude Code (hooks natifs) | Cursor (hooks) |
|---|---|---|
| Permission allow/deny/ask avant exécution | Oui (`PreToolUse` → `permissionDecision`) | Oui (`beforeShellExecution`, `beforeMCPExecution`, `preToolUse`) |
| **Always allow** persistant depuis la réponse | Oui (mécanisme de règles de permission de Claude Code) | **Non documenté** : aucune sortie de hook ne crée de règle persistante → cohérent avec AgentPeek qui réserve ⌥A à Claude Code. **[VÉRIFIÉ — doc]** |
| Répondre à une **question** de l'agent depuis l'extérieur | Oui (tool `AskUserQuestion` interceptable) | Le tool `ask_question` existe (observé en DB, §2.5) mais **aucun hook documenté ne permet d'y répondre** → réponse inline aux questions Cursor probablement impossible. **[HYPOTHÈSE]** (tester si `preToolUse` se déclenche sur `ask_question` et si `updated_input`/deny a un effet exploitable) |
| Approuver/rejeter un **plan** depuis l'extérieur | Oui (plan mode + permission) | Tool `create_plan` observé + flag `hasPendingPlan` en DB, mais pas de sortie de hook « approve plan » documentée. **[HYPOTHÈSE]** |
| Turn terminé | `Stop` hook | `stop` hook (+ `sessionEnd`) — équivalent |
| Texte des réponses en continu | transcripts JSONL | `afterAgentResponse` / `afterAgentThought` + transcript JSONL |
| Compteur de tokens en direct | transcripts (usage par message) | **Aucun champ de tokens dans les hooks** ; `preCompact` donne `context_tokens` ponctuellement ; la DB donne `contextTokensUsed` (§2.4). Tokens par tour : source à valider. **[HYPOTHÈSE]** |

---

## 2. Sessions Cursor sur disque (schéma réellement observé)

### 2.1 Vue d'ensemble des emplacements **[VÉRIFIÉ — local]**

| Chemin | Contenu |
|---|---|
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | SQLite (ici **1,0 Go**, mode WAL : fichiers `-wal`/`-shm` présents). Tables `ItemTable` et `cursorDiskKV` (schéma : `key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB`). **Toutes les conversations d'agent sont ici** (stockage global, pas par workspace) |
| `~/Library/Application Support/Cursor/User/globalStorage/storage.json` | IDs machine/télémétrie, état des fenêtres (`backupWorkspaces`, `windowsState`) — pas de userId exploitable |
| `~/Library/Application Support/Cursor/User/workspaceStorage/<hash>/workspace.json` | `{ "folder": "file:///chemin/du/projet" }` → mappe le hash de workspace vers le dossier |
| `~/Library/Application Support/Cursor/User/workspaceStorage/<hash>/state.vscdb` | Petit SQLite par workspace. `composer.composerData` n'y contient plus que `{selectedComposerIds, lastFocusedComposerIds, hasMigrated…}` : les données ont **migré vers le globalStorage** |
| `~/Library/Application Support/Cursor/sentry/scope_v3.json` | `scope.user.id` (45 caractères, format `<provider>\|user_…`) et `scope.user.email` → source alternative du userId |
| `~/.cursor/projects/<slug>/` | Artefacts par projet, slug = chemin absolu avec `/` remplacés par `-` (ex. `Users-bastien-Documents-medmed`). Sous-dossiers observés : `terminals/`, `agent-transcripts/`, `mcps/`, `canvases/`, `uploads/`, `assets/`, `agent-tools/` |
| `~/.cursor/ai-tracking/ai-code-tracking.db` | SQLite d'attribution IA du code (§2.7) |
| `~/.cursor/plans/*.plan.md` | Plans en Markdown + frontmatter YAML (§2.8) |
| `~/.cursor/ide_state.json` | `{ "recentlyViewedFiles": [{relativePath, absolutePath}] }` |
| Autres : `~/.cursor/mcp.json`, `~/.cursor/extensions/`, `~/.cursor/skills-cursor/`, `~/.cursor/plugins/`, `~/.cursor/argv.json`, `~/.cursor/blocklist`, `~/.cursor/unified_repo_list.json`, `~/.cursor/debug-logs/` | Config MCP, extensions, skills, plugins (cibles Quick Routes) |

### 2.2 `ItemTable` (globalStorage) — clés utiles **[VÉRIFIÉ — local]** (336 lignes au total)

| Clé | Contenu |
|---|---|
| `composer.composerHeaders` | **Le registre central des sessions** : `{ "allComposers": [ … ] }` (124 entrées observées). Cf. §2.3 |
| `cursorAuth/accessToken`, `cursorAuth/refreshToken` | JWT (424 caractères chacun). Cf. §3.1 |
| `cursorAuth/cachedEmail`, `cursorAuth/cachedSignUpType`, `cursorAuth/stripeMembershipType` | e-mail, `Google`, `enterprise` (valeurs de cette machine) |
| `aiCodeTracking.dailyStats.v1.5.<YYYY-MM-DD>` | `{ date, tabSuggestedLines, tabAcceptedLines, composerSuggestedLines, composerAcceptedLines }` — **statistiques jour par jour** locales (une clé par jour actif) |
| `glass.localAgentProjectMembership.v1` | dict `composerId (uuid) → projectId (uuid)` — rattachement conversation → « projet » de la nouvelle UI « glass » |
| `composer.planRegistry`, `composer.planRedirects`, `composer.planMigrationToHomeDirCompleted` | registre des plans (lié à `~/.cursor/plans`) |
| `cloudAgentRepository.agents`, `backgroundComposer.windowBcMapping` | agents cloud/background |
| `anysphere.cursor-always-local`, `anysphere.cursor-mcp`, `mcpOAuth.*`, `secret://…` | données d'extensions internes et tokens OAuth MCP (à ne jamais lire) |

Remarque : de nombreuses clés préfixées `glass.` / `cursor/glass.*` correspondent à la nouvelle interface « agents » de Cursor (fenêtre dédiée). Les onglets par workspace : `cursor/glass.tabs.v2/<workspaceHash>/…`.

### 2.3 Registre `composer.composerHeaders.allComposers[]` **[VÉRIFIÉ — local]**

Champs observés (taux de présence sur 124 entrées) — c'est la source idéale pour la **liste des sessions** :

| Champ | Présence | Signification observée |
|---|---|---|
| `composerId` | 124/124 | UUID de la conversation |
| `type` | 124/124 | `"head"` observé |
| `name` | 89/124 | Titre de la session (généré) ; absent sur les brouillons |
| `createdAt`, `lastUpdatedAt` | 124 / 64 | epoch **millisecondes** |
| `conversationCheckpointLastUpdatedAt` | 86/124 | epoch ms — bouge pendant l'activité |
| `unifiedMode` | 124/124 | `agent` \| `chat` \| `edit` \| `plan` \| `debug` (valeurs observées) |
| `forceMode` | 124/124 | `chat` \| `edit` observés |
| `hasBlockingPendingActions` | 95/124 | **true = une permission/action bloquante attend l'utilisateur** |
| `hasPendingPlan` | 87/124 | **true = un plan attend approbation** |
| `hasUnreadMessages` | 122/124 | messages non lus |
| `contextUsagePercent` | 86/124 | % de la fenêtre de contexte utilisé (float) |
| `totalLinesAdded`, `totalLinesRemoved` | 119/124 | **stats de diff cumulées** de la session |
| `filesChangedCount` | 86/124 | nombre de fichiers touchés |
| `subtitle` | 86/124 | **dernière activité en langage clair** (ex. « Edited package.json ») — équivalent direct de la ligne « activité récente » d'AgentPeek |
| `workspaceIdentifier` | 124/124 | `{ id: <workspaceHash>, uri: { fsPath, external, path, scheme } }` → **projet** |
| `trackedGitRepos` | 114/124 | `[{ repoPath, branches: [{ branchName, lastInteractionAt }] }]` |
| `subagentInfo` | 26/124 | présent si la conversation **est un subagent** : `{ subagentType (int), subagentTypeName ("explore"…), parentComposerId, rootParentConversationId, toolCallId, toolCallIdHistory[], parentRequestId, rootParentRequestId, conversationLengthAtSpawn, additionalData }` |
| `isArchived`, `isDraft`, `isWorktree`, `worktreeStartedReadOnly`, `isSpec`, `isProject`, `isBestOfNSubcomposer`, `numSubComposers`, `referencedPlans`, `branches`, `draftTarget`, `hasBeenInSidebar` | variable | drapeaux divers |

### 2.4 `cursorDiskKV` — clé `composerData:<composerId>` **[VÉRIFIÉ — local]**

122 243 lignes au total dans `cursorDiskKV`. Répartition des préfixes : `bubbleId:` (66 777), `agentKv:blob:<sha256>` (52 399), `composer.content.<sha256>` (~1 500), `ofsContent:` (443), `checkpointId:` (434), `codeBlockPartialInlineDiffFates:` (426), `composerData:` (169), `inlineDiff:` (59), `codeBlockDiff:` (13), `messageRequestContext:` (12), `composerVirtualRowHeights:` (3).

`composerData:<uuid>` (version de schéma observée `_v: 16`) — champs principaux :

| Champ | Observé | Usage AgentDash |
|---|---|---|
| `composerId`, `name`, `subtitle`, `createdAt`, `lastUpdatedAt` | uuid, str, str, ms, ms | identité de session |
| `status` | `completed` \| `none` \| `aborted` (répartition observée : 88 completed, 69 none, 7 aborted, 5 vides) | état de fin de tour — **`none` couvre à la fois « jamais lancé » et « en cours »** |
| `unifiedMode` / `forceMode` | `agent`/`chat`/`edit`/`plan`/`debug` | type de session |
| `isAgentic` | bool | vrai pour le mode agent |
| `agentBackend` | `"cursor-agent"` observé | backend d'exécution |
| `fullConversationHeadersOnly[]` | `{ bubbleId, type (1=user, 2=assistant), serverBubbleId?, contentHeightHint?, grouping { hasText, hasThinking, thinkingDurationMs, isRenderable, capabilityType… } }` — 1 932 entrées sur la plus grosse session | **ordre des messages** ; jointure vers `bubbleId:` |
| `generatingBubbleIds[]` | vide au repos | **non vide = génération en cours** **[HYPOTHÈSE]** (nom explicite, mais jamais observé rempli à froid — vérifier pendant un tour actif) |
| `contextTokensUsed`, `contextTokenLimit`, `contextUsagePercent` | ex. 217 196 / 300 000 / 72,4 | jauge de contexte |
| `promptTokenBreakdown` | `{ totalUsedTokens, maxTokens, categories: [{id, label, estimatedTokens}] }` (`system_prompt`, `tools`, `rules`, `skills`, `mcp`, …) | détail du contexte |
| `totalLinesAdded`, `totalLinesRemoved`, `filesChangedCount`, `addedFiles`, `removedFiles`, `newlyCreatedFiles[]` | int | stats de diff |
| `todos[]` | `{ id, content, status, dependencies }` | liste de tâches de l'agent |
| `workspaceIdentifier` | comme §2.3 | projet |
| `subComposerIds[]`, `subagentComposerIds[]` | uuid[] | subagents |
| `stopHookLoopCount` | int | compteur lié au hook `stop` |
| `usageData` | `{}` observé partout | inutilisable (vide) |
| `conversationState` | grosse chaîne binaire/base64 (~115 Ko) | opaque, ignorer |
| `modelConfig` | `{ modelName, maxMode, selectedModels[] {modelId, parameters[]} }` | modèle |
| `blobEncryptionKey`, `speculativeSummarizationEncryptionKey` | str(44) | clés de chiffrement de blobs (les `composer.content.<sha>` / `agentKv:blob:` sont probablement chiffrés → ne pas compter dessus) **[HYPOTHÈSE]** |
| `queueItems[]`, `isQueueExpanded`, `isDraft`, `isArchived`… | divers | file de prompts en attente, drapeaux UI |

### 2.5 `cursorDiskKV` — clé `bubbleId:<composerId>:<bubbleId>` **[VÉRIFIÉ — local]**

Un enregistrement JSON par « bulle » (message). Champs principaux :

- `type` : `1` = utilisateur, `2` = assistant.
- `text` / `richText` : contenu du message (le texte assistant est présent en clair).
- `toolFormerData` : **le tool call** porté par la bulle :
  `{ tool (int), name (string), status, params (JSON string), rawArgs (JSON string), result (JSON string), toolCallId, modelCallId, toolIndex, toolCallBinary }`.
  Statuts observés sur 37 969 tool calls : `completed` (37 371), `error` (544), `cancelled` (49), **`loading` (5)** → `loading` = tool call en cours.
  Noms d'outils observés : `read_file_v2`, `run_terminal_command_v2`, `edit_file_v2`, `ripgrep_raw_search`, `read_lints`, `todo_write`, `glob_file_search`, `ask_question`, `task_v2` (subagents), `delete_file`, `semantic_search_full`, `create_plan`, `switch_mode`, `await`, et `mcp-<serveur>-<tool>` pour les MCP.
- `tokenCount` : `{ inputTokens, outputTokens }` — **quasi toujours 0** (11 bulles non nulles sur 66 777). Ne pas s'appuyer dessus pour l'usage. **[VÉRIFIÉ — local]**
- `isThought`, `allThinkingBlocks`, `thinking` : blocs de réflexion.
- `createdAt`, `requestId`, `checkpointId`, `modelInfo { modelName }`, `unifiedMode`, `isAgentic`, `todos`, `capabilities`, etc. (≈ 80 champs, la plupart vides).

Clés associées : `messageRequestContext:<composerId>:<requestId>`, `checkpointId:<composerId>:<uuid>` (checkpoints de fichiers), `ofsContent:<uuid>:file://…` (snapshots de contenu de fichier), `inlineDiff:`/`codeBlockDiff:` (diffs d'application).

### 2.6 Transcripts JSONL : `~/.cursor/projects/<slug>/agent-transcripts/<composerId>/<composerId>.jsonl` **[VÉRIFIÉ — local]**

- Un dossier par `composerId` (≈ 60 observés pour un projet actif) ; c'est le `transcript_path` fourni aux hooks (`CURSOR_TRANSCRIPT_PATH`).
- Format ligne à ligne, **proche du format de messages Anthropic** :
  - `{ "role": "user"|"assistant", "message": { "content": [ { "type": "text", … } | { "type": "tool_use", "name": "Read", "input": {…} } ] } }` — noms d'outils **normalisés** ici (`Read`, etc., différents des noms internes de la DB) ;
  - ligne terminale : `{ "type": "turn_ended", "status": "success"|"error", "error": … }`. Statuts observés : `success` (6), `error` (2), et 22 fichiers dont la dernière ligne est un message assistant (tour interrompu ou en cours).
- **Attention** : tous les projets n'ont pas `agent-transcripts/` (seuls certains modes/versions l'écrivent). Ne pas en faire la source unique. **[VÉRIFIÉ — local]**

### 2.7 `~/.cursor/ai-tracking/ai-code-tracking.db` **[VÉRIFIÉ — local]**

Tables : 
- `ai_code_hashes(hash PK, source, fileExtension, fileName, requestId, conversationId, timestamp, model, createdAt)` ;
- `scored_commits(commitHash, branchName, scoredAt, linesAdded, linesDeleted, tabLinesAdded, tabLinesDeleted, composerLinesAdded, composerLinesDeleted, humanLinesAdded, humanLinesDeleted, blankLinesAdded, blankLinesDeleted, commitMessage, commitDate, v1AiPercentage, v2AiPercentage)` ;
- `conversation_summaries(conversationId PK, title, tldr, overview, summaryBullets, model, mode, updatedAt)` — **résumés de conversation tout prêts** (titre + tl;dr) ;
- `tracked_file_content`, `ai_deleted_files`, `tracking_state`.

Utile pour : le % de code IA par commit, et `conversation_summaries` comme source de titres/résumés de session de secours.

### 2.8 `~/.cursor/plans/*.plan.md` **[VÉRIFIÉ — local]**

Nommage : `<slug_du_titre>_<8 hex>.plan.md`. Format : frontmatter YAML + corps Markdown :

```markdown
---
name: <titre du plan>
overview: <résumé une phrase>
todos:
  - id: <slug>
    content: <description>
    status: completed | pending | …
isProject: false
---

# <Titre>
<corps markdown du plan>
```

Lien plan ↔ conversation : via `composer.planRegistry` / `referencedPlans` (ItemTable) — structure exacte à confirmer. **[HYPOTHÈSE]**

### 2.9 `~/.cursor/projects/<slug>/terminals/<n>.txt` **[VÉRIFIÉ — local]**

Frontmatter YAML + sortie brute du terminal de l'agent :

```
---
pid: 128
cwd: /Users/bastien/Documents/macos-ai-dashboard
last_command: |
  <dernière commande multi-lignes>
last_exit_code: 0
---
<sortie du terminal>
```

Parfait pour « détails du process » et l'activité shell récente par projet.

---

## 3. Usage mensuel Cursor

### 3.1 Récupération du token de session local

- `ItemTable` de `state.vscdb` (globalStorage) contient `cursorAuth/accessToken` et `cursorAuth/refreshToken`. **[VÉRIFIÉ — local]**
- L'`accessToken` est un **JWT HS256** : `iss = https://authentication.cursor.sh`, `aud = https://cursor.com`, `scope = openid profile email offline_access`, `sub = "<provider>|user_<id>"` (ex. provider `google-oauth2`), durée de vie très longue (≈ 56 ans entre `iat` et `exp` sur cette machine). **[VÉRIFIÉ — local]** (structure inspectée sans divulguer la valeur)
- Construction du cookie (méthode de `Dwtexe/cursor-stats`, code lu) : **[VÉRIFIÉ — OSS]**
  ```
  userId       = jwt.sub.split('|')[1]        // "user_…"
  sessionToken = `${userId}%3A%3A${accessToken}`
  Cookie: WorkosCursorSessionToken=<sessionToken>
  ```
- Sources alternatives du userId : `~/Library/Application Support/Cursor/sentry/scope_v3.json` → `scope.user.id` (format `<provider>|user_…`) et `scope.user.email`. **[VÉRIFIÉ — local]** (utilisé par `Tendo33/cursor-usage-tracker` **[VÉRIFIÉ — OSS]**)
- En-têtes recommandés par l'extension Raycast `cursor-costs` (code lu) pour passer les protections : `User-Agent` Safari, `Origin: https://cursor.com`, `Referer: https://cursor.com/dashboard?tab=usage`, `Sec-Fetch-*`. **[VÉRIFIÉ — OSS]** (nécessité réelle **[HYPOTHÈSE]**)

C'est exactement le modèle « lecture via la session Mac existante, pas de login séparé » d'AgentPeek.

### 3.2 Endpoints (non officiels, mêmes endpoints que le dashboard web — **sujets à changement**)

Aucune requête réelle n'a été faite ; formats issus de code open-source lu et de la doc communautaire.

| Endpoint | Méthode / corps | Réponse (champs) | Statut |
|---|---|---|---|
| `https://cursor.com/api/usage-summary` | GET | `billingCycleStart` / `billingCycleEnd` (dates ISO ou epoch ms en string), `membershipType`, `limitType` (`user`\|`team`), `isUnlimited`, `individualUsage.plan { enabled, used, limit, remaining (cents), breakdown { included, bonus, total }, autoPercentUsed?, apiPercentUsed?, totalPercentUsed? }`, `individualUsage.onDemand { enabled, used, limit, remaining }`, `teamUsage` | **[VÉRIFIÉ — OSS]** (Raycast `cursor-costs`, types + appels lus) |
| `https://cursor.com/api/dashboard/get-aggregated-usage-events` | POST `{ "teamId": -1, "startDate": <ms>, "endDate": <ms> }` | `aggregations[] { modelIntent, inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, totalCents }`, `totalInputTokens`, `totalOutputTokens`, `totalCacheWriteTokens`, `totalCacheReadTokens`, `totalCostCents` | **[VÉRIFIÉ — OSS]** (idem) |
| `https://cursor.com/api/dashboard/get-monthly-invoice` | POST `{ "month": n, "year": n, "includeUsageEvents": false }` | `items[] { cents, description }`, `hasUnpaidMidMonthInvoice` | **[VÉRIFIÉ — OSS]** (`Dwtexe/cursor-stats`) |
| `https://cursor.com/api/usage?user=<userId>` | GET | legacy « requests » : objet par modèle (ex. `gpt-4`) avec `numRequests`, `maxRequestUsage`, `numTokens` ; `startOfMonth` | **[VÉRIFIÉ — OSS]** — endpoint historique, AgentPeek l'a remplacé (« replaces the legacy feed », v0.2.10) |
| `https://cursor.com/api/auth/stripe` | GET | métadonnées d'abonnement (statut `active`/`trialing`/…) | **[VÉRIFIÉ — OSS]** |
| Divers : `get-hard-limit`, `set-hard-limit`, `get-usage-based-premium-requests`, `export-usage-events-csv`, `api2.cursor.sh/...GetCurrentPeriodUsage` | POST/GET | limites de dépense, export CSV | **[VÉRIFIÉ — OSS]**, utilité secondaire |

Officiel mais hors périmètre individuel : Admin API / Analytics API d'équipe (`/teams/spend`, `/teams/daily-usage-data`, `/teams/filtered-usage-events`) — nécessite un rôle admin d'équipe, non pertinent pour AgentDash mono-utilisateur.

### 3.3 Notions Spend / Weighted / Auto / API et « $X of $Y »

Contexte tarifaire (docs + presse spécialisée, juin 2026) : les plans individuels Cursor comportent **deux budgets mensuels** — un pool « **Auto + Composer** » et un pool « **API** » (modèles tiers décomptés au prix API du fournisseur, donc **pondérés** par modèle). Le dashboard affiche la progression vers chaque limite. **[VÉRIFIÉ — doc/presse]**

Correspondance proposée pour les 4 mesures d'AgentPeek (à valider avec de vraies réponses API) :

| Mesure AgentPeek | Source probable | Statut |
|---|---|---|
| **Spend** | `individualUsage.plan.used` / `limit` (cents) → « $X of $Y » ; ou `totalCostCents` de `get-aggregated-usage-events` sur le cycle | **[HYPOTHÈSE]** |
| **Weighted** | `totalPercentUsed` (usage inclus combiné, pondéré aux prix API) | **[HYPOTHÈSE]** |
| **Auto** | `autoPercentUsed` (pool Auto + Composer) | **[HYPOTHÈSE]** |
| **API** | `apiPercentUsed` (pool API / modèles nommés) | **[HYPOTHÈSE]** |

« $X of $Y » : `used`/`limit` sont en **cents** (ex. 1207 = 12,07 $). Le `membershipType` (et `cursorAuth/stripeMembershipType` local : `free`, `pro`, `business`, `enterprise`…) conditionne l'existence d'une limite en dollars (`isUnlimited`, `limit` null). Date de reset = `billingCycleEnd`.

### 3.4 Projets open-source de référence (étudiés)

| Projet | Enseignements |
|---|---|
| `Dwtexe/cursor-stats` (extension VS Code/Cursor) | extraction du token depuis `state.vscdb`, construction du cookie, `get-monthly-invoice`, `get-hard-limit`, `/api/usage` legacy, gestion équipe (`get-team-spend`, `spendCents`) |
| Raycast `extensions/cursor-costs` (menu bar macOS) | `usage-summary` + `get-aggregated-usage-events` avec `teamId: -1`, types TS complets des réponses, en-têtes anti-bot, cycle de facturation vs mois calendaire |
| `Tendo33/cursor-usage-tracker` | fallback userId via `sentry/scope_v3.json`, `GetCurrentPeriodUsage` (api2.cursor.sh), `/api/auth/stripe` |
| `robinebers/openusage` (menu bar) | rafraîchissement des tokens persisté en retour, refresh sur 401/403, imputation de coût par jour via prix des modèles |
| Autres trouvés : `cursorusage.com`, `Sammy970/cursor-usage-extension`, `lixwen/cursor-usage-monitor`, `Ittipong/cursor-price-tracking`, `junhoyeo/tokscale`, `RosemyneH/cursor-waybar` | confirment tous le couple cookie WorkOS + endpoints dashboard |

---

## 4. Détection d'état (executing / waiting / idle) et rattachement au projet

### 4.1 Machine à états proposée (hooks = source primaire, temps réel)

| Transition | Événement hook |
|---|---|
| → **executing** | `beforeSubmitPrompt` (tour lancé), `sessionStart`, tout `preToolUse`/`beforeShellExecution`/`afterShellExecution`/`afterFileEdit` (activité) |
| → **thinking** | `afterAgentThought` (fin d'un bloc de réflexion ; « thinking » = entre le début du tour et la prochaine activité d'outil) **[HYPOTHÈSE]** : il n'existe pas d'événement « thinking commence », il faut l'inférer |
| → **waiting (permission)** | le script de hook `beforeShellExecution`/`beforeMCPExecution` d'AgentDash **bloque** en attendant la décision de l'utilisateur dans le notch, puis répond `allow`/`deny` (avec `user_message` pour « Deny with feedback ») ; s'il expire ou si l'utilisateur veut décider dans Cursor, répondre `ask` pour rendre la main à l'UI Cursor. **[HYPOTHÈSE]** clé : vérifier que le timeout laisse le temps de répondre, sinon augmenter `timeout` dans hooks.json |
| → **idle / done** | `stop` (`status: completed`/`aborted`/`error`), `sessionEnd` |
| subagents | `subagentStart` / `subagentStop` (avec `modified_files`, `duration_ms`, compteurs) |

### 4.2 Sources secondaires (fichiers/DB — réconciliation et sessions démarrées avant AgentDash)

- `composer.composerHeaders.allComposers[]` (ItemTable, globalStorage) : `hasBlockingPendingActions` (waiting-permission), `hasPendingPlan` (waiting-plan), `lastUpdatedAt`/`conversationCheckpointLastUpdatedAt` (fraîcheur → idle si ancien), `subtitle` (dernière activité), `hasUnreadMessages`. **[VÉRIFIÉ — local]** (valeurs à corréler avec l'état réel en dynamique : **[HYPOTHÈSE]**)
- `composerData:<id>.status` : `none` pendant/avant le tour, `completed`/`aborted` après. `generatingBubbleIds[]` non vide pendant la génération. **[HYPOTHÈSE]** (à observer en live)
- Dernier `bubbleId` avec `toolFormerData.status == "loading"` → tool call en cours. **[VÉRIFIÉ — local]** (5 occurrences résiduelles observées, donc le flag existe bien au repos aussi : filtrer par fraîcheur)
- Transcript JSONL : dernière ligne `turn_ended` = tour fini ; dernière ligne `assistant` = tour en cours ou interrompu. **[VÉRIFIÉ — local]**
- Détection de vie du processus : `pid` dans `terminals/<n>.txt` + process `Cursor`/`cursor-agent` vivants (`kill -0`). **[HYPOTHÈSE]**

### 4.3 Rattachement session → projet

1. **Hooks** : `workspace_roots[]` (stdin) ou `CURSOR_PROJECT_DIR` — direct et fiable.
2. **DB** : `composerData:<id>.workspaceIdentifier.uri.fsPath` (et `.id` = hash de `workspaceStorage/<hash>/workspace.json → folder`). **[VÉRIFIÉ — local]**
3. **Repos Git** : `trackedGitRepos[].repoPath` + branche. **[VÉRIFIÉ — local]**
4. `~/.cursor/projects/<slug>` : slug = chemin avec `-` (collision possible si le chemin contient déjà des tirets → préférer 1 et 2).

---

## Décisions d'implémentation recommandées

1. **Hooks d'abord, DB ensuite.** Installer `~/.cursor/hooks.json` (version 1) avec un binaire/script AgentDash sur : `beforeSubmitPrompt`, `beforeShellExecution`, `beforeMCPExecution`, `afterShellExecution`, `afterFileEdit`, `afterAgentResponse`, `afterAgentThought`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `sessionStart`, `sessionEnd`, `stop`. Le script relaie le JSON stdin vers l'app via **socket Unix** (ou XPC) et écrit la réponse sur stdout ; timeout explicite long (`timeout` par hook) pour les hooks de permission.
2. **Installation non destructive** : fusionner avec un `hooks.json` existant (préserver les hooks tiers), et statut « Ready » = fichier présent + entrée AgentDash intacte + script exécutable (pour l'onglet Doctor).
3. **Permissions inline Cursor** : répondre `allow`/`deny` (+ `user_message` pour « Deny with feedback ») depuis le hook bloquant ; fallback `ask` vers l'UI Cursor. Pas de « Always Allow » pour Cursor (aligné sur AgentPeek : ⌥A réservé à Claude Code).
4. **Lecture de `state.vscdb` en direct, sans copie** : ouvrir en **lecture seule** (`SQLITE_OPEN_READONLY`, WAL permet lecteurs concurrents), requêtes ciblées par clé (`ItemTable.composer.composerHeaders`, `composerData:<id>`, `bubbleId:<id>:%`) — jamais de scan complet du fichier de 1 Go ; retry sur `SQLITE_BUSY` ; ne **jamais** utiliser `immutable=1` sur la base vivante.
5. **Liste de sessions** = `composer.composerHeaders.allComposers` (poll léger, ~1–2 s quand une session est active) enrichie en temps réel par les hooks ; clé de déduplication = `composerId` (= `conversation_id` des hooks, à confirmer) ; masquer `isDraft`/`isArchived`/`isBestOfNSubcomposer` ; rattacher les entrées avec `subagentInfo` à leur `rootParentConversationId`.
6. **Timeline des tool calls** : événements hooks en direct + relecture historique via `fullConversationHeadersOnly` → `bubbleId:*` (champ `toolFormerData`), avec table de traduction des noms d'outils (`run_terminal_command_v2` → « Ran command », etc.).
7. **Usage mensuel** : lire `cursorAuth/accessToken` dans `ItemTable`, dériver `userId` du `sub` JWT, cookie `WorkosCursorSessionToken=<userId>%3A%3A<jwt>` ; appeler `usage-summary` (jauges Spend/Weighted/Auto/API + cycle de facturation) et `get-aggregated-usage-events` (`teamId: -1`, du `billingCycleStart` à maintenant) pour le détail par modèle ; retenir la dernière valeur en cas d'échec (comportement AgentPeek) ; jamais d'écriture, jamais d'envoi du token ailleurs que cursor.com.
8. **Stats journalières** : source locale gratuite `aiCodeTracking.dailyStats.v1.5.*` (lignes suggérées/acceptées) + agrégats quotidiens de `get-aggregated-usage-events` si besoin de dollars/jour.
9. **Tokens par session Cursor** : ne pas promettre l'équivalent Claude Code au départ — `tokenCount` des bulles est vide ; utiliser `contextTokensUsed`/`promptTokenBreakdown` (contexte) et, si nécessaire, les événements d'usage réseau pour le coût. À trancher après le point « Hypothèses » n° 3.
10. **Plans et questions Cursor** : afficher (via `hasPendingPlan`, tool `ask_question`/`create_plan` détecté par `preToolUse`) mais **ne pas** promettre approve/reject ni réponse inline tant que l'hypothèse n° 4 n'est pas tranchée.

## Hypothèses restant à valider (en implémentation)

1. **`conversation_id` (hooks) == `composerId` (state.vscdb)** — corréler en déclenchant un hook réel.
2. **Timeout par défaut des hooks** (« platform default » non chiffré) : mesurer, et vérifier qu'un `timeout` élevé permet à un hook de permission de bloquer plusieurs minutes sans être tué ni faire dériver l'agent (fail-open !). Vérifier aussi le comportement quand plusieurs scripts répondent des permissions contradictoires.
3. **Comptage de tokens par tour** : confirmer qu'aucune source locale fiable n'existe (bulles à 0) ; sinon, dériver du réseau (`get-aggregated-usage-events` par période courte) ou renoncer au live mid-turn pour Cursor.
4. **Questions/plans** : `preToolUse` se déclenche-t-il sur `ask_question`/`create_plan` ? Une réponse `updated_input`/`deny` permet-elle une interaction utile ? Sinon, où l'état « waiting-question » est-il visible en DB (bulle `ask_question` avec `toolFormerData.status == "loading"` ?).
5. **Fiabilité dynamique de `hasBlockingPendingActions` / `hasPendingPlan` / `generatingBubbleIds` / `status`** : fréquence d'écriture réelle pendant un tour (la DB est-elle flushée en continu ou par lots ?) — conditionne la latence de l'état sans hooks.
6. **Sessions du CLI `cursor-agent`** (non installé ici) : écrit-il dans le même `state.vscdb` / `~/.cursor/projects`, et les hooks `~/.cursor/hooks.json` s'y appliquent-ils ? (`agentBackend: "cursor-agent"` observé côté app laisse penser que le backend est partagé.)
7. **Endpoints usage** : formats exacts de `usage-summary` selon le plan (free/pro/ultra/business/enterprise — cette machine est « enterprise », `isUnlimited` possible), nécessité réelle des en-têtes anti-bot, comportement 401/403 et stratégie de refresh (utiliser `cursorAuth/refreshToken` ? openusage le fait).
8. **Correspondance Spend/Weighted/Auto/API ↔ champs API** (tableau §3.3) — à confirmer sur de vraies réponses.
9. **Chiffrement des blobs** `composer.content.<sha>` / `agentKv:blob:` (présence de `blobEncryptionKey`) : vérifier si le texte des réponses est toujours disponible en clair dans `bubbleId:*` sur les versions récentes.
10. **Versions minimales** : la doc hooks ne précise pas de version requise ; définir Cursor ≥ 3.x comme prérequis testé (3.7.27 validé ici) et prévoir la détection de schéma (`_v` observé = 16).
