# 8. Actions inline (« Act »)

> Spécification du pilier « Act » d'AgentDash (nom provisoire) : répondre aux permissions, plans et questions des agents directement depuis le notch, sans changer de fenêtre. Rédigé le 3 juillet 2026, conforme à `plan/01-architecture.md` (IPC socket UNIX, fail-open, hotkeys éphémères) et `plan/02-data-model.md` (types `PendingPrompt`, `PromptDecision`, machine à états §3).
> Convention : **[VÉRIFIÉ]** = adossé aux recherches (`plan/research/claude-code.md`, `cursor.md`, `system-integration.md`) ; **[HYPOTHÈSE]** = à valider en implémentation, jamais présenté comme un fait.

---

## 1. Objectif & périmètre

Ce document couvre intégralement la section **§4 « Actions inline (Act) »** d'`AGENTPEEK_FEATURES.md` : §4.1 (permissions dans le notch, raccourcis ⌘A/⌘N/⌥A/⌥T, « Deny with feedback », prompts « honnêtes », prompts extensibles, « prompt handling location »), §4.2 (plans : Approve/Reject, titres stylisés), §4.3 (questions inline, multi-questions). Il couvre aussi les fragments liés de §2.2 (auto-expand du notch sur attention), §10 Shortcuts (avertissement en cas d'échec d'enregistrement — la fenêtre Settings elle-même relève du document SettingsKit) et §14.5 (périmètre du clone : actions réservées à Claude Code pour ⌥A et les réponses).

Sont **hors périmètre** de ce fichier : l'installation des hooks et le protocole IPC bas niveau (document hooks/IPC), le rendu du panel notch lui-même (document NotchUI), les notifications système (document Notifications — seule la *route de décision* venant d'une notification est spécifiée ici), la machine à états complète (déjà tranchée en `02-data-model.md` §3, référencée T5–T12 et C5–C7).

Principe directeur hérité de l'architecture : **fail-open absolu**. Aucune action d'AgentDash ne doit pouvoir bloquer une session ; toute absence de décision rend la main au dialogue natif de l'agent.

---

## 2. Exigences détaillées

