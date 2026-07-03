# 7. Sessions — liste, carte, timeline et actions

> Spécification de la feature « Watch » : la liste des sessions Claude Code + Cursor, la carte de session, la row étendue (timeline) et les actions associées. Rédigée le 3 juillet 2026, conforme à `plan/01-architecture.md` (modules, threading, budgets) et `plan/02-data-model.md` (types `Session`, `SessionState`, `TimelineEvent`, règles de déduplication §1.1 et cycle de vie §7).
> Convention : **[VÉRIFIÉ]** = adossé aux recherches (`plan/research/claude-code.md`, `plan/research/cursor.md`) ou à la doc AgentPeek ; **[TRANCHÉ produit]** = règle que nous fixons car AgentPeek ne la documente pas ; **[HYPOTHÈSE — à valider]** = à confirmer en implémentation.

---

## 1. Objectif & périmètre

Reproduire intégralement la section **3 « Monitoring des sessions (Watch) »** d'`AGENTPEEK_FEATURES.md` (§3.1 liste, §3.2 carte, §3.3 session étendue), ainsi que les points de §14.4 (« Sessions : liste triée par projet, états, tokens live input/output, diffs, timeline des tool calls, subagents, Markdown, Copy as Markdown, Kill, dédoublonnage, desktop + terminal ») et les items de fiabilité de §3.1 (« déduplication », « reconnexion automatique », « `/clear` ne retire pas la session », « session relancée en cours de tour ne perd pas son dernier tour »).

