# 11. Quick Routes & Fast Actions

> Rédigé le 3 juillet 2026, en conformité stricte avec `plan/01-architecture.md` (modules, threading, budgets) et `plan/02-data-model.md` (§5 : structs `QuickRoute` et `FastAction`).
> Convention : **[VÉRIFIÉ]** = adossé à AGENTPEEK_FEATURES.md, à la doc officielle ou à une inspection locale de cette machine (3 juillet 2026) ; **[HYPOTHÈSE — à valider]** = déduction à confirmer en implémentation. Aucune hypothèse n'est présentée comme un fait.

---

## 1. Objectif & périmètre

Ce document spécifie deux features « utilitaires » du panel du notch :

1. **Quick Routes** — raccourcis vers les dossiers et fichiers fréquents des agents, ouverts dans le Finder ; seuls les chemins **existants** s'affichent. Couvre AGENTPEEK_FEATURES.md **§7** (table des routes, mention « MCP servers » de la landing), **§2.2** (le panel liste les Quick Routes parmi ses sections) et **§14.8** (périmètre du clone : `~/.claude/*`, `~/.cursor/*` uniquement — Codex exclu).
2. **Fast Actions** — commandes shell sauvegardées, exécutables directement depuis le notch. Couvre AGENTPEEK_FEATURES.md **§8** et l'entrée changelog **v0.2.5** (« Fast Actions (commandes shell depuis le notch) »). La description publique d'AgentPeek se limite à une phrase : tout le reste (éditeur, environnement d'exécution, confirmation, affichage du résultat) est une conception AgentDash, marquée [HYPOTHÈSE produit] quand elle prétend imiter AgentPeek.

Hors périmètre de ce document : le conteneur du panel lui-même (NSPanel, expansion, densité — document du plan consacré au notch), la fenêtre Settings dans sa structure générale (document Settings), l'installation des hooks (document hooks/IPC) — on n'en consomme ici que les signaux (« hooks installés » ⇒ invalidation du cache d'existence des routes).

Modules concernés : **NotchUI** (sections UI, conformément à `01-architecture.md` §3.1 : « Quick Routes, Fast Actions » listés dans NotchUI), **DashCore** (catalogue, résolveur, store et runner — types partagés), **SettingsKit** (UI de gestion des Fast Actions).

---

## 2. Exigences détaillées

### Quick Routes

| ID | Priorité | Exigence (testable) |
|---|---|---|
| **REQ-QRF-01** | P0 | Le catalogue des routes est statique et contient exactement les identifiants `skills`, `plugins`, `config`, `logs`, `hooks`, `mcp`, `root` avec les chemins de la table §3.1 ci-dessous — identifiants et défauts identiques au commentaire de `02-data-model.md` §5. Aucune route Codex (`~/.codex/*`) n'apparaît. |
| **REQ-QRF-02** | P0 | Un chemin candidat n'est affiché (chip ou entrée de menu) que si `FileManager` confirme son existence [VÉRIFIÉ features §7 : « seuls les chemins existants s'affichent »]. Une route dont aucun chemin n'existe n'affiche aucun chip. |
| **REQ-QRF-03** | P0 | La résolution d'existence s'exécute **hors MainActor** (règle `01-architecture.md` §5.2 : aucun I/O disque sur MainActor), est déclenchée à chaque expansion du panel, mise en cache 30 s, et invalidée immédiatement après une installation/réparation de hooks (apparition de `~/.cursor/hooks.json`). |
| **REQ-QRF-04** | P0 | Clic sur un chemin **dossier** → ouverture d'une fenêtre Finder sur ce dossier (`NSWorkspace.shared.open`). Clic sur un chemin **fichier** (`revealsFile == true`) → révélation dans le Finder avec sélection (`NSWorkspace.shared.activateFileViewerSelecting`) — mapping du champ `revealsFile` de `02-data-model.md`. |
| **REQ-QRF-05** | P0 | Route à chemin existant unique : le clic sur le chip ouvre directement. Route à ≥ 2 chemins existants : le clic déroule un menu listant chaque chemin existant, préfixé du badge/nom d'agent (« Claude Code », « Cursor ») et du chemin abrégé (`~/…`). [HYPOTHÈSE produit — présentation AgentPeek inconnue, choix AgentDash] |
| **REQ-QRF-06** | P1 | Après une ouverture réussie, le panel du notch se replie en pill (l'intention de l'utilisateur est de passer au Finder ; le Finder devient de toute façon l'app active). [HYPOTHÈSE produit] |
| **REQ-QRF-07** | P0 | Si aucune route n'a de chemin existant (ni `~/.claude` ni `~/.cursor`), la section « Quick Routes » entière est masquée — pas d'état vide affiché. |
| **REQ-QRF-08** | P1 | L'existence est re-vérifiée au moment du clic ; si le chemin a disparu entre la résolution et le clic, aucune boîte de dialogue : le chip disparaît à la re-résolution immédiate et un log `.info` est émis. |
| **REQ-QRF-09** | P1 | Le tilde est résolu via `FileManager.default.homeDirectoryForCurrentUser` (pas de sandbox → vrai home, VÉRIFIÉ `01-architecture.md` §2). Les symlinks sont suivis pour le test d'existence, mais c'est le chemin catalogue (non résolu) qui est ouvert/révélé. |
| **REQ-QRF-10** | P1 | Layout de la section : titre « Quick Routes », chips en flow layout multi-lignes, dimensions et espacements de §4.1 ; hauteur des chips modulée par le réglage `density` (compact/regular/colossal). |
| **REQ-QRF-11** | P2 | Chemins candidats additionnels (extensions AgentDash, désactivables par constantes) : `~/.cursor/plugins` (route `plugins`), `~/.cursor/skills-cursor` (route `skills`), `~/.claude.json` (route `mcp`). Chacun suit la même règle d'existence. Voir §3.1 pour le statut vérifié/hypothèse de chacun. |
| **REQ-QRF-12** | P2 | Chaque chip expose un tooltip (`help`) avec le ou les chemins complets, et un label d'accessibilité « Open <title> in Finder ». |
| **REQ-QRF-13** | P0 | Aucune erreur des Quick Routes n'est bloquante : jamais de `NSAlert`, jamais d'exception propagée à l'UI ; échec = log `.info` catégorie `ui` sans contenu utilisateur. |

### Fast Actions

| ID | Priorité | Exigence (testable) |
|---|---|---|
| **REQ-QRF-14** | P0 | CRUD complet : créer, éditer, supprimer une `FastAction` (`id: UUID`, `title`, `command`, `workingDirectory?`, `lastRunAt?`, `lastExitCode?` — struct exacte de `02-data-model.md` §5). La suppression demande confirmation. |
| **REQ-QRF-15** | P0 | Persistance dans **UserDefaults** (`02-data-model.md` §8) : tableau encodé JSON sous la clé `fastActions.v1`, ordre du tableau = ordre d'affichage, écriture débouncée 500 ms comme `AppSettings`. Un blob illisible ⇒ liste vide + log `.error` (jamais de crash), l'ancien blob est conservé sous `fastActions.v1.corrupt` pour diagnostic. |
| **REQ-QRF-16** | P0 | Exécution via `/bin/zsh -lc <command>` (décision `02-data-model.md` : shell login → `PATH` utilisateur chargé depuis `~/.zprofile`/`~/.zshrc`), `stdin = /dev/null`, cwd = `workingDirectory` (tilde résolu) sinon home, environnement hérité de l'app complété de `TERM=dumb`, `NO_COLOR=1`, `CLICOLOR=0`. |
| **REQ-QRF-17** | P0 | **Anti-clic accidentel** : le premier clic sur « Run » **arme** le bouton (état « Run? », teinte accent) pendant 3 s ; seul un second clic dans cette fenêtre exécute ; sinon retour à l'état normal. Échap, clic ailleurs ou repli du panel désarment. Aucune Fast Action n'est jamais déclenchée par survol, raccourci global par défaut, ni automatiquement (lancement d'app, timer, événement d'agent). |
| **REQ-QRF-18** | P0 | Pendant l'exécution : spinner + bouton « Stop » sur la row ; le résultat affiche le code de sortie, la durée, et la **fin** de la sortie (tail de 8 Ko / 200 lignes max rendues), stdout et stderr fusionnés, dans un bloc monospace repliable directement dans le notch. |
| **REQ-QRF-19** | P0 | Le pipe de sortie est drainé **en continu** (jamais de blocage du process enfant sur un pipe plein), la sortie est décodée UTF-8 en mode tolérant (octets invalides remplacés), les séquences d'échappement ANSI sont retirées avant affichage, et les mises à jour UI sont coalescées à 250 ms (budget `01-architecture.md` §5.2). |
| **REQ-QRF-20** | P0 | Gestion d'erreurs : échec de spawn (message « Failed to launch shell »), `workingDirectory` inexistant (échec **avant** spawn, « Working directory not found »), terminaison par signal (« Terminated (signal N) »), exit ≠ 0 (badge rouge « exit N »). Chaque cas laisse la row dans un état final consultable, jamais de dialogue modal. |
| **REQ-QRF-21** | P0 | « Stop » envoie SIGTERM au process, puis SIGKILL après 3 s s'il vit encore (même séquence que le kill de serveurs, `01-architecture.md` §5.1). À la fermeture d'AgentDash, tous les runs actifs reçoivent la même séquence (best effort). |
| **REQ-QRF-22** | P1 | Au plus **1 run simultané par action** (bouton Run masqué pendant le run de cette action) et au plus **3 runs simultanés** toutes actions confondues (au-delà : boutons Run désactivés avec tooltip « Too many running actions »). |
| **REQ-QRF-23** | P0 | UI de gestion dans **Settings → General**, groupe « Fast Actions » : liste (titre + commande tronquée), boutons `+` / `−` / « Edit », réordonnancement par glisser-déposer, éditeur en sheet (champs §4.4). [HYPOTHÈSE produit — emplacement dans Settings non documenté par AgentPeek] |
| **REQ-QRF-24** | P1 | `lastRunAt` et `lastExitCode` sont mis à jour à chaque fin de run, persistés, et affichés sur la row du notch (badge ✓ vert / « exit N » rouge + horodatage relatif « 2m ago »). |
| **REQ-QRF-25** | P1 | Un run continue si le panel se replie ; à la réouverture, la row reflète l'état courant (spinner ou résultat). Aucune notification système n'est émise pour les Fast Actions. |
| **REQ-QRF-26** | P1 | Logging : uniquement `action.id`, code de sortie, durée, taille de sortie — **jamais** le texte de la commande ni la sortie (promesse privacy, `01-architecture.md` §7.3). |
| **REQ-QRF-27** | P1 | Bouton « Copy output » sur le bloc de résultat (presse-papiers, sortie complète retenue — dans la limite du tail conservé) ; menu contextuel de row : « Copy command ». |
| **REQ-QRF-28** | P1 | État vide de la section notch : texte « No fast actions yet » + bouton « Open Settings » ouvrant Settings → General. La section reste visible (contrairement aux Quick Routes) pour rendre la feature découvrable. [HYPOTHÈSE produit] |
| **REQ-QRF-29** | P2 | Validation à l'édition : « Save » désactivé si `title` ou `command` est vide/blanc ; plafond doux de 50 actions (le bouton `+` se désactive avec tooltip). |
| **REQ-QRF-30** | — | Supprimé (décision one-shot du 3 juillet 2026). |

---

## 3. Conception technique

### 3.1 Table des Quick Routes (adaptée au scope Claude Code + Cursor)

Référence AgentPeek (features §7) transposée sans Codex ; existence vérifiée sur cette machine le 3 juillet 2026 :

| `id` | `title` (UI) | Chemins candidats (ordre d'affichage) | `revealsFile` | Statut |
|---|---|---|---|---|
| `skills` | Skills | `~/.claude/skills` | non | [VÉRIFIÉ : parité AgentPeek ; dossier présent localement] |
| | | `~/.cursor/skills-cursor` *(extension P2, REQ-QRF-11)* | non | [VÉRIFIÉ : dossier présent localement ; HYPOTHÈSE — à valider : sémantique « skills Cursor » du dossier] |
| `plugins` | Plugins | `~/.claude/plugins` | non | [VÉRIFIÉ : parité AgentPeek ; présent localement] |
| | | `~/.cursor/plugins` *(extension P2)* | non | [VÉRIFIÉ : présent localement ; absent de la table AgentPeek] |
| `config` | Config | `~/.claude/settings.json` | **oui** | [VÉRIFIÉ : parité AgentPeek ; fichier présent] |
| `logs` | Logs | `~/.claude/projects` | non | [VÉRIFIÉ : parité AgentPeek ; présent] |
| | | `~/.cursor/projects` | non | Adaptation du scope (équivalent Cursor de `~/.codex/sessions` chez AgentPeek : transcripts agent) [VÉRIFIÉ : dossier présent localement, contient les projets/agent-transcripts] |
| `hooks` | Hooks | `~/.cursor/hooks.json` | **oui** | [VÉRIFIÉ : parité AgentPeek ; **absent** sur cette machine tant que l'installateur AgentDash n'a pas tourné → le chip n'apparaît qu'après installation, conforme REQ-QRF-02] |
| `mcp` | MCP | `~/.cursor/mcp.json` | **oui** | [VÉRIFIÉ : fichier présent localement, clé `mcpServers` confirmée ; la landing AgentPeek mentionne « Jump to … MCP servers »] |
| | | `~/.claude.json` *(extension P2)* | **oui** | [VÉRIFIÉ : fichier présent localement ; HYPOTHÈSE — à valider : c'est bien là que `claude mcp add --scope user` écrit `mcpServers` (clé absente sur cette machine faute de serveur user-scope)] |
| `root` | Root | `~/.claude` puis `~/.cursor` | non | [VÉRIFIÉ : parité AgentPeek ; les deux présents] |

Notes : les hooks Claude Code vivent dans `~/.claude/settings.json`, déjà couvert par `config` — pas de doublon dans `hooks`. Les chemins sont stockés **avec** tilde dans le catalogue (lisibilité des menus) et résolus à l'exécution.

### 3.2 API — Quick Routes (DashCore + NotchUI)

```swift
// DashCore/Sources/QuickRoutes/QuickRoutesCatalog.swift
public enum QuickRoutesCatalog {
    /// Table §3.1 figée à la compilation. Les extensions P2 sont derrière ce drapeau.
    public static let includeExtendedPaths = true   // REQ-QRF-11
    public static var all: [QuickRoute] { … }        // 7 routes, ids/défauts de 02-data-model.md §5
}

/// Résultat de la résolution : uniquement ce qui existe.
public struct ResolvedQuickRoute: Identifiable, Sendable {
    public var id: String                 // même id que QuickRoute
    public var title: String
    public var revealsFile: Bool
    public var existingPaths: [QuickRoutePath]   // non vide par construction
}
public struct QuickRoutePath: Identifiable, Sendable {
    public var id: String { tildePath }
    public var tildePath: String          // "~/.claude/skills" (affichage menu)
    public var absoluteURL: URL           // résolu via homeDirectoryForCurrentUser
    public var agent: AgentKind           // badge du menu (déduit du préfixe ~/.claude / ~/.cursor)
}

/// Résolution hors MainActor (REQ-QRF-03). Sans état : une struct suffit, pas d'actor.
public struct QuickRoutesResolver: Sendable {
    public init(fileManager: FileManager = .default)
    /// stat() de ~12 chemins, ~quelques µs ; appelé dans une Task.detached(priority: .userInitiated).
    public func resolve(catalog: [QuickRoute] = QuickRoutesCatalog.all) -> [ResolvedQuickRoute]
}

// NotchUI/Sources/QuickRoutes/QuickRoutesSection.swift
@MainActor
struct QuickRoutesSectionModel {
    private(set) var routes: [ResolvedQuickRoute] = []
    private var resolvedAt: Date? = nil            // cache TTL 30 s
    mutating func refreshIfStale(force: Bool = false) // Task.detached → resolve → maj sur MainActor
}

// Ouverture (MainActor : NSWorkspace est une API AppKit)
@MainActor
enum QuickRouteOpener {
    /// Re-vérifie l'existence (REQ-QRF-08), puis :
    ///  - revealsFile == true  → NSWorkspace.shared.activateFileViewerSelecting([url])
    ///  - revealsFile == false → NSWorkspace.shared.open(url)   // fenêtre Finder sur le dossier
    /// Retourne false si le chemin a disparu (le caller force un refresh).
    @discardableResult
    static func open(_ path: QuickRoutePath, revealsFile: Bool) -> Bool
}
```

Déclencheurs de `refreshIfStale(force: true)` : expansion du panel ; notification interne `hooksDidChange` émise par l'installateur de hooks (le fichier `~/.cursor/hooks.json` vient d'être créé/retiré) ; bouton « réparer » du Doctor.

### 3.3 API — Fast Actions (DashCore + NotchUI + SettingsKit)

```swift
// DashCore/Sources/FastActions/FastActionStore.swift
@MainActor @Observable
public final class FastActionStore {
    public private(set) var actions: [FastAction] = []          // ordre = ordre UI
    public private(set) var runs: [UUID: FastActionRun] = [:]   // clé = FastAction.id (≤ 1 run/action)

    public init(defaults: UserDefaults = .standard)             // charge fastActions.v1 (REQ-QRF-15)

    // CRUD (REQ-QRF-14) — chaque mutation déclenche la persistance débouncée 500 ms
    public func add(_ action: FastAction)
    public func update(_ action: FastAction)
    public func delete(id: UUID)                                // stoppe le run éventuel avant retrait
    public func move(fromOffsets: IndexSet, toOffset: Int)

    // Exécution
    public var canStartNewRun: Bool { runs.values.filter(\.phase.isRunning).count < 3 }  // REQ-QRF-22
    public func run(id: UUID)          // délègue à FastActionRunner, s'abonne au stream
    public func stop(id: UUID)
    public func stopAllForAppTermination()                      // REQ-QRF-21, appelé par l'AppDelegate
}

public struct FastActionRun: Identifiable, Sendable {
    public var id: UUID                       // == actionID (1 run max par action)
    public var startedAt: Date
    public var phase: RunPhase
    public var outputTail: String             // ≤ 8 Ko, ANSI retiré, UTF-8 lossy (REQ-QRF-19)
    public var outputTruncated: Bool
    public var durationMs: Int?
}
public enum RunPhase: Equatable, Sendable {
    case running
    case finished(exitCode: Int32)            // 0 = succès
    case signaled(Int32)                      // terminationReason == .uncaughtSignal
    case failed(FastActionError)              // spawn / cwd
    case stopped                              // Stop utilisateur
    var isRunning: Bool { self == .running }
}
public enum FastActionError: Error, Equatable, Sendable {
    case workingDirectoryMissing(String)
    case spawnFailed(errno: Int32)
}

// DashCore/Sources/FastActions/FastActionRunner.swift
/// Actor dédié : Process, pipes et buffers ne touchent jamais MainActor (01-architecture.md §5).
public actor FastActionRunner {
    public struct Update: Sendable { public var phase: RunPhase; public var tail: String; public var truncated: Bool }
    /// Démarre le process et publie des Updates coalescées (≥ 250 ms entre deux émissions,
    /// sauf l'update finale). Le stream se termine avec la phase finale.
    public func run(_ action: FastAction) -> AsyncStream<Update>
    public func stop(actionID: UUID)          // SIGTERM → 3 s → SIGKILL
}
```

### 3.4 Algorithme d'exécution (runner)

```
run(action):
 1. cwd ← expandTilde(action.workingDirectory ?? "~")
    si !isDirectory(cwd) → yield .failed(.workingDirectoryMissing) ; fin.        (REQ-QRF-20)
 2. Process:
      executableURL = /bin/zsh ; arguments = ["-l", "-c", action.command]        (REQ-QRF-16)
      currentDirectoryURL = cwd ; standardInput = FileHandle.nullDevice
      environment = env(app) + [TERM: dumb, NO_COLOR: 1, CLICOLOR: 0]
      standardOutput = standardError = pipe            // fusion stdout+stderr   (REQ-QRF-18)
 3. try process.run()  — catch → yield .failed(.spawnFailed) ; fin.
 4. Boucle de drainage (readabilityHandler sur queue dédiée) :
      chunk → décodage UTF-8 lossy → strip ANSI (regex CSI/OSC) → ring buffer 8 Ko
      → si (now − lastEmit ≥ 250 ms) yield .running + tail                       (REQ-QRF-19)
 5. terminationHandler :
      .exit(code)          → phase = .finished(code)
      .uncaughtSignal(sig) → phase = stopRequested ? .stopped : .signaled(sig)
      yield final (tail complet, durationMs) ; finish stream.
 6. stop(actionID) : process.terminate() /*SIGTERM*/ ; après 3 s si isRunning → kill(pid, SIGKILL).
```

Le strip ANSI utilise une passe unique sur `\u{1B}\[[0-9;?]*[ -/]*[@-~]` et `\u{1B}\][^\u{07}]*(\u{07}|\u{1B}\\)` [HYPOTHÈSE — à valider : couverture suffisante des séquences réelles ; sinon bibliothèque de 30 lignes maison à durcir sur fixtures].

Limite assumée : SIGTERM vise le process `zsh` ; des petits-enfants détachés peuvent survivre (pas de `killpg`, cohérent avec la règle sécurité `01-architecture.md` §8.4 qui l'interdit). Documenté dans l'UI par le libellé « Stop » (pas « Kill all »).

### 3.5 Séquence complète (armement → exécution → résultat)

```
Utilisateur              NotchUI (MainActor)          FastActionStore        FastActionRunner (actor)
    │ clic « Run »              │                            │                        │
    ├──────────────────────────►│ arme le bouton (3 s)       │                        │
    │ clic « Run? » (< 3 s)     │                            │                        │
    ├──────────────────────────►│ store.run(id) ────────────►│ runs[id] = .running    │
    │                           │                            │ for await u in ───────►│ spawn /bin/zsh -lc
    │                           │  spinner + Stop            │   runner.run(action)   │ drainage pipe,
    │                           │◄── observation @Observable ◄─ maj runs[id] ◄────────┤ coalescence 250 ms
    │ (optionnel) clic « Stop » │                            │                        │
    ├──────────────────────────►│ store.stop(id) ───────────►│ ───────────────────────► SIGTERM → 3 s → SIGKILL
    │                           │                            │ phase finale, tail     │
    │  badge ✓ / « exit N »     │◄───────────────────────────┤ lastRunAt/lastExitCode │
    │  + bloc sortie repliable  │                            │ → UserDefaults (500 ms)│
```

### 3.6 Persistance (REQ-QRF-15, REQ-QRF-24)

- Clé `fastActions.v1` : `Data` JSON d'un `[FastAction]` (struct `Codable` de `02-data-model.md`). Le suffixe `.v1` porte la version de schéma ; une migration future lit `v1` et écrit `v2`.
- Écriture : débounce 500 ms partagé avec `AppSettings` (même mécanique, `01-architecture.md`/`02-data-model.md` §8).
- Décodage en échec → `actions = []`, blob déplacé vers `fastActions.v1.corrupt`, log `.error` (catégorie `ui`), signal Doctor `degraded("fast actions store")` [HYPOTHÈSE produit — check Doctor optionnel].
- Rien d'autre n'est persisté : les `FastActionRun` (sorties comprises) sont mémoire uniquement.

---

## 4. Spécification UX/UI

Tous les textes d'interface en anglais, comme AgentPeek. Dimensions données pour la densité `regular` ; `compact` × 0,85 et `colossal` × 1,3 sur les hauteurs de rows et tailles de police (arrondies au point).

### 4.1 Section « Quick Routes » (panel du notch)

- **Position** : zone basse du panel, au-dessus de « Fast Actions » (ordre exact des sections arbitré par le document notch).
- **Header** : label `QUICK ROUTES` (uppercase, 11 pt, semibold, opacité 0,55 — modulée par `metricsOpacity`), padding horizontal 16 pt, margin-top 12 pt.
- **Chips** : flow layout multi-lignes ; chip = icône SF Symbol + label 12 pt medium ; hauteur 26 pt, padding horizontal interne 10 pt, coins arrondis en capsule, espacement inter-chips 8 pt (horizontal et vertical), fond `agentGlass()` relevé (depth-lit : carte en léger relief).
- **Icônes** [HYPOTHÈSE produit — choix AgentDash] : Skills `graduationcap`, Plugins `puzzlepiece.extension`, Config `gearshape`, Logs `doc.text.magnifyingglass`, Hooks `link`, MCP `server.rack`, Root `folder`.
- **Interactions** : survol = élévation légère + opacité 1,0 (150 ms ease-out) ; clic chemin unique = ouverture immédiate ; clic multi-chemins = menu (`NSMenu`) avec entrées « Claude Code — ~/.claude/skills » / « Cursor — ~/.cursor/skills-cursor » ; après ouverture, repli du panel (REQ-QRF-06).
- **États** : chip jamais désactivé (un chip affiché est cliquable par définition) ; section masquée si vide (REQ-QRF-07).

### 4.2 Section « Fast Actions » (panel du notch)

- **Header** : label `FAST ACTIONS` (même style que Quick Routes) + compteur discret (« 3 ») à droite.
- **Row** (hauteur 34 pt) : icône `terminal` 14 pt · `title` 13 pt medium (troncature milieu) · zone droite contextuelle :
  - repos : badge dernier résultat s'il existe (`✓` vert ou `exit 2` rouge, 11 pt) + horodatage relatif (« 2m ago », opacité 0,5) + bouton `Run` (capsule 24 pt) ;
  - armé : le bouton devient `Run?` teinté accent, pulsation subtile d'opacité (0,8 ↔ 1,0, 600 ms), 3 s max ;
  - en cours : spinner 14 pt + durée qui s'incrémente (« 12s ») + bouton `Stop` (capsule rouge) ;
  - terminé : badge résultat + chevron pour déplier la sortie.
- **Bloc sortie** (déplié) : fond en creux (puits depth-lit), monospace 11 pt, hauteur max 160 pt avec scroll interne, coins 8 pt, padding 10 pt ; en-tête du bloc : `exit 0 · 3.2s` à gauche, bouton `Copy output` à droite ; si tronqué, première ligne grisée `… output truncated (showing last 8 KB)`.
- **Menu contextuel de row** : `Run`, `Copy command`, `Edit in Settings…`, `Delete…`.
- **État vide** : icône `bolt` 20 pt, texte « No fast actions yet » (13 pt), sous-texte « Save shell commands and run them from the notch. » (11 pt, opacité 0,6), bouton « Open Settings ».
- **Animations** : transitions d'état du bouton en 180 ms ease-in-out ; apparition du bloc sortie en dépliage 220 ms.

### 4.3 Settings → General → groupe « Fast Actions »

- Groupe titré « Fast Actions », sous les toggles de hooks [HYPOTHÈSE produit].
- **Liste** (style `Table` macOS, hauteur ~140 pt) : colonne « Title », colonne « Command » (monospace, troncature queue) ; réordonnancement par drag ; double-clic = éditer.
- **Barre d'outils** sous la liste : boutons `+` (nouvelle action), `−` (supprimer la sélection, avec confirmation), `Edit`.
- **Note de bas de groupe** (11 pt, secondaire) : « Commands run as your user via /bin/zsh from the notch. Output stays on this Mac. »

### 4.4 Éditeur (sheet)

- Titre : « New Fast Action » / « Edit Fast Action ».
- Champs :
  - `Title` — TextField, placeholder « Restart dev server » ;
  - `Command` — TextEditor monospace 3–6 lignes, placeholder « pnpm dev --port 3000 » ;
  - `Working directory (optional)` — TextField chemin + bouton `Choose…` (NSOpenPanel dossiers uniquement) ; vide = home.
- Pied : note « Runs with /bin/zsh -lc. Interactive commands (sudo, editors) are not supported. » ; boutons `Cancel` / `Save` (Save désactivé si titre ou commande vide — REQ-QRF-29).
- Confirmation de suppression : alerte « Delete “<title>”? » / « This cannot be undone. » / boutons `Delete` (destructif) et `Cancel`.

---

## 5. Cas limites & gestion d'erreurs

### Quick Routes

1. **`~/.cursor/hooks.json` absent** (état actuel de cette machine, VÉRIFIÉ) : le chip « Hooks » n'apparaît pas ; il apparaît sans redémarrage après l'installation des hooks (invalidation `hooksDidChange`, REQ-QRF-03).
2. **Chemin supprimé entre résolution et clic** : re-check au clic, échec silencieux, refresh forcé, log `.info` (REQ-QRF-08).
3. **Symlink** : existence testée sur la cible ; révélation sur le chemin catalogue (REQ-QRF-09). Symlink cassé = inexistant.
4. **Chemin présent mais illisible** (permissions) : le chip s'affiche (l'existence suffit) ; le Finder gère l'accès — aucune erreur AgentDash.
5. **Ni `~/.claude` ni `~/.cursor`** : section entièrement masquée (REQ-QRF-07) ; cohérent avec le mode dégradé « agent non détecté » (`01-architecture.md` §7.2 : Quick Routes filtrées par existence).
6. **Panel non-activant** : `activateFileViewerSelecting`/`open` activent le Finder — le repli volontaire du panel (REQ-QRF-06) évite un panel orphelin au-dessus du Finder.
7. **Home non standard** (`homeDirectoryForCurrentUser` ≠ `/Users/<login>`) : géré par construction, aucun chemin en dur avec `/Users/`.
8. **Cache TTL** : deux expansions à moins de 30 s ne relancent pas les `stat()` (économie inutile mais règle simple) ; le refresh forcé couvre les cas où la fraîcheur importe.

### Fast Actions

9. **Blob UserDefaults corrompu** : liste vide, blob préservé en `.corrupt`, log `.error` — jamais de crash (REQ-QRF-15).
10. **`workingDirectory` supprimé depuis la création** : échec avant spawn avec message dédié (REQ-QRF-20) ; l'action reste éditable.
11. **Commande introuvable** : zsh retourne exit 127 avec « command not found » dans la sortie — affiché tel quel, badge « exit 127 ».
12. **Commande interactive** (sudo, vim, read) : stdin `/dev/null` ⇒ échec immédiat de l'outil, capturé dans la sortie ; limitation documentée dans l'éditeur (§4.4).
13. **Sortie massive** (`yes`, build verbeux) : drainage continu obligatoire (sinon l'enfant bloque sur pipe plein), ring buffer 8 Ko, flag `outputTruncated` (REQ-QRF-19).
14. **Sortie binaire / UTF-8 invalide** : décodage lossy (U+FFFD), jamais d'exception.
15. **Séquences ANSI / titres OSC** : retirés avant affichage ; en cas de séquence non couverte, elle apparaît en clair (dégradation cosmétique, non bloquante).
16. **Commande sans fin** (serveur lancé en Fast Action) : pas d'auto-kill ; spinner + « Stop » indéfiniment ; le process apparaîtra aussi dans la section serveurs si un port 3000–9999 est ouvert (comportement assumé, non dédupliqué).
17. **Descendants détachés après Stop** : SIGTERM/SIGKILL sur `zsh` seulement (pas de `killpg`, §3.4) — des orphelins peuvent survivre ; assumé et documenté.
18. **Quit de l'app pendant un run** : `stopAllForAppTermination()` en best effort ; si SIGKILL n'a pas le temps de partir, l'enfant est re-parenté (assumé).
19. **Suppression d'une action en cours d'exécution** : stop d'abord, retrait ensuite (REQ-QRF-14).
20. **Édition d'une action en cours d'exécution** : autorisée ; le run en cours conserve l'ancienne commande, le prochain run utilise la nouvelle.
21. **Armement puis repli du panel** : désarmement systématique (REQ-QRF-17) — jamais d'exécution différée invisible.
22. **> 3 runs simultanés** : boutons Run désactivés + tooltip (REQ-QRF-22) — protège les budgets CPU/RAM.
23. *Supprimé (décision one-shot du 3 juillet 2026)* — plus de trial ni de panel verrouillé ; REQ-QRF-30 supprimé.
24. **`~/.zprofile` lent** (nvm, brew shellenv…) : latence de spawn possible de plusieurs centaines de ms — le spinner apparaît dès le clic, aucune bascule de thread UI.
25. **Deux actions au titre identique** : autorisé (l'`UUID` désambiguïse) ; aucune contrainte d'unicité.
26. **Échec d'écriture UserDefaults** : improbable ; le débounce réessaie à la mutation suivante ; aucune perte au-delà de la dernière édition.

---

## 6. Critères d'acceptation

1. **Given** `~/.claude/skills` existe et `~/.cursor/hooks.json` n'existe pas, **When** j'ouvre le panel du notch, **Then** la section Quick Routes affiche « Skills » et n'affiche pas « Hooks ».
2. **Given** le panel est ouvert et les hooks Cursor viennent d'être installés depuis Settings, **When** je regarde la section Quick Routes sans redémarrer, **Then** le chip « Hooks » est apparu.
3. **Given** le chip « Config » (fichier), **When** je clique dessus, **Then** une fenêtre Finder s'ouvre sur `~/.claude` avec `settings.json` **sélectionné**, et le panel se replie en pill.
4. **Given** le chip « Root » avec `~/.claude` et `~/.cursor` existants, **When** je clique dessus, **Then** un menu propose « Claude Code — ~/.claude » et « Cursor — ~/.cursor », et le choix d'une entrée ouvre le bon dossier dans le Finder.
5. **Given** `~/.claude` et `~/.cursor` sont tous deux absents (machine vierge), **When** j'ouvre le panel, **Then** aucune section « Quick Routes » n'est visible.
6. **Given** aucune Fast Action enregistrée, **When** j'ouvre le panel, **Then** la section Fast Actions affiche « No fast actions yet » et le bouton « Open Settings » ouvre Settings → General sur le groupe Fast Actions.
7. **Given** l'éditeur de Fast Action ouvert avec un titre saisi mais une commande vide, **When** je regarde le bouton Save, **Then** il est désactivé ; **When** je saisis `echo hello`, **Then** il s'active et Save ajoute la row dans la liste et dans le notch.
8. **Given** une Fast Action « Echo » (`echo hello`), **When** je clique une seule fois sur « Run » puis j'attends 4 s, **Then** rien ne s'exécute et le bouton est revenu à l'état normal.
9. **Given** la même action, **When** je clique « Run » puis « Run? » dans les 3 s, **Then** la commande s'exécute, un spinner apparaît, puis un badge `✓` et le bloc sortie déplié montre `hello` avec `exit 0` et la durée.
10. **Given** une action `exit 3`, **When** je l'exécute, **Then** la row affiche un badge rouge « exit 3 » et `lastExitCode == 3` persiste après redémarrage d'AgentDash (badge « exit 3 » + horodatage relatif au relancement).
11. **Given** une action `sleep 60`, **When** je clique « Stop » après 2 s, **Then** le run se termine en état « Stopped » en moins de 4 s (SIGTERM, puis SIGKILL au besoin) et le bouton « Run » redevient disponible.
12. **Given** une action `yes | head -c 10000000`, **When** je l'exécute, **Then** l'app ne gèle pas, la sortie affichée est plafonnée avec la mention « output truncated » et la RAM de l'app n'augmente pas de plus de quelques Mo (tail 8 Ko).
13. **Given** une action avec `workingDirectory = ~/toto-inexistant`, **When** je l'exécute, **Then** l'échec « Working directory not found » s'affiche sans spawn et sans dialogue modal.
14. **Given** une action dont la commande émet des couleurs ANSI (`ls -G` ou `printf '\e[31mred\e[0m'`), **When** je consulte la sortie, **Then** aucun caractère d'échappement n'est visible.
15. **Given** trois actions en cours d'exécution, **When** je tente d'en lancer une quatrième, **Then** le bouton Run est désactivé avec le tooltip « Too many running actions ».
16. **Given** un run en cours, **When** je replie le panel puis le rouvre 10 s plus tard, **Then** la row montre toujours le spinner (ou le résultat si terminé) — le run n'a pas été interrompu.
17. **Given** le fichier de log `agentdash.log` après plusieurs runs, **When** je l'inspecte, **Then** ni le texte des commandes ni leur sortie n'y figurent (uniquement id, exit code, durée, taille).

---

## 7. Dépendances (autres fichiers du plan) et risques

### Dépendances

| Document | Ce qu'on en consomme |
|---|---|
| `plan/01-architecture.md` | modules (NotchUI/DashCore/SettingsKit), règles de threading (aucun I/O sur MainActor, coalescence 250 ms), budgets RAM/CPU, règles kill (SIGTERM→SIGKILL, pas de `killpg`), logging sans contenu utilisateur |
| `plan/02-data-model.md` | structs `QuickRoute` et `FastAction` (§5), persistance UserDefaults (§8), `Density`/`metricsOpacity` (AppSettings) |
| Document notch UI (numérotation à confirmer) | conteneur du panel, ordre des sections, `agentGlass()`, depth-lit, repli/expansion, gestion densité |
| Document hooks/installation (numérotation à confirmer) | signal `hooksDidChange` (création de `~/.cursor/hooks.json`) pour invalider le cache d'existence |
| Document Settings (numérotation à confirmer) | structure de l'onglet General qui héberge le groupe « Fast Actions » |
| Document serveurs dev (numérotation à confirmer) | chevauchement possible : un serveur lancé via Fast Action apparaît aussi dans la section serveurs (assumé, cas limite n°16) |

### Risques

1. **Présentation multi-chemins inconnue chez AgentPeek** (menu vs chips séparés) — risque faible, purement cosmétique ; notre choix (menu) est réversible sans toucher au modèle.
2. **`~/.claude.json` comme emplacement MCP user-scope** [HYPOTHÈSE] : si l'emplacement documenté diffère (CLI `claude mcp` évoluant), la route `mcp` pointe au mauvais endroit — mitigé par le drapeau `includeExtendedPaths` et la règle d'existence (au pire, un chip de plus qui ouvre un fichier réel).
3. **Strip ANSI incomplet** : dégradation cosmétique seulement ; banc de fixtures prévu (tâche T7).
4. **Orphelins après Stop** (descendants de zsh) : assumé ; si les retours utilisateurs l'exigent, réévaluer un groupe de processus dédié au spawn (dérogation localisée à la règle « pas de killpg », à documenter en révision d'architecture).
5. **Emplacement Settings du groupe Fast Actions** [HYPOTHÈSE produit] : AgentPeek n'a pas d'onglet documenté ; si un onglet dédié s'avère plus juste, le déplacement est trivial (SettingsKit).
6. **Sécurité perçue** : exécuter du shell depuis une surface toujours visible peut inquiéter — mitigé par : geste explicite en 2 temps, aucune exécution automatique, note explicite dans Settings, zéro persistance des sorties.

---

## 8. Découpage en tâches

| # | Tâche | Contenu | Taille |
|---|---|---|---|
| T1 | `QuickRoutesCatalog` + `QuickRoutesResolver` (DashCore) | table §3.1, résolution d'existence, tests unitaires sur système de fichiers temporaire (routes présentes/absentes/symlinks) | **S** |
| T2 | `QuickRoutesSection` (NotchUI) | chips flow layout, menu multi-chemins, `QuickRouteOpener`, cache TTL + invalidation `hooksDidChange`, repli du panel | **M** |
| T3 | `FastActionStore` (DashCore) | CRUD, ordre, persistance `fastActions.v1` débouncée, récupération blob corrompu, tests unitaires (encode/decode/migration/corruption) | **M** |
| T4 | `FastActionRunner` (DashCore) | actor Process/pipes, drainage continu, ring buffer 8 Ko, strip ANSI, coalescence 250 ms, SIGTERM→SIGKILL, tests d'intégration (echo, exit N, sleep+stop, sortie massive, cwd manquant, signal) | **L** |
| T5 | Section Fast Actions (NotchUI) | rows, armement 2 temps + désarmement, spinner/Stop, bloc sortie repliable, Copy output/command, état vide, badges persistés | **L** |
| T6 | Groupe Settings → General (SettingsKit) | table + drag reorder, éditeur sheet, NSOpenPanel, confirmations, validations | **M** |
| T7 | Banc de fixtures ANSI + sorties réelles | corpus de sorties (npm, cargo, pytest, séquences OSC) pour durcir le strip et le tail | **S** |
| T8 | Intégration & critères d'acceptation | câblage composition root (store injecté, `stopAllForAppTermination`), passage manuel des 17 scénarios §6, vérification budgets (RAM stable sur sortie massive, zéro contenu dans les logs) | **M** |

Ordre recommandé : T1 → T2 (Quick Routes livrables seules, valeur immédiate) puis T3 → T4 → T5 → T6 → T7 → T8. Total estimé : 2 tâches S, 4 M, 2 L — pas de XL, les deux features sont volontairement autonomes et sans dépendance réseau.