Priorités : **P0** = MVP (parité v0.1.0 d'AgentPeek), P1 = confort/parité complète, P2 = raffinement.

### 2.1 Cycle de vie d'un `PendingPrompt`

- **REQ-ACT-01 (P0)** — À la réception d'un événement « décision » sur le socket IPC, `PromptStore` crée un `PendingPrompt` et le publie ; la carte de prompt est visible dans le notch en **moins de 150 ms** après l'écriture de l'événement par l'agent (chaîne mesurée ≈ 25 ms — [VÉRIFIÉ], budget A9 de l'architecture).
- **REQ-ACT-02 (P0)** — Sont classés « décision » (connexion IPC gardée ouverte) exactement : Claude Code `PermissionRequest` (matcher `*`, inclut `ExitPlanMode`) et `PreToolUse` matcher `AskUserQuestion|ExitPlanMode` ; Cursor `beforeShellExecution` et `beforeMCPExecution`. Tout autre événement reçoit une réponse vide immédiate (télémétrie) — conforme à `01-architecture.md` §4.1.
- **REQ-ACT-03 (P0)** — Le mapping vers `PendingPromptPayload` est : `PermissionRequest`/`beforeShellExecution`/`beforeMCPExecution` → `.permission` ; `tool_name == "ExitPlanMode"` → `.plan` (quelle que soit la voie, `PermissionRequest` ou `PreToolUse`) ; `tool_name == "AskUserQuestion"` → `.question`. Les `PromptCapabilities` sont calculées à la création : `canAlwaysAllow = (agent == .claudeCode && !permission_suggestions.isEmpty)` [VÉRIFIÉ doc], `canAnswerInline`/`canApprovePlan` = Claude uniquement, `canHandInToTerminal = true` partout.
- **REQ-ACT-04 (P0)** — À l'arrivée d'un prompt : la session passe en `waiting(…)` (transitions T5–T7/C5), le pill affiche l'état attention (orange), le point orange de la menu bar s'allume, et si `autoExpandOnAttention == true` et `promptHandling != .terminalOnly`, le panel s'ouvre automatiquement (animation 420 ms) avec la carte de prompt visible.
- **REQ-ACT-05 (P0)** — Une décision utilisateur produit exactement une réponse JSON (formats §3.3), écrite sur la **même connexion IPC** que la requête, puis la connexion est fermée et le `PendingPrompt` retiré. Une seule décision par prompt : les contrôles se désactivent dès le premier déclenchement (anti double-clic/double-hotkey).
- **REQ-ACT-06 (P0)** — La décision applique la transition d'état **optimiste** (Allow/Always Allow → `executing` T8 ; Deny → `thinking` T9 ; réponses/plan → `thinking` T10–T11 ; Cursor C6) et émet un `TimelineEvent.permission(...)` portant la `DecisionSource` (`notch`, `hotkey`, `notification`). La **confirmation** est corroborée par l'événement suivant de l'agent (`PreToolUse`/`PostToolUse` du tool autorisé ; côté Claude, le transcript affiche « Allowed by PermissionRequest hook » [VÉRIFIÉ doc]). Sans corroboration sous 5 s, l'état reste celui des hooks suivants (règle `hookAuthorityWindow`) — aucun rollback UI.
- **REQ-ACT-07 (P0)** — **Auto-libération** : à `expiresAt = receivedAt + hookDecisionTimeout − promptAutoReleaseMargin` (600 − 10 s par défaut), l'app répond « pas de décision » (corps vide pour Claude, `{"permission":"ask"}` pour Cursor), ferme la connexion, retire la carte et journalise `PermissionOutcome.released`. L'état de session **reste** `waiting` (T12) : l'agent affiche alors son dialogue natif.
- **REQ-ACT-08 (P0)** — Si la connexion IPC est fermée côté distant (agent tué, timeout agent, crash du hook), le `PendingPrompt` est retiré silencieusement, sans erreur visible ; l'invariant « 1 connexion ouverte ⇔ 1 `PendingPrompt` vivant » (`02-data-model.md` §8.1-3) est vérifié dans les deux sens.
- **REQ-ACT-09 (P0)** — **Obsolescence** : si un événement ultérieur prouve que la décision a été prise ailleurs (ex. `PreToolUse`/`PostToolUse` du même `tool_use_id`, `Stop`, `SessionEnd`, réponse visible dans le transcript), le prompt est retiré et la connexion libérée (réponse vide/`ask`) — couvre l'hypothèse claude-code n°1 (réponse donnée dans le terminal pendant l'attente) [HYPOTHÈSE — séquencement exact terminal/hook à valider].

### 2.2 UI Permission

- **REQ-ACT-10 (P0)** — La carte permission propose : **Allow** (⌘A, bouton primaire), **Deny** (⌘N), **Always Allow** (⌥A, visible ssi `canAlwaysAllow`), et le lien **« Deny with feedback… »** qui révèle un champ texte + boutons **Send**/**Cancel**.
- **REQ-ACT-11 (P0)** — La carte affiche : icône/avatar de l'agent, `projectName`, titre de session, nom d'outil affiché (`displayName`), résumé de l'input (commande complète pour Bash en bloc monospace, `file_path` pour Edit/Write, `tool_name` + serveur pour MCP), et le `cwd`. Le contenu volumineux suit REQ-ACT-35.
- **REQ-ACT-12 (P0)** — **Deny with feedback** envoie : Claude → `decision:{behavior:"deny", message:"<texte>"}` [VÉRIFIÉ doc] ; Cursor → `{"permission":"deny","user_message":"<texte>"}` (conforme `02-data-model.md` C6 ; le champ effectivement lu par le modèle — `user_message` vs `agent_message` — est une [HYPOTHÈSE cursor à valider ; en attendant, renseigner les deux champs avec le même texte]).
- **REQ-ACT-13 (P0)** — **Always Allow** renvoie **telle quelle** la première `permission_suggestions[]` reçue dans `updatedPermissions` (« équivalent au choix "always allow" du dialogue » [VÉRIFIÉ doc]). P2 : si plusieurs suggestions existent, un menu contextuel sur le bouton liste les destinations (`session`/`localSettings`/`projectSettings`/`userSettings`).
- **REQ-ACT-14 (P1)** — **Reformulation « honnête »** : pour tout `Bash`/`beforeShellExecution`, AgentDash analyse **la commande elle-même** (jamais uniquement le champ `description` fourni par le modèle) et affiche en tête les effets d'écriture détectés : redirections `>`/`>>`, `tee`, `rm`/`rmdir`/`unlink`, `mv`, `cp`/`install`/`rsync`, `dd of=`, `truncate`, `sed -i`/`perl -i`, `mkdir`/`touch`, `chmod`/`chown`, `git reset --hard`/`git clean -f`/`git checkout --`. Règles complètes en §3.4. La `description` du modèle reste affichée, mais étiquetée « Agent's description » (c'est la lecture produit du « more honest » d'AgentPeek — [HYPOTHÈSE produit sur le comportement exact d'AgentPeek, feature attestée §4.1]).
- **REQ-ACT-15 (P1)** — Les constructions **opaques** (`eval`, `bash -c`, substitution `$(…)`/backticks, `xargs`, `find -exec`, `curl … | sh`) désactivent la reformulation et affichent le badge « Effects unclear — review the command », sans jamais prétendre à l'innocuité.

### 2.3 UI Plan

- **REQ-ACT-16 (P0)** — Un prompt `.plan` rend `tool_input.plan` en **Markdown** (via `AttributedString(markdown:)`, fallback texte brut), avec **titre stylisé** = premier H1 du Markdown (sinon « Plan »), et les boutons **Approve** (⌘A) / **Reject** (⌘N). Approve → `decision:{behavior:"allow"}` ; Reject → `decision:{behavior:"deny", message:<feedback>}` — Claude reste en plan mode et lit le feedback [VÉRIFIÉ doc].
- **REQ-ACT-17 (P1)** — Les `allowedPrompts[]` (`{tool, prompt}`) du plan sont listés sous le corps (« Will request: … ») pour éclairer la décision [VÉRIFIÉ doc que le champ existe].
- **REQ-ACT-18 (P1)** — Une case « Switch to Accept Edits » (décochée par défaut) ajoute `updatedPermissions:[{"type":"setMode","mode":"acceptEdits","destination":"session"}]` à l'approbation [VÉRIFIÉ doc]. Le feedback de Reject est **optionnel** (Reject sec = `message` générique « Plan rejected from AgentDash »).

### 2.4 UI Questions

- **REQ-ACT-19 (P0)** — Un prompt `.question` rend les **1 à 4 questions** [VÉRIFIÉ doc] de `tool_input.questions[]`, chacune avec son `header` (chip), son texte, et ses `options` sous forme de boutons-pilules ; `multiSelect == true` autorise plusieurs pilules actives (mention « Select all that apply »).
- **REQ-ACT-20 (P0)** — Chaque question offre en plus un champ **réponse libre** (placeholder « Type your own answer… ») ; saisir du texte désélectionne les pilules et réciproquement (feature §4.3 « options + réponse texte »).
- **REQ-ACT-21 (P0)** — **Submit** (bouton + touche ⏎ quand le panel est key) n'est actif que lorsque **chaque** question a une réponse (pilule(s) ou texte non vide). L'envoi construit `permissionDecision:"allow"` + `updatedInput = {questions: <tableau original inchangé>, answers: {<texte de la question>: <label(s) joints par ", " | texte libre>}}` [VÉRIFIÉ doc pour le format ; efficacité en session interactive = HYPOTHÈSE claude-code n°2].
- **REQ-ACT-22 (P0)** — Si le banc d'essai (`scripts/experiments/`) invalide l'hypothèse n°2, un **feature flag** bascule l'envoi en fallback : `permissionDecision:"deny"` + `permissionDecisionReason` contenant les réponses en clair (« User answered: … ») — pattern documenté par la recherche. L'UI ne change pas.
- **REQ-ACT-23 (P1)** — **Cursor** : les questions (`ask_question`) et plans (`create_plan`, `hasPendingPlan`) sont **affichés** (état `waiting`, carte descriptive) mais **non actionnables** ; la carte propose uniquement « Respond in Cursor » (active l'app Cursor) — aligné sur AgentPeek (⌥A et réponses réservés à Claude Code) et sur les hypothèses cursor n°4–5.

### 2.5 Raccourcis clavier

- **REQ-ACT-24 (P0)** — Mapping par type de prompt : permission → ⌘A Allow, ⌘N Deny, ⌥A Always Allow (uniquement si `canAlwaysAllow`, sinon no-op silencieux), ⌥T Open Terminal ; plan → ⌘A Approve, ⌘N Reject, ⌥T ; question → ⌥T seulement (⌘A/⌘N inactifs pour éviter une réponse accidentelle ; ⏎ soumet — [HYPOTHÈSE produit, AgentPeek non documenté sur ce point]). Les raccourcis sont personnalisables via Settings → Shortcuts (`AppSettings.shortcut*`).
- **REQ-ACT-25 (P0)** — **Enregistrement éphémère** : les hotkeys (`RegisterEventHotKey`, aucune permission TCC [VÉRIFIÉ]) ne sont enregistrées **que** pendant qu'au moins un prompt actionnable est **affiché** (panel ouvert avec carte visible). Fermeture du panel, décision, auto-libération, dernière carte retirée → désenregistrement immédiat. Jamais d'enregistrement permanent (⌘A volerait « Tout sélectionner » système).
- **REQ-ACT-26 (P0)** — Chaque échec d'enregistrement (`OSStatus != noErr`, ex. `eventHotKeyExistsErr = -9878`) est collecté et remonté : bandeau d'avertissement dans Settings → Shortcuts (« ⌘A could not be registered — another app may be using it. Buttons still work. ») + icône ⚠ discrète sur le bouton concerné de la carte. Les boutons cliquables restent la voie nominale.
- **REQ-ACT-27 (P0)** — Les keycodes sont résolus **par caractère** via la disposition clavier courante (`UCKeyTranslate`), pas par constante positionnelle (`kVK_ANSI_A` taperait Q sur AZERTY — machine cible française) ; ré-enregistrement sur `kTISNotifySelectedKeyboardInputSourceChanged` [VÉRIFIÉ en principe, recherche system-integration §6.3].
- **REQ-ACT-28 (P0)** — Les hotkeys agissent **exclusivement sur le prompt focalisé** (§2.6), jamais sur toute la file.
- **REQ-ACT-29 (P0)** — Pendant qu'un champ texte de la carte (feedback, réponse libre) est first responder, les hotkeys ⌘A/⌘N/⌥A sont **suspendues** (désenregistrées) pour ne pas transformer une frappe en décision ; elles se réarment à la perte de focus.
- **REQ-ACT-30 (P1)** — **⌥T** ouvre le terminal de la session focalisée selon l'algorithme §3.5 : app hôte identifiée via `term_program` transmis par le hook [VÉRIFIÉ : `TERM_PROGRAM` hérité] et/ou remontée de la chaîne de parents du PID de session [HYPOTHÈSE pour la chaîne] ; fallback : ouvrir Terminal.app sur le `cwd` de la session. Limitation assumée (pas de TCC) : activation de l'application, pas de l'onglet précis.

### 2.6 File d'attente multi-prompts

- **REQ-ACT-31 (P0)** — `PromptStore` maintient une file **FIFO par `receivedAt`** de tous les prompts vivants (sessions multiples en parallèle). Le plus ancien est **focalisé** par défaut ; après une décision, le focus avance automatiquement au plus ancien restant.
- **REQ-ACT-32 (P0)** — Quand plusieurs prompts coexistent, la carte focalisée affiche un compteur « +N waiting » et des chevrons ‹ › de navigation (clic) ; chaque prompt de la file est identifié par agent + projet + titre de session.
- **REQ-ACT-33 (P1)** — Cliquer une row de session porteuse d'un badge attention focalise son prompt dans la zone Act.
- **REQ-ACT-34 (P0)** — `Session.pendingPrompt` reste ≤ 1 par session (modèle des agents). Si un second prompt arrive pour la même session (cas subagents parallèles [HYPOTHÈSE — jamais observé]), il entre dans la file de `PromptStore` et devient `pendingPrompt` de la session à la résolution du premier.

### 2.7 Prompts extensibles, timeout, hand-in

- **REQ-ACT-35 (P0)** — **Prompts extensibles** (feature v0.1.18) : contenu replié par défaut (commande : 4 lignes max ; plan : ~240 pt ; input MCP : 6 lignes) avec « Show more » ; déplié, la zone scrolle à l'intérieur de la carte, plafonnée à la hauteur du panel — « Show less » pour replier. Aucune ligne > 10 Ko n'est rendue brute (troncature avec ellipse, cohérent avec la ligne max de 70 007 octets observée [VÉRIFIÉ]).
- **REQ-ACT-36 (P0)** — **Timeout côté agent** : Claude tue le hook au `timeout` configuré (600 s posés par notre installeur [VÉRIFIÉ doc du champ]) ; Cursor a un « platform default » non chiffré, notre installeur pose un `timeout` explicite [HYPOTHÈSE cursor n°2 sur le plafond réel]. AgentDash n'attend **jamais** ce couperet : auto-libération à `timeout − 10 s` (REQ-ACT-07). Quand il reste < 60 s, la carte affiche un compte à rebours « Hands back to terminal in 0:42 ».
- **REQ-ACT-37 (P1)** — Bouton **« Respond in terminal »** sur chaque carte : libération immédiate et volontaire (réponse vide Claude / `ask` Cursor, `DecisionSource.terminal`), pour l'utilisateur qui préfère décider dans son terminal sans attendre.

### 2.8 Réglage « prompt handling location » et routes secondaires

- **REQ-ACT-38 (P0)** — `AppSettings.promptHandling` gouverne le comportement [HYPOTHÈSE produit — sémantique exacte d'AgentPeek inconnue, la nôtre est tranchée ainsi] :
  - `.notch` (défaut) : prompts capturés et actionnables dans le notch (comportement décrit dans ce document) ; la notification système actionnable est postée en parallèle comme canal de rattrapage, selon les règles normatives de `12-notifications.md` (gating `notifyPermissionRequests` REQ-NOT-08, suppression si panel déjà ouvert par hover/clic REQ-NOT-32) ;
  - `.terminalOnly` : l'app répond « pas de décision » **immédiatement** (vide/`ask`) — aucun prompt actionnable, aucune notification de permission (REQ-NOT-33), l'état `waiting` reste affiché passivement (badge attention) et le dialogue natif de l'agent s'affiche sans délai ;
  - `.both` : identique à `.notch`, mais la notification est **garantie** : la suppression « panel déjà ouvert par interaction » de REQ-NOT-32 est levée.
  Le changement de réglage prend effet au prompt suivant (les prompts en cours conservent leur mode).
- **REQ-ACT-39 (P1)** — Les actions **Allow/Deny des notifications** (catégorie `PERMISSION_REQUEST` [VÉRIFIÉ faisable, recherche §7.2]) sont routées vers `PromptStore.decide` avec `DecisionSource.notification` — même chemin de code que les hotkeys. Le **post** de la notification suit les règles normatives de `12-notifications.md` : postée dans **tous** les modes sauf `.terminalOnly` (REQ-NOT-33), gating `notifyPermissionRequests` (REQ-NOT-08), unique suppression = panel déjà ouvert par interaction utilisateur (hover/clic, REQ-NOT-32) ; en mode `.both`, elle est garantie même panel ouvert (REQ-ACT-38).
- **REQ-ACT-40 (P0)** — **Privacy** : aucun contenu de prompt (commande, plan, question, feedback) n'est journalisé — uniquement identifiants, tailles, horodatages et codes de décision (`01-architecture.md` §7.3).

---

## 3. Conception technique

### 3.1 Séquence complète (permission Claude, cas nominal)

```
Claude Code            agentdash-hook           HookServer            EventRouter /            NotchUI + hotkeys
(agent)                (spawné)                 (queue réseau)        PromptStore (MainActor)
  │ PermissionRequest      │                        │                        │                        │
  ├─ spawn, JSON stdin ───►│                        │                        │                        │
  │                        ├─ connect + 1 ligne ───►│                        │                        │
  │                        │       NDJSON           ├─ DashEvent(.decision) ►│                        │
  │                        │                        │  reply: closure retenue├─ enqueue(PendingPrompt)│
  │                        │                        │                        │  session → waiting(T5) ├─► auto-expand (420 ms)
  │                        │                        │                        │                        ├─► carte + hotkeys ON
  │                        │   (connexion ouverte — l'utilisateur décide)    │                        │
  │                        │                        │                        │◄── decide(id, .allow) ─┤ ⌘A ou clic
  │                        │                        │◄─ reply(json + "\n") ──┤  session → executing   ├─► flash ✓, hotkeys OFF
  │                        │◄─ ligne réponse ───────┤   send + cancel        │  (T8, optimiste)       │   (si file vide)
  │◄─ stdout JSON, exit 0 ─┤                        │                        │                        │
  ├─ exécute le tool…      │                        │                        │                        │
  ├─ PreToolUse/PostToolUse (télémétrie) ──────────►│───────────────────────►│ corroboration+timeline │
```

Chemins alternatifs : auto-libération (REQ-ACT-07) = `reply` appelée avec corps vide à `expiresAt` ; app fermée = le hook voit `.waiting`/ENOENT et sort en exit 0 silencieux (fail-open, [VÉRIFIÉ]) ; connexion coupée = `handleConnectionClosed` retire le prompt (REQ-ACT-08).

### 3.2 API `PromptStore` (DashCore, @MainActor)

```swift
@MainActor @Observable
public final class PromptStore {
    public private(set) var prompts: [PendingPrompt] = []      // FIFO par receivedAt
    public private(set) var focusedPromptID: UUID?
    public var focusedPrompt: PendingPrompt? { prompts.first { $0.id == focusedPromptID } }
    public var hasActionablePrompt: Bool { !prompts.isEmpty }

    /// Appelé par EventRouter. `reply` capture la NWConnection (queue réseau) ; nil = corps vide.
    public func enqueue(_ prompt: PendingPrompt, reply: @escaping @Sendable (Data?) -> Void)
    /// Décision utilisateur (boutons, hotkey, notification). Idempotent : 2e appel = no-op.
    public func decide(_ id: UUID, _ decision: PromptDecision, via source: DecisionSource)
    public func focus(_ id: UUID)
    public func focusNext(after id: UUID)                       // avance FIFO post-décision
    /// Connexion fermée côté distant, ou obsolescence détectée (REQ-ACT-08/09).
    public func retire(_ id: UUID, outcome: PermissionOutcome)
    /// Tick 1 s (timer mutualisé) : auto-libération des prompts arrivés à expiresAt.
    public func releaseExpired(now: Date)
}
```

`decide` : (1) encode via `DecisionEncoder` ; (2) appelle `reply(data)` ; (3) applique la transition optimiste à `SessionStore` ; (4) émet le `TimelineEvent` ; (5) retire le prompt et `focusNext`. En mode `.terminalOnly`, `enqueue` court-circuite : `reply(nil)` immédiat, pas d'insertion.

### 3.3 `DecisionEncoder` — formats de réponse exacts [VÉRIFIÉ doc pour chaque forme]

```swift
enum DecisionEncoder {
    /// Retourne le corps à écrire tel quel sur stdout du hook ; nil = corps vide (« pas d'avis »).
    static func encode(_ d: PromptDecision, for p: PendingPrompt) -> Data?
}
```

| Cas | Corps JSON (Claude) |
|---|---|
| Allow | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| Always Allow | idem + `"updatedPermissions":[<permission_suggestions[0] écho exact>]` |
| Deny (± feedback) | `…"decision":{"behavior":"deny","message":"<texte ou omis>"}` |
| Approve plan | `behavior:"allow"` ± `updatedPermissions:[{"type":"setMode","mode":"acceptEdits","destination":"session"}]` |
| Reject plan | `behavior:"deny","message":"<feedback>"` |
| Réponses questions (via `PreToolUse`) | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[…original…],"answers":{"<texte question>":"<labels joints ', '>"}}}}` |
| Hand-in / auto-libération | **corps vide** (nil) |

| Cas | Corps JSON (Cursor) |
|---|---|
| Allow | `{"permission":"allow"}` |
| Deny (± feedback) | `{"permission":"deny","user_message":"<texte>","agent_message":"<texte>"}` (double champ tant que l'hypothèse n'est pas tranchée) |
| Hand-in / auto-libération | `{"permission":"ask"}` |

Si le prompt plan est arrivé par `PermissionRequest` (voie principale), Approve/Reject utilisent la forme `decision:{behavior:…}` ; par `PreToolUse` (secours), la forme `permissionDecision:"allow"|"deny"` + `permissionDecisionReason`.

### 3.4 `HonestCommandAnalyzer` (AgentClaude/AgentCursor → DashCore)

```swift
struct CommandEffect: Sendable {
    enum Kind: Sendable { case write, delete, move, copy, create, inPlaceEdit, permissions, gitDestructive }
    var kind: Kind
    var paths: [String]        // cibles détectées (relatives affichées telles quelles)
}
enum CommandAnalysis: Sendable {
    case effects([CommandEffect])   // vide = lecture seule apparente
    case opaque(reason: String)     // eval, $(…), pipe vers sh… → « Effects unclear »
}
func analyzeShellCommand(_ command: String) -> CommandAnalysis
```

Algorithme (heuristique assumée, jamais présentée comme une preuve) :
1. **Tokenisation** respectant `'…'`, `"…"` et `\` (pas de vrai parseur sh) ; échec de tokenisation → `.opaque`.
2. **Découpage** en commandes simples sur `;`, `&&`, `||`, `|`, `&`, retours ligne.
3. Pour chaque commande simple : ignorer les préfixes `VAR=x`, `env`, `sudo`, `nohup`, `time`, `nice`.
4. **Détection d'opacité** d'abord : présence de `` ` ``, `$(`, `eval`, `sh -c`/`bash -c`/`zsh -c`, `xargs`, `find … -exec`, pipe final vers `sh|bash|zsh` → `.opaque` (REQ-ACT-15), analyse stoppée.
5. **Redirections** : tout token `>`/`>>` (hors `2>&1`, `>&2`, cible `/dev/null`) → `.write(cible)` ; `tee [-a] f…` → `.write` ; `dd` avec `of=` → `.write` ; `truncate` → `.write`.
6. **Verbes** : `rm|rmdir|unlink` → `.delete(args non-options)` ; `mv` → `.move(dernier arg)` ; `cp|install|rsync` → `.copy(dernier arg)` ; `mkdir|touch` → `.create` ; `sed`/`perl` avec `-i` → `.inPlaceEdit(fichiers)` ; `chmod|chown` → `.permissions` ; `git reset --hard|clean -f…|checkout --` → `.gitDestructive`.
7. Restitution : bandeau « Writes files: a, b » / « Deletes: node_modules » / « Rewrites git state » ; sinon « Runs a command » sans bandeau.

### 3.5 ⌥T — retrouver le terminal de la session

```swift
func openHostApp(for session: Session) {
    // 1. Chaîne de parents (Claude : pid du registre ~/.claude/sessions/<pid>.json [VÉRIFIÉ]) :
    //    remonter pbi_ppid (max 5 niveaux) jusqu'à un PID possédé par une app GUI
    //    (NSRunningApplication(processIdentifier:) != nil) → activate() : amène LA bonne app.
    //    [HYPOTHÈSE : les runners peuvent exec/reparenter ; à valider par banc d'essai.]
    // 2. Sinon, table term_program → bundle id (transmis par l'enveloppe du hook [VÉRIFIÉ hérité]) :
    //    Apple_Terminal→com.apple.Terminal, iTerm.app→com.googlecode.iterm2,
    //    WarpTerminal→dev.warp.Warp-Stable, ghostty→com.mitchellh.ghostty,
    //    vscode→Cursor ou VS Code (désambiguïsation via __CFBundleIdentifier hérité [HYPOTHÈSE]).
    // 3. host == .ide → activer Cursor.app / VS Code ; .desktopApp → activer Claude.app.
    // 4. Fallback : NSWorkspace.open([URL(cwd)], withApplicationAt: Terminal.app) — ouvre un
    //    terminal AU cwd de la session. Aucune API privée, aucun TCC : activation d'app seulement.
}
```

### 3.6 Hotkeys éphémères — intégration

Le contrôleur `PromptHotKeys` (code validé, recherche system-integration §6.2) vit dans la cible app. Câblage :
- `withObservationTracking` sur `promptStore.hasActionablePrompt`, l'état du panel (ouvert + carte visible) et le first responder texte → `register()` quand tout est vrai, `unregister()` sinon (REQ-ACT-25/29). Ré-entrée idempotente.
- `register()` retourne `[Action: OSStatus]` d'échecs → publiés dans `DoctorStore.shortcutFailures` et lus par Settings → Shortcuts (REQ-ACT-26).
- `onAction` → `promptStore.decide(focusedID, mapped(action), via: .hotkey)` ; ⌥A ignoré si `!canAlwaysAllow` ; ⌥T → `openHostApp` ; mapping par `payload` (REQ-ACT-24).
- Timer 1 s mutualisé (architecture §5.2) : countdown UI + `releaseExpired`.

---

## 4. Spécification UX/UI

### 4.1 Zone Act dans le panel

La zone Act s'insère en tête du panel (au-dessus de la liste de sessions), n'existe que si ≥ 1 prompt vivant, et pousse le contenu avec une animation d'insertion (fade + slide 200 ms). Carte : pleine largeur du panel moins 12 pt de marge, coins arrondis 10 pt, fond `agentGlass()` renforcé, liseré latéral 3 pt couleur attention (orange) ; padding interne 12 pt ; densité/graisse suivent Appearance.

**En-tête de carte** (1 ligne, 20 pt) : mini-avatar agent (14 pt) · `projectName` (semibold) · titre de session tronqué · à droite « +2 waiting » + chevrons ‹ › si file (REQ-ACT-32) ; compte à rebours « Hands back to terminal in 0:42 » (11 pt, orange) quand < 60 s.

### 4.2 Carte Permission

```
┌─────────────────────────────────────────────────────────────┐
│ ◆ macos-ai-dashboard · Fix session dedup     +1 waiting ‹ › │
│ Claude wants to use Bash                                    │
│ ⚠ Writes files: src/Session.swift        ← REQ-ACT-14, si   │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ sed -i '' 's/old/new/' src/Session.swift                │ │  bloc SF Mono 11 pt,
│ │                                          Show more ▾    │ │  4 lignes max repliées
│ └─────────────────────────────────────────────────────────┘ │
│ Agent's description: “Update the session file”              │  11 pt, secondaire
│ in ~/Documents/macos-ai-dashboard                           │  11 pt, tertiaire
│ [ Deny ⌘N ]  [ Always Allow ⌥A ]        [ Allow ⌘A ]        │  boutons 26 pt
│ Deny with feedback…      Respond in terminal   ⌥T Terminal  │  liens 11 pt
└─────────────────────────────────────────────────────────────┘
```

Textes exacts (anglais) : titre `Claude wants to use <Tool>` / `Cursor wants to run a command` / `Cursor wants to call <tool> (MCP)` ; bandeaux honnêtes `Writes files: <a, b>`, `Deletes: <a>`, `Moves <a> → <b>`, `Rewrites git state`, `Changes permissions: <a>`, `Effects unclear — review the command` ; boutons `Allow`, `Deny`, `Always Allow` ; liens `Deny with feedback…`, `Respond in terminal`, `Open Terminal` ; feedback : placeholder `Explain why (sent to the agent)…`, boutons `Send` / `Cancel`. « Allow » = bouton primaire (accent) ; « Deny » neutre ; « Always Allow » neutre avec sous-libellé de destination (« for this project »). Échec hotkey → ⚠ 10 pt sur le raccourci du bouton, tooltip « Shortcut unavailable — see Settings → Shortcuts ».

### 4.3 Carte Plan

Chip `PLAN` (violet) + **titre stylisé** (H1 du Markdown, 15 pt bold — « titres de plan stylisés » §4.2) ; corps Markdown replié à ~240 pt (`Show more ▾`) ; section `Will request:` listant les `allowedPrompts` (icône outil + prompt, 11 pt) ; case à cocher `Switch to Accept Edits` ; boutons `Reject ⌘N` / `Approve ⌘A` (primaire) ; lien `Reject with feedback…`.

### 4.4 Carte Questions

Chip `QUESTION` (bleu) ; par question : `header` en chip 10 pt, texte 13 pt, pilules d'options (hauteur 24 pt, multi-lignes en flow layout ; sélection = fond accent ; multiSelect : mention `Select all that apply`), champ `Type your own answer…` (32 pt). Questions empilées, séparateur hairline ; > hauteur du panel → scroll interne. Pied : `Submit ⏎` (primaire, désactivé tant que REQ-ACT-21 non satisfaite) + `Respond in terminal`. Cursor non actionnable : mêmes chips, corps descriptif, unique bouton `Respond in Cursor`.

### 4.5 États, animations, surfaces secondaires

- **Arrivée** : auto-expand 420 ms (si activé) ; sinon pill en état attention (teinte orange pulsée lente) + point orange menu bar. Son : aucun (les sons relèvent des notifications).
- **Décision** : le bouton choisi affiche ✓ (ou ✕ pour Deny) 250 ms, la carte se replie (300 ms, ease-in), la suivante glisse en place (250 ms). La row de session reflète immédiatement le nouvel état (couleur + avatar).
- **Auto-libération / obsolescence** : repli sans coche, toast discret 2 s « Handed back to terminal ».
- **Saisie texte** : le clic dans un champ rend le panel key (`becomesKeyOnlyIfNeeded` [VÉRIFIÉ recette]) ; Échap annule le champ (et rend le focus à l'app précédente), pas le prompt.
- **Menu bar** : le popover liste les prompts en attente (ligne titre + projet) ; clic → ouvre le panel focalisé sur ce prompt.

---

## 5. Cas limites & gestion d'erreurs

| # | Cas | Comportement |
|---|---|---|
| 1 | App fermée / crashée quand l'agent déclenche | Hook : `.waiting`/ENOENT → exit 0 silencieux ; dialogue natif de l'agent. Rien à faire côté app [VÉRIFIÉ]. |
| 2 | Utilisateur répond dans le terminal pendant l'attente | REQ-ACT-09 : obsolescence détectée (événement suivant du même tool) → retrait + libération. [HYPOTHÈSE n°1 claude-code : le dialogue natif est probablement différé tant que le hook retient — banc d'essai prioritaire.] |
| 3 | Timeout agent atteint malgré la marge (horloge dérivée, sommeil) | La connexion meurt côté agent → REQ-ACT-08 (retrait silencieux). `didWakeNotification` déclenche `releaseExpired` immédiat au réveil. |
| 4 | `permission_suggestions` vide ou absent | `canAlwaysAllow = false` → bouton masqué, ⌥A no-op (REQ-ACT-13/24). |
| 5 | Deux prompts pour la même session (subagents) | File FIFO les garde tous deux ; `Session.pendingPrompt` = le plus ancien non résolu (REQ-ACT-34). |
| 6 | Prompt pendant que le champ feedback d'un autre est ouvert | La carte focalisée ne change pas ; compteur « +N waiting » s'incrémente ; pas de vol de focus. |
| 7 | Session tuée (Kill) ou `SessionEnd`/`/clear` avec prompt vivant | Retrait + libération (corps vide/`ask`), outcome `.released`, marqueur timeline. |
| 8 | Plan/tool_input énorme (ligne 70 Ko observée [VÉRIFIÉ]) | Rendu paresseux + troncature REQ-ACT-35 ; le JSON complet n'est jamais copié dans les logs (REQ-ACT-40). |
| 9 | Markdown de plan invalide | Fallback texte brut monospace ; jamais d'échec de rendu bloquant. |
| 10 | JSON d'événement malformé sur le socket | EventRouter répond corps vide et ferme ; aucun `PendingPrompt` créé ; compteur d'erreurs Doctor. |
| 11 | Échec d'enregistrement hotkey (Raycast, etc.) | REQ-ACT-26 : avertissement persistant, boutons opérationnels. Re-tentative à chaque nouvel enregistrement éphémère. |
| 12 | Changement de disposition clavier pendant un prompt | Désenregistrement + résolution + ré-enregistrement (REQ-ACT-27). |
| 13 | notch **et** menu bar désactivés | Comportement `.terminalOnly` forcé : libération immédiate, l'agent garde la main. Jamais de prompt retenu sans surface pour y répondre. |
| 14 | `updatedInput.answers` inopérant en interactif | Feature flag fallback `deny + reason` (REQ-ACT-22) ; décision au banc d'essai, pas en production. |
| 15 | Hooks tiers en parallèle répondant `deny` | La fusion Claude Code « le plus restrictif gagne » [VÉRIFIÉ doc] peut contredire notre Allow ; la corroboration (REQ-ACT-06) constate le refus réel → timeline reflète l'issue effective, pas notre intention. |
| 16 | Réponse `ask` Cursor sans UI Cursor visible | La main revient à Cursor ; AgentDash garde `waiting` via `hasBlockingPendingActions` (réconciliation DB). |
| 17 | Écran sans notch / panel sur écran externe | Aucune différence : la zone Act vit dans le panel, positionné par NotchUI. |
| 18 | Double décision (⌘A + clic quasi simultanés) | `decide` idempotent (REQ-ACT-05) : la seconde est ignorée. |
| 19 | Feedback vide + « Send » | Bouton Send désactivé si champ vide (Deny sec disponible par ailleurs). |
| 20 | Suspension de l'app (SIGSTOP) pendant une attente | À la reprise, `releaseExpired` purge les prompts périmés avant tout rendu. |

---

## 6. Critères d'acceptation

1. **Given** une session Claude Code interactive avec hooks installés et AgentDash ouvert, **When** Claude demande la permission d'exécuter `npm test`, **Then** le panel s'auto-étend en < 1 s, affiche « Claude wants to use Bash » avec la commande, et les boutons Allow/Deny/Always Allow ; **When** je presse ⌘A, **Then** le terminal affiche « Allowed by PermissionRequest hook » et la commande s'exécute sans que je touche au terminal.
2. **Given** un prompt permission visible, **When** je clique « Deny with feedback… », tape « use pnpm instead » et Send, **Then** Claude reçoit le message et reformule sa prochaine action en conséquence ; la timeline montre « Permission denied (notch) ».
3. **Given** un prompt avec `permission_suggestions` non vide, **When** je presse ⌥A, **Then** la règle est persistée (visible dans `~/.claude/settings.local.json` selon `destination`) et la même commande ne redemande plus de permission ; **Given** un prompt Cursor, **Then** le bouton Always Allow est absent et ⌥A ne fait rien.
4. **Given** Claude propose un plan (`ExitPlanMode`), **When** le prompt s'affiche, **Then** je vois le titre H1 stylisé, le plan en Markdown replié avec « Show more », la liste « Will request: » ; **When** je clique Approve avec « Switch to Accept Edits » coché, **Then** Claude sort du plan mode en `acceptEdits` (visible via `permission_mode` des hooks suivants).
5. **Given** Claude pose 2 questions via `AskUserQuestion` (une à options, une multiSelect), **When** je sélectionne une pilule + deux pilules, **Then** Submit s'active ; **When** je soumets, **Then** le sélecteur du terminal ne s'affiche pas et Claude poursuit avec mes réponses (ou, si le flag fallback est actif, reçoit mes réponses en feedback de refus).
6. **Given** deux sessions (Claude + Cursor) demandant chacune une permission, **Then** la carte du plus ancien est focalisée avec « +1 waiting » ; **When** je décide, **Then** la seconde carte glisse en place automatiquement et ⌘A n'agit que sur elle.
7. **Given** un prompt visible et le champ de feedback focalisé, **When** je tape la lettre « a » avec ⌘ enfoncé (habitude « tout sélectionner »), **Then** aucune décision n'est prise (hotkeys suspendues) ; **When** le champ perd le focus, **Then** ⌘A redevient actif.
8. **Given** aucun prompt visible, **Then** `⌘A` dans n'importe quelle app fait « Tout sélectionner » normalement (aucune hotkey résiduelle — vérifiable dans TextEdit).
9. **Given** Raycast a réservé ⌥T, **When** un prompt apparaît, **Then** Settings → Shortcuts affiche l'avertissement d'échec et le bouton « Open Terminal » de la carte fonctionne au clic.
10. **Given** un prompt sans décision pendant 590 s (timeout 600 s), **Then** AgentDash rend la main (toast « Handed back to terminal »), le dialogue natif de Claude apparaît dans le terminal, et la session reste `waiting` dans la liste.
11. **Given** `promptHandling = terminalOnly`, **When** une permission arrive, **Then** aucune carte n'apparaît, le dialogue natif s'affiche immédiatement, la row de session passe en waiting avec badge orange.
12. **Given** une commande `rm -rf node_modules && curl x | sh`, **Then** la carte affiche « Deletes: node_modules » **et** « Effects unclear — review the command » (partie opaque), jamais un libellé rassurant.
13. **Given** AgentDash quitté brutalement pendant 3 prompts en attente, **Then** chaque agent affiche son dialogue natif en quelques secondes et aucune session n'est bloquée.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances entrantes** : `01-architecture.md` (contrat IPC §4.1, classification décision/télémétrie, budgets, hotkeys éphémères §8.7) ; `02-data-model.md` (`PendingPrompt`, `PromptDecision`, `PromptCapabilities`, machine à états §3, constantes §3.4) ; document **hooks & installation** (timeouts posés dans `settings.json`/`hooks.json`, enveloppe `HookEnvelope` avec `term_program`/`ppid`) ; document **NotchUI** (panel, auto-expand, `agentGlass()`, gestion key window) ; document **sessions** (transitions, timeline, registre PID pour ⌥T) ; document **notifications** (catégorie `PERMISSION_REQUEST` actionnable) ; document **Settings/Doctor** (onglet Shortcuts, publication des échecs d'enregistrement).

**Risques majeurs** (bancs d'essai `scripts/experiments/` AVANT implémentation, cf. `01-architecture.md` §9) :
1. **Hypothèse claude-code n°1** — comportement du dialogue terminal pendant la rétention `PermissionRequest` : conditionne l'UX entière et la sémantique de « prompt handling location ». *Mitigation* : banc d'essai chronométré ; en cas de conflit dur, `.terminalOnly` par défaut et `.notch` opt-in.
2. **Hypothèse claude-code n°2** — `updatedInput.answers` en interactif : REQ-ACT-22 fournit le fallback sans changement d'UI.
3. **Hypothèse cursor n°2** — plafond réel du `timeout` des hooks Cursor : si < 60 s, les permissions Cursor deviennent quasi inactionnables dans le notch ; *mitigation* : auto-libération adaptée à la valeur mesurée + documentation Doctor.
4. **Hotkeys** — consommation de ⌘A depuis un `NSPanel` non activant à confirmer par test UI (question ouverte n°5 de system-integration) ; conflits avec les launchers répandus (REQ-ACT-26 les rend non bloquants). **[RÉSULTAT SPIKE — M2, 3 juillet 2026]** : `RegisterEventHotKey` est **global** (capture ⌘A partout, y compris le « select-all » de l'éditeur) — vérifié empiriquement (un ⌘A hors app déclenchait Allow). *Mitigation adoptée et implémentée* : le handler n'agit que si **le panneau notch est la key window** (`panel.isKeyWindow`) ; dès que l'utilisateur bascule dans une autre app, notre app resigne, le panneau perd le statut key, et ⌘A retrouve son sens natif ailleurs. ⌥T (Open Terminal) reste permis sans ce garde. Test passif validé : aucun auto-allow sans engagement délibéré du notch. La frappe ⌘A n'est donc active que lorsque l'utilisateur a cliqué/engagé le notch (les boutons cliquables restent le chemin nominal, toujours actifs).
5. **Reformulation honnête** — heuristique shell : risque de faux positifs/négatifs ; *mitigation* : biais assumé vers `.opaque` (ne jamais rassurer à tort), corpus de tests de commandes réelles.

---

## 8. Découpage en tâches

| # | Tâche | Contenu | Taille |
|---|---|---|---|
| A1 | Banc d'essai hypothèses n°1/n°2 Claude + timeout Cursor | scripts `experiments/permission-request-interactive`, `ask-user-question-answers`, `cursor-hook-timeout` ; rapport de mesures | **M** |
| A2 | `PromptStore` + cycle de vie | enqueue/decide/retire/releaseExpired, invariant connexion⇔prompt, file FIFO + focus, idempotence | **M** |
| A3 | `DecisionEncoder` + tests | toutes les formes §3.3 (Claude/Cursor), tests unitaires d'or (golden JSON) | **S** |
| A4 | Intégration EventRouter → PromptStore | classification décision/télémétrie, capabilities, transitions optimistes T8–T12/C6, corroboration | **M** |
| A5 | Carte Permission (NotchUI) | layout §4.2, boutons, feedback inline, états décidé/expiré, animations | **L** |
| A6 | Carte Plan | rendu Markdown + titre stylisé, allowedPrompts, Accept Edits, Approve/Reject | **M** |
| A7 | Carte Questions | multi-questions, pilules, multiSelect, texte libre, validation Submit, fallback flag | **L** |
| A8 | File multi-prompts UI | compteur « +N waiting », chevrons, focus depuis rows/menu bar | **M** |
| A9 | `PromptHotKeys` intégré | enregistrement éphémère, résolution AZERTY (`UCKeyTranslate`), suspension saisie, publication des échecs | **M** |
| A10 | ⌥T `openHostApp` | chaîne ppid + table `term_program` + fallbacks, banc d'essai reparentage | **M** |
| A11 | `HonestCommandAnalyzer` | tokenisation, tables d'effets, détection d'opacité, corpus de tests (≥ 60 commandes) | **M** |
| A12 | « Prompt handling location » + route notifications | 3 modes, court-circuit `.terminalOnly`, actions de notification → `decide` | **S** |
| A13 | Auto-libération & countdown | timer mutualisé, réveil (`didWakeNotification`), toast, outcome `.released` | **S** |
| A14 | Tests d'intégration bout en bout | agent réel (Claude CLI) : scénarios d'acceptation 1–5, 10, 13 scriptés en checklist | **L** |

Ordre : A1 d'abord (dérisque tout), puis A2–A4 (moteur), A5/A9 (MVP permission = cœur v0.1.0), A6–A8, A10–A13, A14 en continu.
