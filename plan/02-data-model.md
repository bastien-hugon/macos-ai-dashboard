# AgentDash (nom provisoire) — Modèle de données

> Rédigé le 3 juillet 2026, en cohérence avec `plan/01-architecture.md`. Tous les types vivent dans `DashCore` sauf mention contraire. Pseudo-Swift : structs/enums `Sendable`, mutations uniquement dans les stores `@MainActor`.
> Convention : **[VÉRIFIÉ]** = adossé à un fait des recherches ; **[HYPOTHÈSE]** = mapping à valider en implémentation (renvoi vers la liste d'hypothèses du document de recherche concerné).

---

## 1. Identité des agents et des sessions

```swift
enum AgentKind: String, Codable, Sendable {
    case claudeCode = "claude"
    case cursor     = "cursor"
    // Codex : hors scope du clone (AGENTPEEK_FEATURES.md §14). L'enum reste ouverte par design.
}

/// Identité STABLE d'une session — la clé de déduplication unique de tout le système.
struct SessionID: Hashable, Codable, Sendable {
    let agent: AgentKind
    /// Claude Code : `sessionId` (UUID) — présent dans les hooks, le registre ~/.claude/sessions/<pid>.json
    /// et chaque ligne de transcript [VÉRIFIÉ].
    /// Cursor : `composerId` (UUID) — clé de composerHeaders/composerData ; supposé == `conversation_id`
    /// des hooks [HYPOTHÈSE cursor n°1].
    let rawID: String
}

/// Environnement hôte de la session (colonne « terminal vs desktop app » d'AgentPeek).
enum SessionHost: Codable, Sendable {
    case terminal(program: TerminalProgram)   // via TERM_PROGRAM hérité par le hook [VÉRIFIÉ]
    case ide(IDEKind)                          // entrypoint "claude-vscode" [VÉRIFIÉ] ; Cursor app
    case desktopApp                            // entrypoint "claude-desktop-3p" [VÉRIFIÉ via issue GitHub]
    case unknown
}

enum TerminalProgram: String, Codable, Sendable {
    case appleTerminal = "Apple_Terminal", iterm = "iTerm.app", warp = "WarpTerminal"
    case ghostty = "ghostty", vscodeLike = "vscode", other = ""
}
enum IDEKind: String, Codable, Sendable { case cursor, vscode }
```

### 1.1 Règles de déduplication **[TRANCHÉ]**

1. **Clé unique** : `SessionID`. Toute source (hook, transcript, registre `~/.claude/sessions/`, `allComposers`, transcript Cursor) est résolue vers cette clé **avant** d'entrer dans `SessionStore` — il est structurellement impossible d'avoir deux lignes pour la même session.
2. **Registre PID Claude** : un fichier `~/.claude/sessions/<pid>.json` n'est pris en compte que si son PID est vivant (`kill(pid, 0)`) **et** que `proc_bsdinfo.pbi_start_tvsec` est cohérent avec `startedAt` (fichiers orphelins de crash possibles — hypothèse claude-code n°4). Deux fichiers PID portant le même `sessionId` (resume dans un autre process) → un seul `Session`, `pid` = le plus récent.
3. **Cursor** : masquer les composers `isDraft`, `isArchived`, `isBestOfNSubcomposer` ; une entrée avec `subagentInfo` n'est **pas** une session racine : rattachée à `rootParentConversationId` comme activité subagent [VÉRIFIÉ].
4. **Subagents Claude** (`isSidechain: true`, transcripts `<session>/subagents/…`) : jamais des sessions à part entière ; agrégés dans la timeline de la session parente [VÉRIFIÉ].
5. **Conflit de sources** : ordre de confiance pour un même champ = hook (temps réel) > registre/DB > transcript. Le champ `lastEventAt` porte l'horodatage de la source gagnante.

---

## 2. Session

```swift
struct Session: Identifiable, Sendable {
    var id: SessionID
    // — Identité affichée —
    var title: String?             // Claude : dernière entrée `ai-title` [VÉRIFIÉ] ; Cursor : `name` de composerHeaders
    var subtitle: String?          // activité récente en langage clair : dernier TimelineEvent résumé ;
                                   // Cursor : champ `subtitle` de composerHeaders en secours [VÉRIFIÉ]
    var projectPath: String        // Claude : cwd (hooks/registre, maj par CwdChanged) ;
                                   // Cursor : workspaceIdentifier.uri.fsPath / workspace_roots[0] [VÉRIFIÉ]
    var projectName: String        // basename(projectPath) — clé du tri « par projet »
    var gitBranch: String?
    var host: SessionHost
    var accountLabel: String?      // label de compte d'abonnement (cf. UsageAccount) [HYPOTHÈSE claude-code n°5]
    var model: String?             // dernier `message.model` (Claude) / modelConfig.modelName (Cursor)

    // — État —
    var state: SessionState
    var liveness: SessionLiveness
    var isStale: Bool              // executing/thinking sans événement depuis `stuckThresholdSeconds` :
                                   // NE change PAS `state`, déclenche la notification « stuck » (cf. §3.4)
    var permissionMode: String?    // Claude : default/plan/acceptEdits/auto/dontAsk/bypassPermissions [VÉRIFIÉ]
    var pendingPrompt: PendingPrompt?   // ≤ 1 prompt actionnable à la fois par session (modèle des agents)

    // — Métriques (affichées sur la carte) —
    var tokens: TokenTally
    var diff: DiffStats
    var filesTouchedCount: Int     // tool_use distincts Edit|Write|NotebookEdit par file_path [VÉRIFIÉ]
    var commandCount: Int          // tool_use Bash / run_terminal_command_v2
    var contextUsage: ContextUsage?    // Cursor : contextTokensUsed/limit [VÉRIFIÉ] ; Claude : v2 (compaction)
    var startedAt: Date            // base du « temps écoulé » affiché sur la carte (07 · REQ-SES-27)
    var lastEventAt: Date          // fraîcheur d'activité (tri, isStale) + entrée du GC (§7)

    // — Détail (session étendue) —
    var timeline: TimelineWindow   // fenêtre rendue (cap RAM, cf. 01-architecture.md §6) + curseur transcript
    var subagents: [SubagentActivity]
    var lastAssistantExcerpt: AttributedString?   // rendu Markdown, replié « Show more/less »
    var todos: [TodoItem]          // Cursor : composerData.todos ; Claude : attachments todo_reminder

    // — Plomberie —
    var pid: pid_t?                // Claude : registre sessions (cible du Kill) [VÉRIFIÉ] ; Cursor : nil (pas de Kill)
    var procStartTime: (sec: UInt64, usec: UInt64)?  // garde-fou anti-réutilisation de PID avant SIGTERM
    var transcriptPath: String?
    var isDismissed: Bool          // « sessions terminal silencieuses dismissables »
}

struct TokenTally: Sendable {
    // Claude : somme des `message.usage` des entrées assistant, DÉDUP par requestId
    // (garder la dernière entrée du même requestId — streaming cumulatif) [VÉRIFIÉ].
    var input: Int                 // input_tokens
    var output: Int                // output_tokens
    var cacheRead: Int             // cache_read_input_tokens  — inclus dans les totaux de conso [VÉRIFIÉ]
    var cacheCreation: Int         // cache_creation_input_tokens
    var isLive: Bool               // true pendant le tour (entrées partielles ingérées mid-turn)
    // Cursor : indisponible par tour (tokenCount ≈ toujours 0 [VÉRIFIÉ]) → tally absent, UI affiche
    // le contexte (ContextUsage) à la place. [HYPOTHÈSE cursor n°3 : pas de source fiable]
}

struct ContextUsage: Sendable { var used: Int; var limit: Int; var percent: Double }
struct SubagentActivity: Identifiable, Sendable {
    var id: String                 // agent_id (Claude) / composerId enfant (Cursor)
    var type: String               // agent_type / subagentTypeName
    var status: SubagentStatus     // running / completed / failed
    var summary: String?
    var startedAt: Date; var endedAt: Date?
}
enum SubagentStatus: String, Codable, Sendable { case running, completed, failed }
struct TodoItem: Identifiable, Sendable { var id: String; var content: String; var status: String }
```

---

## 3. SessionState — machine à états

```swift
enum SessionState: Equatable, Sendable {
    case executing            // un tool s'exécute (commande, edit, MCP…)
    case thinking             // tour actif, le modèle génère (texte ou thinking), aucun tool en vol
    case waiting(WaitingReason)  // l'agent ATTEND L'UTILISATEUR — uniquement sur signal explicite
    case idle                 // tour terminé, agent prêt pour le prochain prompt
}

enum WaitingReason: Equatable, Sendable {
    case permission           // PermissionRequest / beforeShellExecution / beforeMCPExecution en attente
    case question             // AskUserQuestion / ask_question
    case plan                 // ExitPlanMode / hasPendingPlan
}

enum SessionLiveness: Equatable, Sendable {
    case live                 // process vivant (registre PID Claude / activité hooks / DB fraîche)
    case ended(SessionEndKind)   // SessionEnd reçu ou PID mort — la row reste listée (cf. §7)
}
enum SessionEndKind: String, Sendable { case cleared, exited, killed, resumedElsewhere, crashed }
```

### 3.1 Transitions — Claude Code (source primaire : hooks) **[VÉRIFIÉ pour les événements ; mapping produit tranché]**

| # | De | Vers | Déclencheur exact |
|---|---|---|---|
| T1 | (nouvelle) | `idle` | `SessionStart` (startup/resume) sans prompt en cours ; ou apparition dans `~/.claude/sessions/` (session desktop lancée sans activité — [HYPOTHÈSE claude-code n°4]) |
| T2 | `idle` | `thinking` | `UserPromptSubmit` |
| T3 | `thinking` | `executing` | `PreToolUse` pour tout tool **hors** `AskUserQuestion`/`ExitPlanMode` (télémétrie, réponse vide immédiate) |
| T4 | `executing` | `thinking` | `PostToolUse` / `PostToolUseFailure` / `PostToolBatch` (le modèle reprend la génération) |
| T5 | `thinking`/`executing` | `waiting(.permission)` | `PermissionRequest` reçu (le hook garde la connexion ouverte) ; corroboré par `Notification(notification_type: permission_prompt)` |
| T6 | `thinking` | `waiting(.question)` | `PreToolUse` avec `tool_name == AskUserQuestion` (connexion gardée ouverte) |
| T7 | `thinking` | `waiting(.plan)` | `PermissionRequest` avec `tool_name == ExitPlanMode` (le plan complet est dans `tool_input.plan` [VÉRIFIÉ]) |
| T8 | `waiting(.permission)` | `executing` | décision **Allow / Always Allow** envoyée (le tool part immédiatement) |
| T9 | `waiting(.permission)` | `thinking` | décision **Deny / Deny with feedback** (Claude lit le message et reprend) |
| T10 | `waiting(.question)` | `thinking` | réponse envoyée (`allow` + `updatedInput.questions+answers` [VÉRIFIÉ doc, interactif = HYPOTHÈSE claude-code n°2]) |
| T11 | `waiting(.plan)` | `thinking` | **Approve** (`allow`, ± `setMode acceptEdits`) ou **Reject** (`deny` + message) |
| T12 | `waiting(*)` | `waiting(*)` **inchangé, prompt relâché** | auto-libération : réponse vide à `hookTimeout − 10 s`, ou action « répondre dans le terminal » — l'agent affiche alors son dialogue natif ; l'état reste waiting jusqu'au signal suivant |
| T13 | `thinking`/`executing`/`waiting` | `idle` | `Stop` (fin du tour ; porte `last_assistant_message`) → notification « tâche terminée » si activée |
| T14 | `thinking`/`executing` | `idle` (+ badge erreur) | `StopFailure` (rate_limit, overloaded, billing_error…) → alerte limites/session bloquée |
| T15 | tout état | `idle` + `liveness = .ended(…)` | `SessionEnd` (reason: clear/logout/exit…) ou disparition du PID du registre |
| T16 | tout état | `idle` | `Notification(idle_prompt)` reçue alors qu'aucun tour actif n'est connu (rattrapage de désynchronisation) |

### 3.2 Transitions — Cursor (hooks + réconciliation DB)

| # | De | Vers | Déclencheur |
|---|---|---|---|
| C1 | (nouvelle) | `idle` | `sessionStart`, ou apparition dans `allComposers` |
| C2 | `idle` | `thinking` | `beforeSubmitPrompt` |
| C3 | `thinking` | `executing` | `preToolUse` / `afterShellExecution` (activité outil) ; DB : `generatingBubbleIds` non vide ou `toolFormerData.status == "loading"` frais [HYPOTHÈSE cursor n°5 sur la fraîcheur d'écriture] |
| C4 | `executing` | `thinking` | `postToolUse` / `postToolUseFailure` / `afterFileEdit` / `afterAgentThought` |
| C5 | `thinking`/`executing` | `waiting(.permission)` | hook `beforeShellExecution` / `beforeMCPExecution` d'AgentDash **bloquant** ; réconciliation : `hasBlockingPendingActions == true` [VÉRIFIÉ statique, dynamique HYPOTHÈSE] |
| C6 | `waiting(.permission)` | `executing` / `thinking` | réponse `allow` / `deny` (+ `user_message` = Deny with feedback) ; timeout ou choix utilisateur → réponse `ask` (la main revient à l'UI Cursor), état conservé |
| C7 | `thinking` | `waiting(.question)` / `waiting(.plan)` | détection `ask_question` / `create_plan` / `hasPendingPlan` — **affichage seul**, pas d'action inline (⌥A et réponses réservés à Claude Code, aligné AgentPeek) [HYPOTHÈSE cursor n°4] |
| C8 | tout état | `idle` | `stop` (status completed/aborted/error) ; DB : `status` passe à completed/aborted |
| C9 | tout état | `idle` + `.ended` | `sessionEnd` (reason: completed/aborted/error/window_close/user_close) |

### 3.3 Règles transverses de la machine à états **[TRANCHÉ]**

- **Aucun timeout ne fait entrer en `waiting`.** `waiting` = signal explicite uniquement (T5–T7, C5, C7). Un `Bash` de 10 minutes reste `executing` du début à la fin — c'est l'exigence « un outil long ne bascule PAS en waiting ».
- **Priorité des états** quand plusieurs signaux coexistent : `waiting` > `executing` > `thinking` > `idle`. Un `PermissionRequest` pendant un batch de tools force `waiting`.
- **Fallback sans hooks** (sessions antérieures à l'installation, hooks désactivés) : Claude — `executing` si `tool_use` non apparié + écritures FSEvents < 5 s ; `thinking` si dernière entrée `assistant` partielle (`stop_reason: null`) ; `idle` si `stop_reason: end_turn` et aucune écriture depuis `idleFallbackSeconds` (défaut **10 s**) ; `waiting` **non détectable** de façon fiable (documenté [VÉRIFIÉ] : les transcripts ne marquent pas la demande de permission) → jamais inféré. Cursor — `hasBlockingPendingActions`/`hasPendingPlan`/`status`/`generatingBubbleIds` en poll.
- **Réconciliation** : si hook et fallback divergent, le hook gagne pendant `hookAuthorityWindow` (défaut **15 s**) après son dernier événement ; au-delà, le fallback peut corriger (couvre la perte d'un événement).

### 3.4 Timeouts et constantes (toutes dans `AppSettings` ou constantes nommées)

| Constante | Défaut | Rôle |
|---|---|---|
| `stuckThresholdSeconds` | 120 | `executing`/`thinking` sans événement → `isStale = true` → notification « stuck-session » (état inchangé, se résout au prochain événement) |
| `hookDecisionTimeoutSeconds` | 600 (Claude, timeout par hook dans settings.json [VÉRIFIÉ]) ; 600 demandé côté Cursor [HYPOTHÈSE cursor n°2 : plafond réel à mesurer] | durée max pendant laquelle un prompt reste actionnable dans le notch |
| `promptAutoReleaseMargin` | 10 s | l'app répond « pas de décision » à `timeout − marge` pour une bascule propre vers le dialogue natif |
| `idleFallbackSeconds` | 10 | inertie avant `idle` en mode fallback (anti-flap entre deux requêtes d'un même tour) |
| `hookAuthorityWindow` | 15 s | fenêtre d'autorité des hooks sur le fallback |
| `sessionRetentionHours` | 24 | rétention des sessions `ended` dans la liste (cf. §7) |

---

## 4. Timeline, tool calls, prompts actionnables

```swift
struct TimelineEvent: Identifiable, Sendable {
    var id: String                     // uuid de l'entrée (Claude) / bubbleId+toolCallId (Cursor)
    var timestamp: Date
    var kind: TimelineEventKind
    var summary: String                // langage clair : « Ran `git status` », « Edited Session.swift (+12/−3) »
    var isSidechain: Bool              // événement issu d'un subagent
}

enum TimelineEventKind: Sendable {
    case userPrompt(excerpt: String)
    case assistantText(excerpt: String)
    case thinking(durationMs: Int?)
    case toolCall(ToolCallSummary)
    case permission(PermissionOutcome)     // demandé/accordé/refusé + par qui (notch, terminal, timeout)
    case planProposed(title: String)
    case questionAsked(count: Int)
    case compaction(auto: Bool)            // PreCompact/PostCompact [VÉRIFIÉ]
    case sessionMarker(SessionMarker)      // started, resumed, cleared, ended, killed
    case error(message: String)
}

struct ToolCallSummary: Identifiable, Sendable {
    var id: String                     // tool_use_id (Claude) / toolCallId (Cursor)
    var toolName: String               // nom brut : Bash, Edit, mcp__…, run_terminal_command_v2…
    var displayName: String            // nom traduit (table AgentCursor/AgentClaude)
    var inputSummary: String           // ex. la commande, le file_path — jamais l'input complet en RAM
    var status: ToolCallStatus         // running / succeeded / failed / cancelled
    var durationMs: Int?               // PostToolUse.duration_ms / toolFormerData.duration
    var isError: Bool
    var diff: DiffStats?               // Edit/Write : dérivé de structuredPatch [VÉRIFIÉ]
}
enum ToolCallStatus: String, Sendable { case running, succeeded, failed, cancelled }

struct DiffStats: Sendable, AdditiveArithmetic {
    var linesAdded: Int                // Claude : somme des hunks structuredPatch ;
    var linesRemoved: Int              // Cursor : totalLinesAdded/Removed de composerHeaders [VÉRIFIÉ]
}

/// Fenêtre de timeline rendue (budget RAM §6 de 01-architecture.md).
struct TimelineWindow: Sendable {
    var events: [TimelineEvent]        // au plus `timelineWindowSize` (2000) événements en mémoire
    var totalCount: Int                // compteur réel (« sans limite d'historique » côté données)
    var olderAvailable: Bool           // scroll vers le haut → relecture paresseuse du transcript
}
```

### 4.1 Prompts actionnables (« Act »)

```swift
/// Un prompt en attente = une connexion IPC ouverte, détenue par PromptStore.
struct PendingPrompt: Identifiable, Sendable {
    var id: UUID                       // id de corrélation IPC (logs)
    var sessionID: SessionID
    var receivedAt: Date
    var expiresAt: Date                // receivedAt + hookDecisionTimeout − promptAutoReleaseMargin
    var payload: PendingPromptPayload
    var capabilities: PromptCapabilities
}

enum PendingPromptPayload: Sendable {
    case permission(PermissionRequest)
    case question(QuestionPrompt)
    case plan(PlanProposal)
}

struct PromptCapabilities: Sendable {
    var canAlwaysAllow: Bool           // true ssi Claude + permission_suggestions non vide [VÉRIFIÉ]
    var canDenyWithFeedback: Bool      // Claude : message ; Cursor : user_message [VÉRIFIÉ doc]
    var canAnswerInline: Bool          // questions : Claude uniquement [HYPOTHÈSE claude-code n°2]
    var canApprovePlan: Bool           // plans : Claude uniquement
    var canHandInToTerminal: Bool      // réponse vide (Claude) / `ask` (Cursor)
}

struct PermissionRequest: Sendable {
    var toolName: String
    var toolInput: [String: JSONValue] // tool_input brut (affichage + prompts « honnêtes »)
    var displayTitle: String           // reformulation honnête : « Écrire dans src/… via bash » (analyse
                                       // locale de la commande : redirections, rm, mv…) [HYPOTHÈSE produit]
    var suggestions: [PermissionSuggestion]  // écho exact des permission_suggestions [VÉRIFIÉ]
    var cwd: String
}
struct PermissionSuggestion: Codable, Sendable {   // renvoyée TELLE QUELLE dans updatedPermissions (⌥A)
    var type: String                   // "addRules"…
    var rules: [PermissionRule]?
    var behavior: String?
    var destination: String?           // session / localSettings / projectSettings / userSettings
    var mode: String?
    struct PermissionRule: Codable, Sendable { var toolName: String; var ruleContent: String? }
}

struct QuestionPrompt: Sendable {
    var questions: [AgentQuestion]     // 1 à 4 [VÉRIFIÉ]
    // Réponse : allow + updatedInput = { questions: <original>, answers: {texte question: label(s)} } —
    // multiSelect : labels joints par des virgules [VÉRIFIÉ doc].
}
struct AgentQuestion: Identifiable, Sendable {
    var id: String                     // le TEXTE de la question (clé du mapping answers)
    var header: String?
    var text: String
    var options: [String]              // labels
    var multiSelect: Bool
    var allowsFreeText: Bool           // réponse texte libre inline (feature AgentPeek §4.3)
}

struct PlanProposal: Sendable {
    var markdown: String               // tool_input.plan [VÉRIFIÉ]
    var planFilePath: String?
    var allowedPrompts: [(tool: String, prompt: String)]   // permissions demandées pour exécuter le plan
    var title: String                  // première ligne H1 du markdown, stylisée
    var approveSwitchesToAcceptEdits: Bool  // option : updatedPermissions setMode acceptEdits [VÉRIFIÉ]
}

enum PromptDecision: Sendable {
    case allow
    case alwaysAllow(PermissionSuggestion)     // Claude uniquement
    case deny(feedback: String?)
    case answers([String: String])             // question → label(s) ou texte libre
    case approvePlan(switchToAcceptEdits: Bool)
    case rejectPlan(feedback: String)
    case handInToTerminal                      // réponse vide / `ask`
}
enum PermissionOutcome: Sendable { case granted(via: DecisionSource), denied(via: DecisionSource), released }
enum DecisionSource: String, Sendable { case notch, hotkey, notification, terminal, timeout }
```

---

## 5. Usage, serveurs, routes, actions, notifications

```swift
// — Usage —
enum UsageWindowKind: String, Codable, Sendable {
    case fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet   // Claude [VÉRIFIÉ endpoint oauth/usage]
    case monthly                                            // Cursor (cycle de facturation)
}

struct UsageWindow: Sendable {
    var kind: UsageWindowKind
    var account: UsageAccount.ID
    var utilization: Double            // 0–100
    var resetsAt: Date?                // « resets in… » / « refills Sun at 3:47 PM » / billingCycleEnd
    var fetchedAt: Date                // horodatage de la DERNIÈRE valeur obtenue (rétention sur échec)
    var isStale: Bool                  // dernier refresh en échec → on retient, badge éventuel
    var dollars: (used: Double, limit: Double)?   // Cursor « $X of $Y » (cents → $) [VÉRIFIÉ OSS]
    var subBars: [UsageSubBar]         // Cursor : barres optionnelles Auto/Composer et API
}
struct UsageSubBar: Sendable { var label: String; var percent: Double }

enum CursorUsageMeasure: String, Codable, Sendable, CaseIterable {
    case spend, weighted, auto, api    // mapping vers usage-summary [HYPOTHÈSE cursor n°8]
}

struct UsageAccount: Identifiable, Sendable {
    var id: String                     // Claude : hash du compte Keychain ; Cursor : userId (sub JWT)
    var agent: AgentKind
    var label: String                  // email / organisation [HYPOTHÈSE claude-code n°5 pour Claude]
    var plan: String?                  // stripeMembershipType (Cursor) [VÉRIFIÉ local]
    var isSelected: Bool               // sélection du compte d'usage (Settings → Usage)
}

struct DailyUsage: Identifiable, Sendable {   // stats jour par jour (AgentPeek v0.2.6)
    var id: String                     // "YYYY-MM-DD|agent"
    var date: Date; var agent: AgentKind
    var tokens: TokenTally             // Claude : parsing JSONL local, dédup requestId [VÉRIFIÉ ccusage]
    var costUSD: Double?               // table de prix par modèle (Claude) / totalCostCents (Cursor)
    var linesSuggested: Int?; var linesAccepted: Int?   // Cursor aiCodeTracking.dailyStats [VÉRIFIÉ]
    var sessionCount: Int
}

// — Serveurs dev —
struct DevServer: Identifiable, Sendable {
    struct ID: Hashable, Sendable { let pid: pid_t; let port: UInt16 }   // identité (pid, port),
    var id: ID                                                            // fusion v4/v6 [VÉRIFIÉ]
    var displayName: String            // « Next.js », « Vite », sinon runtime, sinon basename(execPath)
    var framework: FrameworkKind?      // nextjs, vite, astro, wrangler, storybook, playwright, staticServer
    var runtime: RuntimeKind?          // node, bun, deno, python, ruby, rust, go, other
    var packageRunner: PackageRunner?  // npm/pnpm/yarn/bun via npm_config_user_agent [VÉRIFIÉ pnpm]
    var script: String?                // npm_lifecycle_script (« expo start ») [VÉRIFIÉ]
    var projectPath: String            // cwd du process ; "/" (app GUI) → nom d'app [VÉRIFIÉ]
    var execPath: String
    var startTime: (sec: UInt64, usec: UInt64)   // pbi_start_tvsec/usec — uptime + garde-fou kill [VÉRIFIÉ]
    var url: URL                       // http://localhost:<port>
    var stopState: StopState           // .none / .confirming(until: Date) / .terminating / .gone
}
enum FrameworkKind: String, Codable, Sendable { case nextjs, vite, astro, wrangler, storybook, playwright, staticServer }
enum RuntimeKind: String, Codable, Sendable { case node, bun, deno, python, ruby, rust, go, other }
enum PackageRunner: String, Codable, Sendable { case npm, pnpm, yarn, bun }
enum StopState: Equatable, Sendable { case none, confirming(until: Date), terminating, gone }

// — Quick Routes & Fast Actions —
struct QuickRoute: Identifiable, Sendable {
    var id: String                     // "skills", "plugins", "config", "logs", "hooks", "mcp", "root"
    var title: String
    var paths: [String]                // candidats ; seuls les existants s'affichent [VÉRIFIÉ features §7]
    var revealsFile: Bool              // fichier → activateFileViewerSelecting ; dossier → open
}
// Défauts : Skills ~/.claude/skills · Plugins ~/.claude/plugins · Config ~/.claude/settings.json ·
// Logs ~/.claude/projects, ~/.cursor/projects · Hooks ~/.cursor/hooks.json · MCP ~/.cursor/mcp.json ·
// Root ~/.claude, ~/.cursor   (table canonique : 11 §3.1 ; REQ-QRF-01)

struct FastAction: Identifiable, Codable, Sendable {   // persisté (UserDefaults)
    var id: UUID
    var title: String
    var command: String                // shell, exécuté via /bin/zsh -lc, sortie visible dans le notch
    var workingDirectory: String?
    var lastRunAt: Date?; var lastExitCode: Int32?
}

// — Notifications —
enum NotificationKind: String, Codable, Sendable {
    case permissionRequest = "PERMISSION_REQUEST"   // avec actions Allow/Deny inline [VÉRIFIÉ]
    case budgetAlert       = "BUDGET_ALERT"
    case stuckSession      = "STUCK_SESSION"
    case taskComplete      = "TASK_COMPLETE"
    case test              = "TEST"
}
struct NotificationEvent: Identifiable, Sendable {
    var id: UUID
    var kind: NotificationKind
    var sessionID: SessionID?
    var title: String; var body: String
    var postedAt: Date
    var dedupKey: String               // anti-spam : 1 notif budget par (fenêtre, seuil, cycle) ;
                                       // 1 stuck par (session, épisode stale)
}
```

---

## 6. Trial, licence, réglages

```swift
// — Trial (LicensingKit) — anti-rollback complet [VÉRIFIÉ distribution-licensing §3]
struct TrialState: Codable, Sendable {
    var trialStart: Date               // fusion pessimiste : le plus ANCIEN des 2 stockages gagne
    var highWaterMark: Date            // « dernière heure vue » — ne recule jamais
    var elapsedSeconds: UInt64         // accumulé par deltas mach_continuous_time POSITIFS uniquement
    var machineIdHash: String          // SHA-256(IOPlatformUUID + sel)
    var version: Int                   // schéma du blob (HMAC-SHA256 par-dessus)
}
// expired = (effectiveNow ≥ trialStart + 48 h) || (elapsedSeconds ≥ 48 h) ; le plus défavorable gagne.

enum LicenseState: Equatable, Sendable {
    case onboarding                    // premier lancement, choix pas encore fait
    case trial(remaining: TimeInterval)
    case trialExpired                  // → écran d'achat immédiat, notch verrouillé (pill grisée)
    case licensed(LicenseReceipt)
    case graceOffline(LicenseReceipt, since: Date)   // revalidation impossible, grâce 14 j
    case revoked(reason: String)       // refund/disabled confirmé par le serveur
    case tampered                      // incohérences d'horloge répétées (faille v0.2.9 fermée jour 1)
}
struct LicenseReceipt: Codable, Equatable, Sendable {
    var keyHash: String; var machineIdHash: String
    var instanceID: String             // instance Lemon Squeezy (deactivate)
    var issuedAt: Date; var licenseVersion: Int
    var signature: Data                // Ed25519, vérifiée offline à chaque lancement (CryptoKit)
}
```

### 6.1 AppSettings — exhaustif, avec défauts **[TRANCHÉ, défauts calqués sur AgentPeek quand connus]**

```swift
struct AppSettings: Codable, Sendable {
    // General
    var launchAtLogin = false                    // SMAppService ; état RÉEL relu à chaque affichage
    var notchEnabled = true
    var menuBarEnabled = true
    var menuBarShowsUsage = true                 // texte d'usage à côté de l'icône menu bar (06 · REQ-MBR-03)
    var autoExpandOnAttention = true
    var promptHandling: PromptHandling = .notch  // « prompt handling location »
    var claudeHooksEnabled = true                // toggle installe ET répare
    var cursorHooksEnabled = true

    // Notifications
    var notificationsMasterEnabled = true
    var notificationSoundEnabled = true
    var notifyPermissionRequests = true
    var notifyBudgetAlerts = true
    var budgetThreshold5h: Int = 80              // 50–100 %
    var budgetThreshold7d: Int = 80              // 50–100 %
    var budgetThresholdMonthly: Int = 90         // P2, alerte budget cycle Cursor (12 · REQ-NOT-13) [HYPOTHÈSE produit]
    var notifyStuckSessions = true
    var notifyTaskComplete = true

    // Appearance
    var panelWidth: PanelWidth = .normal         // .normal / .wide / .ultraWide
    var pillWidthMode: PillWidthMode = .auto     // .auto / .wide / .ultraWide (verrouillée en mode usage)
    var density: Density = .regular              // .compact / .regular / .colossal
    var sessionListSizing: ListSizing = .fixed   // .fixed / .growable (jusqu'à l'écran puis scroll)
    var titleWeight: TitleWeight = .semibold     // .regular / .medium / .semibold / .bold
    var clock24h = true                          // machine FR → 24 h par défaut
    var pillShowsSessionCount = true
    var pillUsageMode = false                    // jauges live dans le pill réduit
    var pillHideWhenIdle = false
    var pillExpandedOnly = false
    var glassOpacity: Double = 0.55              // 0…1 ; 1.0 = Opaque (désactive réellement le blur)
    var frostedRim = true
    var depthLitEnabled = true
    var metricsOpacity: Double = 0.85
    var hideFromScreenRecording = false          // sharingType = .none
    var preferredScreen: ScreenSelection = .builtinThenMain   // .builtinThenMain / .uuid(String) / .active
    var hoverIntentDelayMs: Int = 200            // anti-flicker v0.1.20 ; hystérésis fermeture 100 ms fixe

    // Usage
    var claudeUsageEnabled = true
    var cursorUsageEnabled = true
    var selectedUsageAccountID: String? = nil    // nil = auto (compte unique)
    var cursorMeasure: CursorUsageMeasure = .weighted
    var cursorShowAutoBar = false
    var cursorShowAPIBar = false
    var countdownFrom100 = false                 // compte à rebours depuis 100 %
    var dailyStatsEnabled = true

    // Shortcuts (KeyboardShortcuts ; enregistrement ÉPHÉMÈRE pendant un prompt visible)
    var shortcutAllow        = Shortcut(.a, [.command])   // ⌘A
    var shortcutDeny         = Shortcut(.n, [.command])   // ⌘N
    var shortcutAlwaysAllow  = Shortcut(.a, [.option])    // ⌥A — Claude uniquement
    var shortcutOpenTerminal = Shortcut(.t, [.option])    // ⌥T
    var shortcutToggleNotch: Shortcut? = nil              // global optionnel

    // Updates / About
    var automaticUpdateChecks = true             // SUScheduledCheckInterval = 3600 (plancher Sparkle)
    var betaChannel = false                      // allowedChannels(["beta"])
    var lastWhatsNewVersion: String = ""         // fenêtre What's New post-update

    // Avancé (exposé dans Doctor)
    var serverScanEnabled = true
    var serverScanExclusions: [String] = ["/System/"]     // filtrage du bruit [HYPOTHÈSE produit n°7]
    var stuckThresholdSeconds: Int = 120
    var sessionRetentionHours: Int = 24
}
enum PromptHandling: String, Codable, Sendable { case notch, terminalOnly, both }
enum PanelWidth: String, Codable, Sendable { case normal, wide, ultraWide }
enum PillWidthMode: String, Codable, Sendable { case auto, wide, ultraWide }
enum Density: String, Codable, Sendable { case compact, regular, colossal }
enum ListSizing: String, Codable, Sendable { case fixed, growable }
enum TitleWeight: String, Codable, Sendable { case regular, medium, semibold, bold }
enum ScreenSelection: Codable, Sendable { case builtinThenMain, uuid(String), active }
```

---

## 7. Cycle de vie d'une session **[TRANCHÉ]**

| Phase | Déclencheur | Effet |
|---|---|---|
| **Apparition** | `SessionStart`/`sessionStart` (hook), fichier `~/.claude/sessions/<pid>.json` (desktop, dès le lancement, sans attendre une activité), nouvelle entrée `allComposers`, ou `.jsonl` inconnu détecté par FSEvents | création du `Session`, état T1/C1 ; chargement paresseux de l'historique |
| **Resume** | `SessionStart(source: resume)` — même `sessionId` → même `Session` ; « une session relancée en cours de tour ne perd pas son dernier tour » = l'état et la timeline sont conservés (clé stable) | mise à jour `pid`, `host` ; marqueur timeline `.sessionMarker(resumed)` [HYPOTHÈSE claude-code n°7 : resume multi-fichiers à vérifier] |
| **`/clear`** | `SessionEnd(reason: clear)` puis `SessionStart(source: clear)` avec **nouveau** `sessionId` [VÉRIFIÉ] | l'ancienne row passe `liveness = .ended(.cleared)` mais **reste listée** (feature : « /clear ne retire pas la session ») ; la nouvelle session est chaînée (`clearedFrom` → ancien ID) et prend la place visuelle ; l'ancienne devient dismissable |
| **Kill** | action utilisateur : re-validation `(pid, start_time)` puis SIGTERM → 3 s → SIGKILL [VÉRIFIÉ D5] ; Claude uniquement (PID connu) | `liveness = .ended(.killed)` + marqueur timeline |
| **Fin naturelle** | `SessionEnd` (exit/logout) ou PID disparu du registre | `.ended(.exited)` ; row conservée, compteurs figés |
| **Dismiss** | action utilisateur (« sessions terminal silencieuses dismissables ») | `isDismissed = true` — masquée, données conservées jusqu'à expiration |
| **Expiration (GC)** | `lastEventAt` > `sessionRetentionHours` (24 h) **et** `liveness == .ended` | retrait de `SessionStore` (les transcripts sur disque restent, évidemment, intouchés) |

---

## 8. Persistance **[TRANCHÉ]**

| Donnée | Emplacement | Détails |
|---|---|---|
| Sessions, timelines, prompts en attente, état des jauges, serveurs | **Mémoire uniquement** | entièrement reconstructible : transcripts + registre + DB Cursor + un refresh usage. Redémarrer AgentDash ne perd rien d'important. |
| `AppSettings`, `FastAction[]`, `lastWhatsNewVersion`, sélection de compte, largeurs/densité | **UserDefaults** (`com.<org>.agentdash`) | struct codée en clés plates (migration facile) ; écriture débouncée 500 ms. |
| Offsets de tail des transcripts | **Mémoire** (v1) + **snapshot fichier optionnel** `~/Library/Application Support/AgentDash/state/tail-offsets.json` | v1 : recalcul au lancement (parse si `mtime` < 48 h, sinon `offset = taille`) [VÉRIFIÉ suffisant à 2 Mo]. Le snapshot `{path, inode, size, offset}` ne s'active que si le chargement initial dépasse 1 s (hypothèse system-integration n°8) ; entrée invalidée si `inode` ou `size` incohérents. |
| Cache d'usage journalier (`DailyUsage`) | **Fichier** `…/AgentDash/state/daily-usage.json` | évite de re-parser tout l'historique JSONL à chaque lancement ; recalculable à tout moment (bouton Doctor « Rebuild stats »). |
| Journal applicatif | `~/Library/Logs/AgentDash/agentdash.log` (+ `hook.log` opt-in) | rotation 5 × 2 Mo ; jamais de contenu utilisateur. |
| Trial | **Keychain** (`kSecClassGenericPassword`, service `com.<org>.agentdash.license`, account `trial-state`, `…ThisDeviceOnly`) **et** fichier scellé HMAC (`…/Application Support/<emplacement neutre>`) | fusion pessimiste au lancement : `trialStart` le plus ancien, `highWaterMark`/`elapsedSeconds` les plus grands ; auto-réparation si un des deux manque [VÉRIFIÉ conception §3 distribution-licensing]. |
| Licence | **Keychain** (même service, account `license-receipt`) + copie fichier de secours | reçu + signature + `instance_id` + clé ; vérification Ed25519 offline à chaque lancement. |
| Sauvegardes de configs tierces | `~/.agentdash/backups/settings.json.<ISO>.bak`, `hooks.json.<ISO>.bak` | avant la première écriture de fusion ; consultables depuis Doctor. |
| Binaire hook | `~/.agentdash/bin/agentdash-hook` | resynchronisé (hash) à chaque lancement de l'app = fonction « réparer ». |
| Secrets tiers (tokens Claude/Cursor) | **Jamais persistés par AgentDash** | lus à la demande (Keychain « Claude Code-credentials », `ItemTable cursorAuth/*`), gardés en mémoire le temps de la requête. |

### 8.1 Invariants finaux

1. Une `SessionID` n'apparaît qu'une fois dans `SessionStore` (déduplication structurelle, §1.1).
2. `waiting` implique `pendingPrompt != nil` **ou** un signal externe explicite (`hasBlockingPendingActions`, `Notification permission_prompt`) — jamais un timeout.
3. Toute connexion IPC ouverte correspond à exactement un `PendingPrompt` vivant ; fermeture du prompt (décision, auto-libération, session terminée) ⇒ fermeture de la connexion, et réciproquement.
4. `TokenTally` ne compte jamais deux fois le même `requestId` (dédup à l'ingestion, avant le store).
5. Les jauges d'usage ne régressent jamais silencieusement : soit une nouvelle valeur datée, soit l'ancienne marquée `isStale`, soit `--` (jamais eu de valeur).
6. Aucun kill (session ou serveur) sans re-validation `(pid, start_time, execPath)` immédiatement avant le signal.