**Dans le périmètre** : modèle de présentation de la liste (tri, regroupement), carte de session, row étendue (extraits Markdown, timeline complète virtualisée, subagents), actions Kill / refresh usage / Copy Session as Markdown / Dismiss, règles de déduplication et de survie des rows.
**Hors périmètre (autres documents du plan)** : machine à états elle-même (`02-data-model.md` §3), transport hooks/IPC et installeurs (document Hooks & IPC), parsing détaillé des transcripts et de `state.vscdb` (documents d'ingestion AgentClaude/AgentCursor), prompts actionnables (document Actions inline), conteneur notch/pill et réglage `sessionListSizing` fixe/growable (document Notch UI), jauges d'usage de compte (document Usage).

Modules concernés : `DashCore` (SessionStore, tri, résumés), `NotchUI` (cartes, avatars, timeline), `AgentClaude`/`AgentCursor` (backfill de timeline, tables de traduction), `AgentDashApp` (kill, presse-papiers).

---

## 2. Exigences détaillées

### 2.1 Liste et regroupement

- **REQ-SES-01 (P0)** — La liste affiche **toutes** les sessions Claude Code et Cursor connues (terminal, extension IDE, apps desktop) en un seul endroit ; plusieurs sessions de projets différents sont visibles simultanément. Une session Claude est détectée par hook `SessionStart`, par le registre `~/.claude/sessions/<pid>.json` ou par un `.jsonl` actif ; une session Cursor par hook `sessionStart` ou par `composer.composerHeaders.allComposers` **[VÉRIFIÉ]**.
- **REQ-SES-02 (P0)** — Les sessions sont **regroupées par projet** : clé de groupe = `projectPath` normalisé (chemin absolu, sans slash final) ; libellé de groupe = `projectName` (basename). Les sessions sans projet identifiable (`cwd` inconnu) vont dans un groupe terminal « Other » affiché en dernier. **[TRANCHÉ produit]**
- **REQ-SES-03 (P0)** — **Tri des groupes** (ordre lexicographique de la clé composite) : (1) groupe contenant ≥ 1 session `waiting` d'abord ; (2) puis `max(lastEventAt)` des sessions visibles du groupe, décroissant ; (3) égalité résiduelle : `projectName` croissant insensible à la casse, puis `projectPath` croissant. **[TRANCHÉ produit]**
- **REQ-SES-04 (P0)** — **Tri intra-groupe** : (1) rang d'état — `waiting` = 0, `executing` = 1, `thinking` = 2, `idle` vivant = 3, `ended` = 4 ; (2) `lastEventAt` décroissant ; (3) `startedAt` décroissant ; (4) `rawID` croissant (ordre total et stable, donc testable). **[TRANCHÉ produit]**
- **REQ-SES-05 (P1)** — **Anti-sautillement** : un réordonnancement causé uniquement par `lastEventAt` est appliqué au plus une fois toutes les 2 s (coalescence) ; un changement de rang d'état ou l'apparition/disparition d'une session réordonne immédiatement. Tout déplacement de row est animé (spring ≈ 300 ms — « animations de sessions » v0.2.11 **[VÉRIFIÉ features]**).
- **REQ-SES-06 (P0)** — Les sessions **desktop apparaissent dès le lancement de l'agent**, sans attendre une activité : détection Claude via l'apparition d'un fichier dans `~/.claude/sessions/` (PID vivant) **[HYPOTHÈSE claude-code n°4 — à valider]**, Cursor via `allComposers` au poll suivant.
- **REQ-SES-07 (P2)** — Si deux `projectPath` distincts partagent le même basename, les libellés de groupe sont désambiguïsés par le dossier parent (« medmed — ~/Documents/medmed »). **[TRANCHÉ produit]**

### 2.2 Identité et déduplication

- **REQ-SES-08 (P0)** — **Clé unique** : toute donnée entrante (hook, transcript, registre PID, `allComposers`, transcript Cursor) est résolue en `SessionID(agent, rawID)` **avant** insertion dans `SessionStore` ; il est structurellement impossible d'avoir deux rows pour la même session (invariant `02-data-model.md` §8.1-1). Les « doublons fusionnés en une seule ligne » d'AgentPeek sont obtenus par construction.
- **REQ-SES-09 (P0)** — **Registre PID Claude** : un fichier `~/.claude/sessions/<pid>.json` n'est pris en compte que si `kill(pid, 0)` réussit **et** que `pbi_start_tvsec` du process est cohérent avec `procStart` du fichier (orphelins de crash ignorés). Deux fichiers PID portant le même `sessionId` (resume dans un autre process) ⇒ une seule row, `pid` = celui du fichier le plus récent. **[VÉRIFIÉ mécanique / HYPOTHÈSE claude-code n°4 sur le cycle de vie du fichier]**
- **REQ-SES-10 (P0)** — **Filtres Cursor** : les composers `isDraft`, `isArchived`, `isBestOfNSubcomposer` sont masqués ; une entrée avec `subagentInfo` n'est jamais une session racine — son activité est rattachée à `rootParentConversationId`. **[VÉRIFIÉ cursor §2.3]**
- **REQ-SES-11 (P0)** — **Subagents Claude** : les transcripts `<session>/subagents/…` et toute entrée `isSidechain: true` ne créent jamais de session ; ils alimentent `subagents` et la timeline (marqués sidechain) de la session parente. **[VÉRIFIÉ claude-code §3.2]**
- **REQ-SES-12 (P0)** — **Conflit de sources** : pour un même champ, ordre de confiance = hook (< 15 s, `hookAuthorityWindow`) > registre/DB > transcript ; `lastEventAt` porte l'horodatage de la source gagnante (règle `02-data-model.md` §1.1-5).

### 2.3 Cycle de vie visible (reconnexion, /clear, resume)

- **REQ-SES-13 (P0)** — **Reconnexion automatique** : après un redémarrage d'AgentDash, la liste est intégralement reconstruite (registre + `allComposers` + transcripts `mtime` < 48 h) en < 1 s pour 100 Mo de transcripts (budget §6 architecture), **sans doublon** et avec états recalculés par les règles de fallback (`02-data-model.md` §3.3). Après réveil machine (`didWakeNotification`), liveness et états sont réévalués sans intervention.
- **REQ-SES-14 (P0)** — **`/clear` ne retire pas la session** : sur `SessionEnd(reason: clear)` puis `SessionStart(source: clear)` (nouveau `sessionId` **[VÉRIFIÉ]**), l'ancienne row passe `liveness = .ended(.cleared)`, **reste listée** (dismissable), reçoit un marqueur timeline « Session cleared » ; la nouvelle session est chaînée (`clearedFrom`) et prend la position visuelle de l'ancienne dans le groupe.
- **REQ-SES-15 (P0)** — **Session relancée en cours de tour** : un `SessionStart(source: resume)` portant un `sessionId` déjà connu met à jour `pid`/`host` de la **même** row ; timeline, `TokenTally`, compteurs et diff du tour en cours sont **conservés** (jamais remis à zéro) ; un marqueur « Session resumed » est ajouté. Le dernier tour reste visible même si l'agent a été tué au milieu (les entrées partielles du transcript ont déjà été ingérées). **[HYPOTHÈSE claude-code n°7 : resume multi-fichiers — si un nouveau `.jsonl` est créé, le chaînage doit fusionner vers la même row]**
- **REQ-SES-16 (P0)** — **Fin de session** : `SessionEnd` (exit/logout) ou PID disparu ⇒ `liveness = .ended(…)`, compteurs figés, row conservée jusqu'au GC (`sessionRetentionHours` = 24 h, uniquement si `ended`). Kill utilisateur ⇒ `.ended(.killed)`.

### 2.4 Carte de session (row repliée)

- **REQ-SES-17 (P0)** — **Avatar pixel-grid animé** : chaque session affiche un avatar 24 × 24 pt rendu par `PixelAvatarView` (§3.3 — **spécification canonique unique du composant, référencée par `05-notch-ui.md` REQ-NUI-52…54** ; aucun jeu de constantes concurrent ailleurs) : grille 5 × 5, motif stable dérivé de `hash(SessionID)` (symétrie verticale, type identicon **[TRANCHÉ produit]**), animé selon l'état : **vague diagonale** quand `executing` (1,2 Hz) / `thinking` (0,5 Hz, amplitude réduite), **rotation calme** quand `waiting`, statique atténué quand `idle`/`ended` (« vague diagonale quand actif, rotation calme quand en attente » **[VÉRIFIÉ features §3.2]**). Animation ≤ 20 fps, **en pause** quand le panel est fermé ou la row hors écran (exception : l'avatar agrégé du pill reste animé à 10 fps max — 05 REQ-NUI-54) ; budget CPU idle < 0,5 %.
- **REQ-SES-18 (P0)** — **État par couleur + mouvement** : `executing` = vert `stateExecuting` (mouvement rapide), `thinking` = cyan `stateThinking` (pulsation lente), `waiting` = orange `stateWaiting` (rotation calme + halo), `idle` = gris `stateIdle` (statique), `ended` = gris atténué + libellé. Les valeurs des teintes sont les **tokens d'état de `05-notch-ui.md` §4.5 (source unique — aucune palette propre ici)**. Couleurs appliquées à l'avatar et à la pastille d'état ; tooltip texte : « Executing » / « Thinking » / « Waiting for you » / « Idle » / « Ended ». **[TRANCHÉ produit pour le mapping état → teinte ; valeurs exactes : hypothèse à calibrer en 05 §4.5]**
- **REQ-SES-19 (P0)** — **Identité** : nom d'agent (« Claude Code » / « Cursor ») + titre de session (`ai-title` Claude, `name` Cursor **[VÉRIFIÉ]**) ; à défaut de titre : `projectName`.
- **REQ-SES-20 (P0)** — **Activité récente en langage clair** : la carte affiche le résumé du dernier `TimelineEvent` (règles de résumé §3.4, table exhaustive) ; Cursor : repli sur `subtitle` de `composerHeaders` si aucune timeline n'est encore chargée **[VÉRIFIÉ cursor §2.3]**. Une ligne, troncature en fin avec « … ».
- **REQ-SES-21 (P0)** — **Tokens live input/output** : chip « `24.6k / 66` » (input / output), où input = **`input_tokens` seul** et output = `output_tokens` (spécification normative du chip : `09-token-usage.md` REQ-USG-41/44) ; le total input **caches inclus** (`+ cache_read_input_tokens + cache_creation_input_tokens`, écart possible ×100 — piège du cache, cf. 09 REQ-USG-24) n'est montré qu'au survol, tooltip « 24.6k in (1.2M with cache) / 66 out ». Valeurs sommées sur les entrées `assistant` **dédupliquées par `requestId`** (dernière entrée du même `requestId` gagne — streaming cumulatif **[VÉRIFIÉ claude-code §3.4]**). Mise à jour **mid-turn** au fil des entrées partielles, coalescée à 300 ms par session (architecture §5.2) ; pendant `isLive`, la chip porte un shimmer discret (« token chip mid-turn » v0.2.11).
- **REQ-SES-22 (P0)** — **Format numérique des tokens** : 0–999 → tel quel (« 66 ») ; 1 000–99 949 → millier à 1 décimale (« 24.6k », décimale supprimée si nulle : « 24k ») ; 99 950–999 499 → millier entier (« 245k ») ; ≥ 999 500 → million à 1 décimale (« 1.2M »). Arrondi à la valeur la plus proche. **[TRANCHÉ produit — l'exemple AgentPeek « 24.6k / 66 » est respecté]**
- **REQ-SES-23 (P0)** — **Cursor sans tally par tour** : `tokenCount` des bulles ≈ 0 **[VÉRIFIÉ cursor §2.5]** ⇒ pas de chip input/output pour Cursor ; à la place, chip de **contexte** « `ctx 72%` » (format normalisé, identique à `04-integration-cursor.md` §4.2 et `09-token-usage.md` §4.6 ; source : `contextTokensUsed`/`contextTokenLimit`). Si une source fiable émerge, la chip tokens s'active **[HYPOTHÈSE cursor n°3]**.
- **REQ-SES-24 (P0)** — **Compteurs fichiers/commandes** : fichiers = `file_path` distincts des `tool_use` `Edit|Write|NotebookEdit` (Claude) / `filesChangedCount` (Cursor) ; commandes = nombre de `tool_use` `Bash` (Claude) / `run_terminal_command_v2` (Cursor). Affichage « 6 files · 12 cmds », masqué à zéro. **[VÉRIFIÉ sources]**
- **REQ-SES-25 (P0)** — **Stats de diff** : « +120 −34 » ; Claude = somme des hunks `structuredPatch`, Cursor = `totalLinesAdded`/`totalLinesRemoved` **[VÉRIFIÉ]** ; + en vert, − en rouge, masqué si 0/0.
- **REQ-SES-26 (P0)** — **Environnement hôte** : étiquette « iTerm » / « Terminal » / « Warp » / « Ghostty » (via `TERM_PROGRAM` de l'enveloppe hook **[VÉRIFIÉ]**), « Cursor » / « VS Code » (entrypoint `claude-vscode` + IDE lock, ou session Cursor), « Desktop » (`claude-desktop-3p` **[VÉRIFIÉ issue GitHub]**), « — » si inconnu.
- **REQ-SES-27 (P0)** — **Temps écoulé** : depuis `startedAt`, mis à jour par le timer mutualisé 1 s, re-render seulement si la chaîne change. Format : < 60 s → « 42s » ; < 1 h → « 7m » ; < 24 h → « 1h 24m » ; ≥ 24 h → « 2d 3h ». **[TRANCHÉ produit]**
- **REQ-SES-28 (P1)** — **Label de compte** : chip du compte d'abonnement associé (`UsageAccount.label`, ex. e-mail ou plan) quand il est connu — source Claude = JSON OAuth **[HYPOTHÈSE claude-code n°5]**, Cursor = `cursorAuth/cachedEmail` + `stripeMembershipType` **[VÉRIFIÉ local]**. Masqué si inconnu.
- **REQ-SES-29 (P1)** — **Badge stale** : `isStale == true` (120 s sans événement en `executing`/`thinking`) affiche un badge horloge sur la carte **sans changer l'état ni la couleur** ; il disparaît au prochain événement. (La notification « stuck » relève du document Notifications.)

### 2.5 Row étendue (clic sur la carte)

- **REQ-SES-30 (P0)** — Un clic sur la carte l'**étend en place** (animation 250 ms) ; un seul déplié à la fois par surface ; re-clic sur l'en-tête ou Échap replie. **[TRANCHÉ produit]**
- **REQ-SES-31 (P0)** — **Extrait de réponse en Markdown** : la dernière réponse assistant (`last_assistant_message` du hook `Stop`, sinon dernière entrée `assistant` du transcript / dernière bulle `type 2` Cursor) est rendue via `AttributedString(markdown:)` avec repli texte brut si le parsing échoue. Replié à **3 lignes** avec bouton « Show more » ; déplié complet avec « Show less » (hauteur max 240 pt puis scroll interne). **[VÉRIFIÉ features §3.3 pour les libellés]**
- **REQ-SES-32 (P0)** — **Timeline horodatée complète** : historique de **tous** les tool calls et événements (prompts, réponses, thinking, permissions, plans, questions, compactions, marqueurs de session), chacun avec heure (`HH:mm:ss`, format 12/24 h selon réglage) et résumé en langage clair (§3.4). **Aucune limite d'historique côté données** : le compteur d'en-tête affiche le total réel (« 1,240 events »).
- **REQ-SES-33 (P0)** — **Fenêtrage RAM + backfill** : au plus `timelineWindowSize` (2 000) événements rendus en mémoire (architecture §6) ; le scroll vers le haut charge les plus anciens par lots de 500 via relecture paresseuse du transcript (Claude) ou de `fullConversationHeadersOnly` → `bubbleId:*` (Cursor) **[VÉRIFIÉ sources]** ; indicateur « Load earlier events » pendant le chargement.
- **REQ-SES-34 (P0)** — **Performance timeline** : rendu virtualisé (`LazyVStack` dans `ScrollView`, identités stables) ; avec 5 000 événements chargés successivement, le scroll reste fluide (pas de hitch > 32 ms mesuré Instruments) et l'ingestion d'un nouvel événement ne re-rend que les rows affectées. Auto-scroll vers le bas uniquement si l'utilisateur est déjà en bas (pin).
- **REQ-SES-35 (P1)** — **Activité des subagents** : les événements sidechain sont indentés et préfixés d'un connecteur « ⌞ » dans la timeline ; une section « Subagents » liste chaque `SubagentActivity` (type, statut running/completed/failed, durée, résumé) — alimentée par `SubagentStart`/`SubagentStop` (Claude) et `subagentStart`/`subagentStop` (Cursor) **[VÉRIFIÉ]**.
- **REQ-SES-36 (P2)** — **Todos** : si `todos` non vide (Cursor `composerData.todos`, Claude `todo_reminder` **[VÉRIFIÉ]**), une section repliée « Todos (n) » liste contenu + statut.

### 2.6 Actions

- **REQ-SES-37 (P0)** — **Kill avec confirmation** : bouton « Kill » (rows Claude avec `pid` connu et `liveness == .live` uniquement ; jamais pour Cursor — `pid` = nil). Premier clic → le bouton devient « Confirm? » (rouge) pendant 3 s ; second clic dans la fenêtre → re-validation `(pid vivant, start_time identique, execPath cohérent)` puis SIGTERM → 3 s → SIGKILL (garde-fous architecture §8.4). Timeout des 3 s → retour à « Kill ». Résultat : `.ended(.killed)` + marqueur timeline ; si le process a déjà disparu : toast « Process already exited ».
- **REQ-SES-38 (P1)** — **Refresh usage** : bouton sur la row étendue qui force un refresh du poller d'usage du compte associé à la session (anti-rafale 10 s, shimmer sur les jauges pendant le refresh — cf. document Usage) ; il rafraîchit aussi immédiatement `contextUsage` (Cursor) via une lecture DB.
- **REQ-SES-39 (P1)** — **Copy Session as Markdown** : entrée de menu contextuel qui exporte la session **complète** (pas seulement la fenêtre rendue) au format défini en §3.6, via `Task.detached` (relecture du transcript hors MainActor), puis place le résultat dans `NSPasteboard.general`. Feedback : l'item affiche « Copied ✓ » 1,5 s. Aucune donnée ne quitte la machine.
- **REQ-SES-40 (P1)** — **Dismiss des sessions silencieuses** : entrée « Dismiss Session » disponible quand la session est `idle` sans `pendingPrompt`, ou `ended`. Effet : `isDismissed = true`, row masquée, données conservées. **Ré-affichage automatique** si un nouvel événement arrive (le dismiss n'est pas un blocage). **[TRANCHÉ produit pour la règle de ré-affichage]**
- **REQ-SES-41 (P1)** — Le menu contextuel (clic droit ou bouton « ⋯ ») expose : « Copy Session as Markdown », « Refresh Usage », « Dismiss Session », « Kill Session… » (dans cet ordre ; items désactivés si non applicables).

### 2.7 Transverses

- **REQ-SES-42 (P0)** — **Latence** : un événement hook met à jour la carte en < 150 ms (budget architecture) ; un changement d'état repositionne la row selon REQ-SES-04/05.
- **REQ-SES-43 (P0)** — **État vide** : sans aucune session, la section affiche « No sessions yet » + sous-titre « Sessions appear when Claude Code or Cursor is active. » ; si les hooks ne sont pas installés, une bannière « Install hooks to see live sessions » pointe vers Settings → General (mode lecture seule par transcripts/DB restant actif — architecture §7.2).
- **REQ-SES-44 (P1)** — **Mode dégradé sans hooks** : les sessions détectées uniquement par transcripts/DB s'affichent avec les mêmes cartes ; l'état suit les règles de fallback ; `waiting` n'est jamais inféré pour Claude sans signal explicite **[VÉRIFIÉ : les transcripts ne marquent pas la demande de permission]**.

---

## 3. Conception technique

### 3.1 Stores et modèle de présentation (DashCore, @MainActor)

```swift
@MainActor @Observable
public final class SessionStore {
    public private(set) var sessions: [SessionID: Session] = [:]
    public private(set) var groups: [SessionGroup] = []          // dérivé, trié (§3.2)

    public func apply(_ delta: SessionDelta)                     // unique point de mutation (hooks, ingestors)
    public func dismiss(_ id: SessionID)
    public func requestKill(_ id: SessionID)                     // délègue à SessionKiller (§3.5)
    public func expand(_ id: SessionID?)                         // ≤ 1 row étendue par surface

    public var expandedSessionID: SessionID?
    // Attention « waiting » : PAS de helper propre ici. Définition canonique unique :
    // `hasPendingAttention` (extension DashCore de SessionStore, 06-menubar.md §3.2),
    // filtrée `!isDismissed && liveness == .live && state.isWaiting`, consommée par le
    // point orange menu bar (06 REQ-MBR-04) et l'auto-expand du notch (12 REQ-NOT-32).
}

public struct SessionGroup: Identifiable, Sendable {
    public let id: String            // projectPath normalisé ; "~other" pour le groupe résiduel
    public var displayName: String   // basename, désambiguïsé si collision (REQ-SES-07)
    public var sessionIDs: [SessionID]
}

/// Delta Sendable produit par EventRouter / TranscriptIngestor / CursorStateReader (coalescé 250–300 ms).
public struct SessionDelta: Sendable {
    public var id: SessionID
    public var source: DeltaSource                    // .hook / .registry / .database / .transcript
    public var state: SessionState?
    public var liveness: SessionLiveness?
    public var tokens: TokenTally?                    // déjà dédupliqué par requestId à l'ingestion
    public var diff: DiffStats?
    public var appendEvents: [TimelineEvent]          // ordre chronologique
    public var counters: (files: Int, commands: Int)?
    public var lastAssistantMarkdown: String?
    public var subagents: [SubagentActivity]?
    public var metadata: SessionMetadataPatch?        // title, host, pid, accountLabel, projectPath…
    public var eventTimestamp: Date
}
```

`apply(_:)` résout le conflit de sources (REQ-SES-12) : un champ porté par `.hook` verrouille ce champ pendant `hookAuthorityWindow` (15 s) ; les deltas `.database`/`.transcript` ne l'écrasent qu'au-delà.

### 3.2 Tri et regroupement — algorithme

```
rebuildGroups():                                    # déclenché par apply(), coalescé
  visible = sessions.values où !isDismissed
  groupes = partition(visible, par: projectPath ?? "~other")
  pour chaque groupe g:
      g.rows.sort(by: rowKey)                       # rowKey(s) = (stateRank(s), -lastEventAt, -startedAt, rawID)
  groupes.sort(by: groupKey)                        # groupKey(g) = (g.contientWaiting ? 0 : 1,
                                                    #                -max(lastEventAt), nomInsensibleCasse, path)
  stateRank: waiting=0, executing=1, thinking=2, idle&live=3, ended=4

coalescence anti-sautillement (REQ-SES-05):
  si le delta change stateRank ou ajoute/retire une session → rebuild immédiat
  sinon → rebuild programmé (au plus 1 / 2 s, timer réarmable)
```

Les identités (`SessionID`, `TimelineEvent.id`) sont stables ⇒ SwiftUI anime les déplacements sans re-création de vues (diff de listes, architecture §6).

### 3.3 Avatar pixel-grid (NotchUI)

Spécification **canonique** du composant, référencée par `05-notch-ui.md` (§3.1 et REQ-NUI-52…54) — l'avatar agrégé du pill en est une instance dédiée à 10 fps max (05 REQ-NUI-54). Teinte : tokens d'état de 05 §4.5 (REQ-SES-18).

```swift
public struct PixelAvatarView: View {
    let seed: UInt64            // fnv1a(sessionID.agent.rawValue + sessionID.rawID) — motif stable
    let state: SessionState
    let paused: Bool            // panel fermé, row hors écran, ou state == idle/ended

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/20.0, paused: paused)) { ctx in
            Canvas { g, size in Self.draw(g, size, seed, state, t: ctx.date.timeIntervalSinceReferenceDate) }
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel(Text(state.accessibilityName))
    }
}
```

Dessin : grille 5 × 5, cellules 4 pt, gouttières 1 pt ; motif = bits de `seed` sur les colonnes 0–2, miroir sur 3–4 (identicon). Modulation par état :
- `executing` : opacité(x, y, t) = 0,35 + 0,65 · max(0, sin(2π(1,2 t − (x + y)/8))) — **vague diagonale** ;
- `thinking` : même vague à 0,5 Hz, amplitude 0,45 ;
- `waiting` : **rotation calme** — cellule éclairée si l'angle (centre → cellule) ∈ [θ, θ + π/3], θ = 2π · 0,15 t ;
- `idle`/`ended` : rendu statique unique (opacité 0,35 / 0,20), `paused = true` (aucun tick).

### 3.4 Résumés en langage clair — table exhaustive **[TRANCHÉ produit, textes anglais]**

| Source (Claude / Cursor) | `summary` |
|---|---|
| `Bash` / `run_terminal_command_v2` | ``Ran `<commande, 1ʳᵉ ligne, tronquée à 60>` `` |
| `Edit` / `edit_file_v2`, `afterFileEdit` | `Edited <basename> (+a/−r)` (diff si connue) |
| `Write` | `Wrote <basename>` |
| `NotebookEdit` | `Edited notebook <basename>` |
| `Read` / `read_file_v2`, `beforeReadFile` | `Read <basename>` |
| `Grep` / `ripgrep_raw_search`, `semantic_search_full` | `Searched for “<pattern, 40>”` |
| `Glob` / `glob_file_search` | `Matched files “<pattern>”` |
| `WebFetch` | `Fetched <host>` |
| `WebSearch` | `Searched the web for “<requête, 40>”` |
| `Task` / `task_v2` | `Started <agent_type> subagent` |
| `AskUserQuestion` / `ask_question` | `Asked a question` (`Asked 3 questions` si n > 1) |
| `ExitPlanMode` / `create_plan` | `Proposed a plan` |
| `TodoWrite` / `todo_write` | `Updated todos (n)` |
| `delete_file` | `Deleted <basename>` |
| `read_lints` | `Checked lints` |
| `switch_mode` | `Switched mode` |
| `mcp__<srv>__<tool>` / `mcp-<srv>-<tool>` | `Called <tool> (<srv> MCP)` |
| outil inconnu | `Used <toolName>` (tolérance aux nouveaux outils) |
| échec (`status == failed`) | suffixe ` — failed` ; interruption : ` — cancelled` |
| `userPrompt` | `Prompt: “<extrait 60>”` |
| `assistantText` | extrait texte brut 60 c. |
| `thinking` | `Thinking…` (+ ` (12s)` si durée connue) |
| `permission(granted/denied via:)` | `Permission granted (notch)` / `Permission denied (terminal)` |
| `planProposed` / `questionAsked` | `Plan: <titre>` / `Asked n question(s)` |
| `compaction` | `Context compacted (auto)` / `(manual)` |
| `sessionMarker` | `Session started` / `resumed` / `cleared` / `ended` / `killed` |

Implémentation : `enum ActivitySummarizer { static func summary(for: TimelineEventKind) -> String }` dans `DashCore`, alimenté par les tables de traduction de `AgentClaude`/`AgentCursor` (`displayName`).

### 3.5 Kill — séquence

```
[Kill] clic ─→ état .confirming(until: now+3s), libellé « Confirm? »
   │ (3 s écoulées) ─→ retour .none
   └ 2ᵉ clic ─→ Task.detached:
        kill(pid, 0) OK ? ∧ proc start_time == procStartTime ? ∧ execPath plausible (contient "claude") ?
          ├─ non → MainActor: toast "Process already exited" ; refresh liveness
          └─ oui → SIGTERM → sleep 3 s → encore vivant ? → SIGKILL
                   → MainActor: liveness=.ended(.killed), timeline += sessionMarker(killed)
```

Le `SessionEnd` éventuellement émis par l'agent mourant est idempotent (même row, déjà `.ended`).

### 3.6 Copy Session as Markdown — format exact **[TRANCHÉ produit]**

```markdown
# Claude Code session — <titre ou projectName>

**Project:** `~/Documents/medmed` · branch `main`
**Host:** iTerm (terminal) · **Model:** claude-opus-4-8 · **Account:** <label ou omis>
**Started:** 2026-07-03 18:58:05 · **Duration:** 1h 24m · **State:** idle
**Tokens:** 24.6k in / 66 out · **Diff:** +120 / −34 · **Files:** 6 · **Commands:** 12
**Session ID:** `0f8ddc9b-b55f-46fc-9709-5b4541d0999c`

## Timeline

- `18:58:05` Session started
- `18:58:12` **Prompt:** “Corrige le bug de tri…”
- `18:58:31` Ran `git status`
- `18:58:40` Edited Session.swift (+12/−3)
- `19:02:10` ⌞ Started explore subagent
- `19:04:55` Permission granted (notch)
- `19:22:03` Session resumed

## Last response

<Markdown brut de la dernière réponse assistant, non tronqué>
```

Règles : en-tête « Cursor session — … » pour Cursor (ligne Tokens remplacée par « **Context:** 72% (217.2k / 300k) ») ; champs inconnus omis (jamais de « null ») ; timeline **complète** relue depuis la source (pas la fenêtre RAM), événements sidechain préfixés « ⌞ » ; heures au format du réglage 12/24 h ; génération hors MainActor.

### 3.7 Timeline — virtualisation et backfill

```swift
public struct TimelineCursor: Sendable, Equatable {
    public var byteOffset: UInt64?      // Claude : offset de ligne dans le .jsonl (index 1/200 événements)
    public var headerIndex: Int?        // Cursor : index dans fullConversationHeadersOnly
}

public protocol TimelineBackfillProviding: Sendable {
    /// Retourne jusqu'à `limit` événements STRICTEMENT antérieurs au curseur, plus le curseur suivant (nil = début atteint).
    func olderEvents(for id: SessionID, before cursor: TimelineCursor?, limit: Int) async throws
        -> (events: [TimelineEvent], next: TimelineCursor?)
}
```

- `AgentClaude` : lors du parse initial, un **index d'offsets** (1 entrée / 200 événements, ~quelques Ko/session) est conservé par l'actor `TranscriptIngestor` ; `olderEvents` relit le segment concerné et re-résume.
- `AgentCursor` : pagination arrière de `fullConversationHeadersOnly`, puis lectures ciblées `bubbleId:<composerId>:<bubbleId>` (jamais de scan de la DB de 1 Go — **[VÉRIFIÉ]** requêtes par clé).
- Vue : `ScrollView { LazyVStack(spacing: 0) }`, sentinelle `.onAppear` sur la première row → `loadOlder()` (garde de réentrance) ; insertion en tête sans saut visuel (ancrage par `scrollPosition` sur l'id du premier événement visible). Pin bas : auto-scroll seulement si `isAtBottom`.
- Éviction : si `events.count > 2 000` après append, retrait par la tête et `olderAvailable = true` (le curseur de backfill est déjà positionné).

### 3.8 Flux de mise à jour mid-turn (séquence)

```
Claude écrit le .jsonl (entrée assistant partielle, usage cumulé)
   │ FSEvents (≈ 0,3 s)
   ▼
TranscriptIngestor (actor) : lecture incrémentale offset → parse lignes
   │ dédup requestId (remplace le tally partiel précédent du même requestId)
   │ coalescence 300 ms / session
   ▼
SessionStore.apply(SessionDelta{tokens, appendEvents, lastAssistantMarkdown})
   │ observation @Observable
   ▼
Carte : chip tokens « 24.6k / 66 » (shimmer isLive) · timeline : rows ajoutées si la session est étendue
```

---

## 4. Spécification UX/UI

### 4.1 Carte repliée (densité regular, largeur normale)

```
┌──────────────────────────────────────────────────────────────┐
│ ▦  Claude Code · Fix sort ordering            1h 24m    ⋯   │  ligne 1
│    Ran `git status`                                          │  ligne 2
│    ⬆ 24.6k / ⬇ 66 ⋅ +120 −34 ⋅ 6 files ⋅ 12 cmds ⋅ iTerm    │  ligne 3
└──────────────────────────────────────────────────────────────┘
```

- Hauteur de carte et padding : **aucune valeur en dur ici** — `DensityMetrics.rowHeight` / `.cardPadding` de la table **unique** de `05-notch-ui.md` §4.6 (REQ-NUI-37). Contrainte à répercuter lors de la calibration de cette table : le cran regular doit loger le layout **3 lignes** ci-dessus (≈ 64 pt) ; compact = **2 lignes** (métriques fusionnées sur la ligne 2) ; colossal = 3 lignes plus aérées. Coins arrondis 10 pt ; fond « puits en creux » via `agentGlass()` (document Notch UI). Les tailles citées ci-dessous (avatar 24 pt, polices 13/12/11 pt) sont celles du cran regular de cette même table.
- Ligne 1 : avatar 24 pt ; nom d'agent 13 pt semibold (graisse pilotée par `titleWeight`) ; « · » + titre de session 13 pt regular tronqué ; temps écoulé 11 pt monospaced-digit secondaire ; bouton « ⋯ » au survol.
- Ligne 2 : activité récente 12 pt, couleur secondaire, 1 ligne. Ligne 3 : chips 11 pt (`⬆/⬇` tokens, diff colorée, files/cmds, hôte, compte) ; opacité pilotée par `metricsOpacity`.
- Pastille d'état 6 pt accolée à l'avatar (couleurs REQ-SES-18) ; badge stale : glyphe horloge 10 pt ambre à droite du temps écoulé.
- Row `ended` : contenu à 55 % d'opacité, libellé d'état « Ended » (ou « Cleared » / « Killed ») à la place du temps écoulé.
- En-tête de groupe : `PROJECT NAME` 11 pt uppercase secondaire + compteur (« MEDMED · 3 ») ; sticky pendant le scroll.

### 4.2 Row étendue

```
┌──────────────────────────────────────────────────────────────┐
│ ▦  Claude Code · Fix sort ordering            1h 24m    ✕   │
│  ─────────────────────────────────────────────────────────  │
│  Last response (Markdown, 3 lignes)…                 ▸ Show more
│  ─────────────────────────────────────────────────────────  │
│  TIMELINE · 1,240 events                                     │
│    ↥ Load earlier events                                     │
│    18:58:31  Ran `git status`                                │
│    18:58:40  Edited Session.swift (+12/−3)                   │
│    19:02:10  ⌞ Started explore subagent                      │
│  SUBAGENTS (1)   explore — completed · 2m 45s                │
│  ─────────────────────────────────────────────────────────  │
│  [Kill]                    [Refresh Usage]   [⋯ menu]        │
└──────────────────────────────────────────────────────────────┘
```

- Animation d'expansion : 250 ms ease-out ; timeline hauteur max 320 pt (scroll interne) ; extrait Markdown : 3 lignes repliées, « Show more » / « Show less » 11 pt accent, déplié max 240 pt puis scroll.
- Timeline : heure 11 pt monospaced-digit secondaire, résumé 12 pt ; événements sidechain indentés 16 pt + « ⌞ » ; erreurs teintées rouge ; marqueurs de session en séparateurs centrés (« — Session resumed — »).
- Boutons : « Kill » (rouge, bordure) → « Confirm? » (plein rouge, 3 s) ; « Refresh Usage » (secondaire) ; menu ⋯ : « Copy Session as Markdown », « Refresh Usage », « Dismiss Session », « Kill Session… ».
- Textes exacts (anglais) : `Show more`, `Show less`, `Load earlier events`, `Kill`, `Confirm?`, `Refresh Usage`, `Copy Session as Markdown`, `Copied ✓`, `Dismiss Session`, `Kill Session…`, `Process already exited`, `No sessions yet`, `Sessions appear when Claude Code or Cursor is active.`, `Install hooks to see live sessions`, tooltips `Executing` / `Thinking` / `Waiting for you` / `Idle` / `Ended`.

### 4.3 Animations et mouvement

- Avatars : cf. §3.3 (20 fps max, pause hors écran/panel fermé/idle ; exception avatar agrégé du pill, 10 fps max — 05 REQ-NUI-54).
- Réordonnancement : `withAnimation(.spring(duration: 0.3))` sur le déplacement des rows ; apparition = fondu + glissement 8 pt ; disparition (GC/dismiss) = fondu 150 ms.
- Chip tokens : shimmer linéaire 1,2 s en boucle uniquement quand `tokens.isLive`.
- Aucune animation pilotée par timer quand le notch est fermé (budget CPU).

---

## 5. Cas limites & gestion d'erreurs

1. **Fichier PID orphelin** (crash de Claude) : PID mort ou `start_time` incohérent ⇒ ignoré ; s'il correspondait à une row `live`, elle passe `.ended(.crashed)`. **[HYPOTHÈSE claude-code n°4]**
2. **Deux fichiers PID, même `sessionId`** (resume ailleurs) : une seule row, `pid` le plus récent ; l'ancien host est remplacé (marqueur « resumed »).
3. **`/clear` en cours de tour** : l'ancienne row fige ses compteurs ; le tour interrompu reste dans sa timeline ; la nouvelle session démarre à zéro (nouveau `sessionId` **[VÉRIFIÉ]**).
4. **Resume multi-fichiers** (nouveau `.jsonl` au resume) : si observé, fusion vers la même row par `sessionId` ; sinon chaînage `parentUuid` **[HYPOTHÈSE claude-code n°7]** — banc d'essai avant implémentation.
5. **Session antérieure à l'installation des hooks** : détectée par transcripts/DB seuls ; état fallback ; jamais `waiting` inféré (Claude).
6. **Événement hook pour une session inconnue** : création immédiate de la row (le hook précède souvent le premier flush du transcript).
7. **Hook et transcript en désaccord** (ex. `Stop` reçu mais entrées encore streamées) : le hook a autorité 15 s ; les tokens continuent de s'accumuler (le tally n'est pas un état).
8. **`requestId` absent** (vieilles versions) : dédup de repli par `message.id` ; à défaut, l'entrée est comptée une fois (sur-comptage borné, signalé Doctor). **[TRANCHÉ produit]**
9. **Ligne JSONL géante (70 Ko observé) ou tronquée** (écriture en cours) : lecture jusqu'à `\n` complet uniquement ; ligne partielle re-tentée au tick suivant ; types inconnus ignorés sans erreur.
10. **`tool_use` jamais apparié** (tour interrompu) : `ToolCallStatus.cancelled` après le `Stop`/`stop` suivant ou la fin de session ; résumé suffixé « — cancelled ».
11. **Composer Cursor sans `workspaceIdentifier`** : groupe « Other » ; rattachement rétroactif si `workspace_roots` arrive par hook.
12. **`agent-transcripts/` absent** (tous les modes Cursor ne l'écrivent pas **[VÉRIFIÉ]**) : timeline reconstruite depuis `bubbleId:*` seul.
13. **`SQLITE_BUSY`** : retry avec backoff (50 → 400 ms) ; au-delà, données DB marquées `degraded`, dernière valeur retenue.
14. **DB Cursor de 1 Go** : jamais de scan complet ; uniquement des requêtes par clé ; le poll adaptatif retombe à 10 s sans session active.
15. **Kill : PID réutilisé** entre l'affichage et le clic : la re-validation `(pid, start_time, execPath)` échoue ⇒ aucun signal envoyé, toast « Process already exited ».
16. **Kill sur session Cursor** : impossible par construction (bouton absent, `pid` nil).
17. **Deux sessions même projet, même titre** : différenciées par heure de début (tooltip `rawID` complet).
18. **Horloge système reculée** : temps écoulé jamais négatif (`max(0, …)`) ; tri par `lastEventAt` monotone (les timestamps sources font foi).
19. **> 50 sessions en 24 h** : la liste reste scrollable ; le GC (24 h, `ended` seulement) borne la croissance ; RAM bornée par le fenêtrage timeline (2 000/session rendus).
20. **Markdown invalide dans une réponse** : repli texte brut (échec `AttributedString(markdown:)` capturé).
21. **Export Markdown pendant une session active** : instantané cohérent (lecture à offset figé) ; les événements arrivés pendant l'export n'y figurent pas.
22. **Dismiss puis nouvel événement** : row ré-affichée (REQ-SES-40) ; le dismiss n'est jamais silencieusement définitif.
23. **Avatar hors écran** : `TimelineView` en pause (vérifiable : CPU idle < 0,5 % avec 20 sessions listées, panel fermé).

---

## 6. Critères d'acceptation

1. **Given** deux sessions Claude actives dans deux projets et une session Cursor dans un troisième, **When** j'ouvre le panel, **Then** trois groupes s'affichent, chacun sous l'en-tête de son projet, ordonnés par activité la plus récente.
2. **Given** une session `idle` et une session `waiting(.permission)` dans le même groupe, **When** la liste se rafraîchit, **Then** la session `waiting` est première, orange, avatar en rotation calme, et son groupe est remonté en tête de liste.
3. **Given** une session Claude en plein tour, **When** le modèle streame sa réponse, **Then** la chip tokens (format « 24.6k / 66 ») évolue pendant le tour, sans jamais décroître au sein d'un même `requestId`, avec au plus ~3 mises à jour visuelles par seconde.
4. **Given** un `Bash` de 10 minutes en cours, **When** 120 s passent sans événement, **Then** la carte reste `executing` (verte) et affiche seulement le badge stale — jamais `waiting`.
5. **Given** une session listée, **When** je tape `/clear` dans Claude Code, **Then** l'ancienne row reste listée (« Cleared », dismissable) et une nouvelle row prend sa position visuelle.
6. **Given** une session Claude tuée en plein tour puis relancée avec `--resume`, **When** la session réapparaît, **Then** c'est la **même** row (aucun doublon), la timeline contient le tour interrompu, les compteurs de tokens n'ont pas été remis à zéro, et un marqueur « Session resumed » est présent.
7. **Given** AgentDash quitté puis relancé avec 3 sessions vivantes, **When** l'app démarre, **Then** les 3 rows réapparaissent en < 1 s, sans doublon, avec des états cohérents avec la réalité (fallback).
8. **Given** une row étendue avec 5 000 événements au total, **When** je scrolle vers le haut, **Then** « Load earlier events » charge des lots de 500, le compteur d'en-tête affiche le total réel, et le scroll reste fluide (aucun hitch perceptible, vérification Instruments).
9. **Given** une réponse assistant de 80 lignes, **When** j'étends la row, **Then** 3 lignes rendues en Markdown s'affichent avec « Show more » ; un clic déplie tout, « Show less » replie.
10. **Given** une session Claude vivante avec PID connu, **When** je clique « Kill » puis « Confirm? » sous 3 s, **Then** le process reçoit SIGTERM (puis SIGKILL si encore vivant à 3 s), la row passe « Killed » et la timeline reçoit le marqueur ; **When** je ne confirme pas, **Then** rien n'est envoyé.
11. **Given** une session quelconque, **When** je choisis « Copy Session as Markdown », **Then** le presse-papiers contient exactement le format §3.6 (en-tête, métriques, timeline complète horodatée, dernière réponse intégrale) et l'item affiche « Copied ✓ ».
12. **Given** une session `idle` dismissée, **When** un nouvel événement arrive pour elle, **Then** la row réapparaît à sa position triée.
13. **Given** une session lancée dans iTerm et une dans l'app desktop Claude, **When** je regarde les cartes, **Then** l'une affiche « iTerm » et l'autre « Desktop », suivies séparément.
14. **Given** un subagent `explore` lancé par une session Claude, **When** il travaille, **Then** aucune nouvelle session n'apparaît ; la section « Subagents » de la row parente le liste « running » puis « completed », et ses événements sont indentés « ⌞ » dans la timeline.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances entrantes** : `plan/01-architecture.md` (threading, budgets, coalescence, modules) ; `plan/02-data-model.md` (types, machine à états, dédup §1.1, cycle de vie §7) ; document Hooks & IPC (livraison des `DashEvent` et de l'enveloppe `term_program`) ; documents d'ingestion AgentClaude/AgentCursor (parseurs, tables de traduction, index d'offsets, lecteur `state.vscdb`) ; document Notch UI (conteneur, `agentGlass()`, densités, `sessionListSizing`) ; document Usage (comptes, refresh, anti-rafale) ; document Actions inline (rendu des `PendingPrompt` dans la row) ; document Notifications (stuck/task complete, consommateurs d'`isStale` et de `Stop`).

**Risques principaux** :
1. **Hypothèses de recherche non validées** : cycle de vie du registre PID (claude-code n°4), resume multi-fichiers (n°7), `conversation_id == composerId` (cursor n°1), fraîcheur d'écriture de `state.vscdb` (cursor n°5), label de compte Claude (n°5). Chacune a un banc d'essai dans `scripts/experiments/` **avant** la feature dépendante (architecture §9). Mitigation : la dédup par `SessionID` et le fail-open rendent les erreurs non destructives (au pire, une row retardée ou un champ absent).
2. **Performance timeline** : le couple LazyVStack + insertions en tête est le point fragile (préservation de l'ancre de scroll). Mitigation : prototype dédié tôt (T8), hauteurs de row quasi fixes, mesure Instruments dans la checklist de release.
3. **Règles de tri** : nos règles [TRANCHÉ produit] peuvent différer d'AgentPeek dans les détails ; elles sont centralisées dans un comparateur unique testé unitairement, donc ajustables à coût quasi nul.
4. **Tokens Cursor** : promesse volontairement réduite (contexte au lieu du tally) tant que l'hypothèse cursor n°3 n'est pas tranchée — ne pas sur-promettre dans l'UI.

---

## 8. Découpage en tâches

| # | Tâche | Contenu | Taille |
|---|---|---|---|
| T1 | `SessionStore.apply` + résolution de conflits | deltas, autorité hooks 15 s, invariants de dédup, tests unitaires (registre PID, filtres Cursor, subagents) | **L** |
| T2 | Tri & regroupement | comparateurs REQ-SES-03/04, coalescence anti-sautillement, groupe « Other », désambiguïsation, tests | **M** |
| T3 | Carte de session (repliée) | layout 3 lignes, chips, formats tokens/temps, badge stale, densités, textes | **L** |
| T4 | `PixelAvatarView` | Canvas + TimelineView, 4 modes d'animation, pause hors écran, instance pill 10 fps (composant partagé, consommé par 05), mesure CPU | **M** |
| T5 | `ActivitySummarizer` + tables de traduction | table §3.4 complète Claude + Cursor, gestion échec/cancelled, tests sur fixtures | **M** |
| T6 | Cycle de vie visible | /clear (chaînage + position), resume mid-turn, fin/GC 24 h, reconnexion au démarrage, tests d'intégration sur fixtures | **L** |
| T7 | Row étendue : extrait Markdown | rendu `AttributedString`, repli 3 lignes, Show more/less, fallback texte brut | **M** |
| T8 | Timeline virtualisée + backfill | LazyVStack, sentinelle, ancre de scroll, éviction 2 000, `TimelineBackfillProviding` Claude (index d'offsets) et Cursor (headers → bubbles), bench 5 000 événements | **XL** |
| T9 | Section subagents + todos | agrégation `SubagentActivity`, indentation sidechain, section repliable | **S** |
| T10 | Kill | machine `confirming`, re-validation, SIGTERM→SIGKILL, toasts, tests garde-fous | **M** |
| T11 | Copy Session as Markdown | template §3.6, export complet hors MainActor, pasteboard, feedback « Copied ✓ » | **M** |
| T12 | Dismiss + refresh usage + menu contextuel | règles d'éligibilité, ré-affichage sur événement, branchement poller usage | **S** |
| T13 | États vides & mode dégradé | empty state, bannière hooks, mode lecture seule | **S** |

Ordre recommandé : T1 → T2 → T5 → T3/T4 (parallèles) → T6 → T7 → T8 → T9–T13. Chemin critique MVP (P0) : T1, T2, T3, T4, T5, T6, T7, T8, T10, T13.
