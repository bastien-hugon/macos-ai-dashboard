# 10. Serveurs de dev locaux

> Spécification de la détection, de l'enrichissement, de l'affichage et du pilotage des serveurs de développement locaux (ports 3000–9999). Rédigée le 3 juillet 2026, conforme à `plan/01-architecture.md` (module **ServersKit**, `actor PortScanner`, budgets §6, décisions D2–D5) et à `plan/02-data-model.md` (§5 : `DevServer`, `FrameworkKind`, `RuntimeKind`, `PackageRunner`, `StopState`).
> Convention : **[VÉRIFIÉ]** = adossé à un fait mesuré ou documenté de `plan/research/system-integration.md` ; **[HYPOTHÈSE — à valider]** = déduction ou décision produit sans preuve, à confirmer en implémentation.

---

## 1. Objectif & périmètre

Reproduire la section « serveurs de dev locaux » d'AgentPeek : l'app scanne en continu les ports **3000–9999**, identifie chaque process en écoute (framework, runtime, package runner, dossier projet, uptime) et offre trois actions — **ouvrir l'URL**, **copier l'URL**, **arrêter le serveur** — depuis le panel du notch et le popover de la barre de menus.

Sections d'`AGENTPEEK_FEATURES.md` couvertes :
- **§6 — Serveurs de dev locaux** (intégralité) : scan 3000–9999 avec indicateur visible, détection de frameworks (Next.js, Vite, Astro, Wrangler, Storybook, Playwright, serveurs statiques), de runtimes (Node, Bun, Deno, Python, Ruby, Rust, Go), du package runner (npm/pnpm/yarn/bun), lignes port + dossier projet + détails process + uptime, actions open/copy/stop avec garde-fous et tap de confirmation dans la menu bar, états vides soignés, sizing « list-style ».
- **§2.2 — Surfaces UI** : la barre de menus affiche « usage tokens + serveurs » (compteur + section dans le popover).
- **§13 — Changelog** : v0.1.0 (stop/copy/open), v0.1.2 (labels framework + uptime), v0.1.24–0.1.25 (labels Astro/Next.js/Vite/Wrangler/Storybook/Playwright), v0.2.1–0.2.4 (sizing serveurs).
- **§14.7** — périmètre du clone.

Hors périmètre de ce fichier : le rendu conteneur du panel/popover (`plan/notch` et `plan/menubar`), les checks Doctor eux-mêmes (fichier Doctor — on n'expose ici que le comparateur `lsof`), les réglages `serverScanEnabled`/`serverScanExclusions` (UI dans SettingsKit, définis dans `AppSettings`).

---

## 2. Exigences détaillées

### Scan des ports

| ID | Priorité | Exigence |
|---|---|---|
| REQ-SRV-01 | P0 | Le scan énumère les sockets TCP en état `LISTEN` sur les ports **3000–9999 inclus** via la chaîne libproc `proc_listpids(PROC_UID_ONLY, getuid())` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO` (`soi_kind == SOCKINFO_TCP`, `tcpsi_state == TSI_S_LISTEN`), sans spawn de process externe et sans privilège. **[VÉRIFIÉ — 1,3 ms/scan mesuré, résultat identique à `lsof` sur la plage]** |
| REQ-SRV-02 | P0 | Seuls les process de l'**utilisateur courant** sont énumérés (`PROC_UID_ONLY`). Les serveurs root ou d'autres utilisateurs n'apparaissent jamais — limitation assumée et documentée (cf. §5). |
| REQ-SRV-03 | P0 | Cadence : **2 s** quand le panel du notch est ouvert avec la section serveurs visible, **10 s** sinon (menu bar seule) ; un scan **immédiat** est déclenché à chaque ouverture du panel et à chaque ouverture du popover menu bar. **[VÉRIFIÉ pour le coût : 2 s ≈ 0,07 % CPU, 10 s ≈ 0,013 %]** |
| REQ-SRV-04 | P0 | Un scan complet consomme < 5 ms CPU en médiane (mesuré via l'auto-surveillance Doctor) ; le scan tourne exclusivement dans l'`actor PortScanner`, jamais sur MainActor. |
| REQ-SRV-05 | P0 | Identité d'une ligne serveur = **`(pid, port)`** ; les doublons IPv4/IPv6 du même couple sont fusionnés en une seule ligne. **[VÉRIFIÉ — doublons v4+v6 observés]** |
| REQ-SRV-06 | P0 | Chaque scan produit un **diff** (`appeared` / `disappeared` / `refreshed`) par rapport au scan précédent ; seuls les deltas sont transmis à `ServerStore` (jamais la liste complète re-rendue). |
| REQ-SRV-07 | P0 | Un **indicateur de scan** est visible dans l'en-tête de la section pendant qu'une passe de scan est en cours (cf. §4.2). |
| REQ-SRV-08 | P1 | Les process dont `execPath` commence par un préfixe de `AppSettings.serverScanExclusions` (défaut `["/System/"]`) sont exclus de l'affichage. La liste est éditable (Settings avancés/Doctor). **[HYPOTHÈSE — à valider : périmètre de filtrage exact d'AgentPeek inconnu, question ouverte n°7 de la recherche]** |
| REQ-SRV-09 | P1 | `AppSettings.serverScanEnabled == false` ⇒ le scan est arrêté (aucun tick) et la section disparaît des deux surfaces. |
| REQ-SRV-10 | P1 | Un scan est déclenché au retour de veille (`NSWorkspace.didWakeNotification`) pour purger les serveurs morts pendant le sommeil. |
| REQ-SRV-11 | P2 | ServersKit expose un comparateur `lsof -iTCP -sTCP:LISTEN -P -n -F pcnPn` (format machine, anti-troncature) utilisé par DoctorKit comme vérification croisée du scan. **[VÉRIFIÉ — approche recommandée par la recherche]** |

### Enrichissement par process

| ID | Priorité | Exigence |
|---|---|---|
| REQ-SRV-12 | P0 | Pour chaque `(pid, port)` découvert, l'identification lit : `proc_pidpath` (exécutable), `KERN_PROCARGS2` (argv **et** environnement), `PROC_PIDVNODEPATHINFO` (cwd), `PROC_PIDTBSDINFO` (`pbi_start_tvsec/usec` → uptime, `pbi_uid`). **[VÉRIFIÉ — les 4 sources testées sans root]** |
| REQ-SRV-13 | P0 | L'identification est calculée **une seule fois** par `(pid, start_sec, start_usec)` et mise en cache ; les scans suivants ne refont que l'énumération des sockets. Le cache est purgé quand le process disparaît. |
| REQ-SRV-14 | P0 | Détection de **framework** selon la table §3.4 (Next.js, Vite, Astro, Wrangler, Storybook, Playwright, serveur statique), règles évaluées dans l'ordre, première correspondance gagnante ; la confirmation par fichier de config dans le cwd est optionnelle (renforce, ne bloque pas). |
| REQ-SRV-15 | P0 | Détection de **runtime** selon la table §3.4 (Node, Bun, Deno, Python, Ruby, Rust, Go), à partir de `basename(execPath)` d'abord. Le framework prime sur le runtime pour le nom affiché (« Next.js » plutôt que « Node »). |
| REQ-SRV-16 | P0 | Détection du **package runner** via `env["npm_config_user_agent"]` : préfixe `npm/` → npm, `pnpm/` → pnpm, `yarn/` → yarn, `bun/` → bun. **[VÉRIFIÉ pour pnpm ; HYPOTHÈSE — à valider pour npm/yarn/bun, question ouverte n°3]** |
| REQ-SRV-17 | P1 | Le **script lancé** est extrait de `npm_lifecycle_script` (secours : `npm_lifecycle_event`) et affiché en ligne de détail (ex. « expo start »). **[VÉRIFIÉ]** |
| REQ-SRV-18 | P0 | Le **dossier projet** affiché est le `cwd` du process (abrégé `~/…`). Si `cwd == "/"` (apps GUI), afficher à la place le nom de l'app dérivé d'`execPath`. **[VÉRIFIÉ — cas observés]** |
| REQ-SRV-19 | P0 | L'**uptime** est calculé `now − pbi_start_tvsec` et formaté « 45s », « 2m », « 3h », « 5d » (unité unique, la plus grande), rafraîchi à chaque tick de scan. **[VÉRIFIÉ]** |
| REQ-SRV-20 | P0 | Nom affiché (`displayName`) : framework > runtime > `basename(execPath)`. Aucune ligne n'est masquée faute d'identification (dégradé = basename + port). |
| REQ-SRV-21 | P2 | Fallback runner sans `npm_config_user_agent` : remonter la chaîne `pbi_ppid` (2–3 niveaux max) et reconnaître `npm`/`yarn`/`pnpm`/`bun` dans les parents. **[HYPOTHÈSE — à valider : certains runners `exec` l'enfant et disparaissent]** |
| REQ-SRV-22 | P0 | Si `KERN_PROCARGS2` ou le cwd échouent (course : process mort, EPERM), la ligne s'affiche en mode dégradé (basename, projet « — ») sans erreur visible ni log de niveau > debug. |

### UI de la section

| ID | Priorité | Exigence |
|---|---|---|
| REQ-SRV-23 | P0 | Le panel du notch contient une section **« Local Servers »** : en-tête (titre + compteur + indicateur de scan), liste de rows conformes à §4.3. |
| REQ-SRV-24 | P0 | Chaque row affiche : badge framework/runtime, **port** (monospace, préfixé `:`), **dossier projet**, ligne de détail process (runner · script ou basename), **uptime**, actions au survol (open / copy / stop). |
| REQ-SRV-25 | P0 | **État vide** : quand aucun serveur n'est détecté, la section affiche le message d'état vide de §4.4 (jamais une zone blanche ni la disparition brute de la section quand elle est activée). |
| REQ-SRV-26 | P1 | Sizing « list-style » : hauteur de row selon la densité (§4.3) ; la liste affiche au plus **5 rows** dans le panel puis scrolle en interne ; le popover menu bar en affiche au plus **8**. **[HYPOTHÈSE — à valider : seuils exacts d'AgentPeek inconnus]** |
| REQ-SRV-27 | P1 | Tri : **port croissant**, ordre stable entre deux scans (pas de réordonnancement visuel quand seuls les uptimes changent). **[HYPOTHÈSE — à valider : critère de tri d'AgentPeek inconnu]** |
| REQ-SRV-28 | P0 | Le popover **menu bar** contient une section serveurs plate (compteur dans le résumé + rows identiques avec les trois actions). |

### Actions

| ID | Priorité | Exigence |
|---|---|---|
| REQ-SRV-29 | P0 | **Ouvrir l'URL** : `NSWorkspace.shared.open(URL("http://localhost:<port>"))` — navigateur par défaut, sans activer AgentDash. **[VÉRIFIÉ — API testée]** |
| REQ-SRV-30 | P0 | **Copier l'URL** : écriture `NSPasteboard.general` (type `.string`) + retour visuel « Copied » ≈ 1 s sur la row. |
| REQ-SRV-31 | P0 | **Stop** en deux temps partout : 1ᵉʳ clic → état `confirming` (bouton « Confirm? ») pendant **3 s**, 2ᵉ clic dans la fenêtre → exécution. Dans la menu bar, c'est le « tap de confirmation » : le 1ᵉʳ tap arme, le 2ᵉ tap confirme. Expiration des 3 s ⇒ retour à l'état normal sans action. |
| REQ-SRV-32 | P0 | Avant tout signal, la cible est **re-validée** : `pid ≥ 100`, `pid != getpid()` et pas un ancêtre d'AgentDash, `pbi_uid == getuid()`, `(pbi_start_tvsec, pbi_start_tvusec)` et `proc_pidpath` identiques au snapshot affiché. Tout échec ⇒ aucune tentative de kill, row rafraîchie. **[VÉRIFIÉ — garde-fous D5]** |
| REQ-SRV-33 | P0 | Séquence d'arrêt : `SIGTERM` → sonde `kill(pid, 0)` toutes les 200 ms pendant 3 s → si vivant `SIGKILL` → sonde 1 s → scan de rafraîchissement. Jamais `killpg`, jamais le groupe : uniquement le PID affiché. **[VÉRIFIÉ — séquence D5]** |
| REQ-SRV-34 | P0 | Les états d'arrêt sont visibles : `confirming` (bouton « Confirm? »), `terminating` (spinner + « Stopping… », actions désactivées), `gone` (row retirée au scan suivant). |
| REQ-SRV-35 | P1 | Échec d'arrêt (process toujours vivant **et** port toujours en écoute après SIGKILL + 1 s, ou garde-fou déclenché) ⇒ badge « Couldn't stop » 3 s sur la row, retour à l'état normal, entrée de log `.notice`. |
| REQ-SRV-36 | P1 | Critère de succès de l'arrêt : `ESRCH` sur `kill(pid, 0)` **ou** disparition du couple `(pid, port)` du scan suivant (couvre le cas zombie non moissonné, cf. §5). |
| REQ-SRV-37 | P1 | Pendant `terminating`, la row est verrouillée (pas de double kill possible) ; l'action est idempotente si le process a déjà disparu (`alreadyGone` silencieux). |

---

## 3. Conception technique

Tout le code de cette section vit dans le package **ServersKit** (dépend uniquement de DashCore), sauf `ServerStore` qui vit dans DashCore (`@MainActor @Observable`) et est alimenté par injection depuis la composition root, conformément à `01-architecture.md` §3.

### 3.1 API publiques

```swift
// ServersKit — pilotage du scan
public enum ScanCadence: Sendable {
    case foreground   // 2 s  — panel ouvert, section visible
    case background   // 10 s — menu bar seule
    case paused       // serverScanEnabled == false
}

public struct ScanDelta: Sendable {
    public var appeared:    [DevServer]        // enrichis (identification faite)
    public var refreshed:   [DevServer.ID]     // uptime/stopState à rafraîchir
    public var disappeared: [DevServer.ID]
    public var scanStartedAt: Date
    public var scanDuration: Duration          // remonté à DoctorStore (budget CPU)
}

public actor PortScanner {
    public init(portRange: ClosedRange<UInt16> = 3000...9999,
                exclusions: @Sendable () -> [String])   // lit AppSettings.serverScanExclusions
    /// Flux consommé par la composition root, qui applique chaque delta à ServerStore sur MainActor.
    public var deltas: AsyncStream<ScanDelta> { get }
    public func setCadence(_ cadence: ScanCadence)
    public func scanNow()                       // ouverture panel/popover, retour de veille, post-kill
}

// ServersKit — identification (pure, testable)
public struct ProcessIdentity: Sendable {
    public let pid: pid_t
    public let startSec: UInt64, startUsec: UInt64
    public let execPath: String
    public let argv: [String]
    public let env: [String: String]
    public let cwd: String?
}

public struct ServerClassification: Sendable {
    public var framework: FrameworkKind?
    public var runtime: RuntimeKind?
    public var packageRunner: PackageRunner?
    public var script: String?                  // npm_lifecycle_script
    public var displayName: String              // framework > runtime > basename(execPath)
    public var projectPath: String              // cwd, ou nom d'app si cwd == "/"
}

public enum ServerIdentifier {                  // enum-namespace, fonctions pures
    public static func classify(_ p: ProcessIdentity) -> ServerClassification
}

// ServersKit — arrêt sécurisé
public enum StopGuardError: Error, Sendable {
    case pidTooLow, isOurselfOrAncestor, notOurUid, identityChanged
}
public enum StopOutcome: Sendable {
    case terminated(signal: Int32, after: Duration)
    case alreadyGone
    case stillAlive                              // échec → REQ-SRV-35
    case refused(StopGuardError)
}
public enum ServerStopper {
    /// Task.detached(.userInitiated) ; résultat rapporté sur MainActor par l'appelant.
    public static func stop(_ snapshot: DevServer) async -> StopOutcome
}
```

`ServerStore` (DashCore) :

```swift
@MainActor @Observable
public final class ServerStore {
    public private(set) var servers: [DevServer] = []      // triés port croissant
    public private(set) var isScanning: Bool = false        // indicateur d'en-tête
    public private(set) var lastScanAt: Date?
    public var count: Int { servers.count }                 // compteur menu bar

    public func apply(_ delta: ScanDelta)                   // fusion + tri stable
    public func setStopState(_ id: DevServer.ID, _ s: StopState)
}
```

### 3.2 Algorithme de scan (une passe)

```
scanOnce():
 1. pids ← proc_listpids(PROC_UID_ONLY, getuid())                     // ~591 PID, [VÉRIFIÉ]
 2. listen ← []
    pour chaque pid > 0 :
      fds ← proc_pidinfo(pid, PROC_PIDLISTFDS)                        // échec (course/EPERM) → continue
      pour chaque fd de type PROX_FDTYPE_SOCKET :
        si  proc_pidfdinfo(…, PROC_PIDFDSOCKETINFO) == SOCKINFO_TCP
        et  tcpsi_state == TSI_S_LISTEN
        et  port ∈ 3000…9999 :
            listen += (pid, port)      // port = UInt16(bigEndian: insi_lport tronqué)
 3. déduplication : Set<(pid, port)>                                   // fusion v4/v6 (REQ-SRV-05)
 4. filtrage : retirer les (pid, port) dont execPath (cache ou proc_pidpath)
    matche un préfixe d'exclusion (REQ-SRV-08)
 5. diff avec previousKeys :
      appeared    = clés nouvelles
      disappeared = clés absentes
      refreshed   = clés conservées (uptime à recalculer côté store)
 6. pour chaque appeared :
      key = (pid, startSec, startUsec)                                 // start lu via PROC_PIDTBSDINFO
      classification = cache[key] ?? classify(readIdentity(pid))       // REQ-SRV-13
      construire DevServer (id, displayName, projectPath, url, startTime, stopState:.none)
 7. purge du cache pour les pid disparus ; previousKeys ← clés courantes
 8. yield ScanDelta(appeared, refreshed, disappeared, duration)
```

Le code libproc (énumération PID, extraction des sockets `LISTEN`, parsing `KERN_PROCARGS2`) est repris **tel quel** de la recherche §1.2 et §2.2, où il est compilé et validé sur cette machine **[VÉRIFIÉ]**. Points de vigilance conservés : marge de +64 entrées entre les deux appels `proc_listpids` ; allocation directe de `kern.argmax` octets pour `KERN_PROCARGS2` (évite la course taille/lecture) ; `insi_lport` est un `Int32` contenant le port 16 bits en ordre réseau.

### 3.3 Cadence et pilotage

```
                 setCadence(.foreground) + scanNow()
   ┌──────────┐ ───────────────────────────────────► ┌──────────────┐
   │ background│        (ouverture panel/popover)     │  foreground  │
   │  tick 10 s│ ◄─────────────────────────────────── │   tick 2 s   │
   └──────────┘        (fermeture des surfaces)       └──────────────┘
        ▲  │ setCadence(.paused)                            │
        │  ▼ (serverScanEnabled = false)                    │ scanNow() aussi sur :
   ┌──────────┐                                             │  • didWakeNotification
   │  paused  │                                             │  • fin d'une séquence stop
   └──────────┘                                             └─ (rafraîchissement immédiat)
```

- Timer : `DispatchSourceTimer` interne à l'actor, réarmé au changement de cadence ; aucun tick en `.paused`.
- `isScanning` est levé au début de la passe et abaissé à la fin ; comme une passe dure ~1,3 ms, l'UI maintient l'indicateur **au minimum 600 ms** lors d'un `scanNow()` déclenché par l'utilisateur, pour que « l'indicateur de scan visible » soit perceptible. **[HYPOTHÈSE — à valider : rendu exact d'AgentPeek inconnu]**
- L'uptime affiché est recalculé côté store à chaque delta (`refreshed`) — la granularité 2 s/10 s est suffisante pour un format « 2m / 3h / 5d ».

### 3.4 Tables de détection (reprises intégralement de la recherche §2.4)

Entrées : `basename(execPath)`, `argv` (jointure des éléments), `cwd`, `env`. Règles évaluées dans l'ordre, première correspondance gagnante. Framework > runtime pour `displayName`.

**Frameworks** — périmètre AgentPeek §6 :

| Framework | Règle argv | Confirmation cwd (optionnelle) | Port par défaut |
|---|---|---|---|
| Next.js | élément se terminant par `/next` ou `next` suivi de `dev`/`start`, ou contient `next/dist/bin/next` | `next.config.{js,mjs,ts}` | 3000 |
| Vite | élément `vite` ou contient `vite/bin/vite.js` ou `node_modules/.bin/vite` | `vite.config.{js,ts,mts}` | 5173 |
| Astro | élément `astro` + `dev`/`preview`, ou contient `astro/astro.js` | `astro.config.{mjs,ts}` | 4321 |
| Wrangler | élément `wrangler` + `dev` (ou `pages`) | `wrangler.{toml,jsonc}` | 8787 |
| Storybook | élément `storybook` ou contient `storybook/bin` ou `@storybook` | `.storybook/` | 6006 |
| Playwright | élément contenant `playwright` (`show-report`, `test --ui`) | `playwright.config.{ts,js}` | 9323 |
| Serveur statique | `serve`, `http-server`, `live-server`, `python(3) -m http.server`, `php -S`, `caddy`, `miniserve` | — | variés |

> Note : la plage 3000–9999 est le contrat produit ; un `vite --port 2999` échappe au scan, c'est assumé (identique à AgentPeek).

**Runtimes** :

| Runtime | Règle |
|---|---|
| Node | `basename == "node"` (se fier au basename, pas au chemin — nvm/volta/fnm) **[VÉRIFIÉ]** |
| Bun | basename `bun` ou `bunx` |
| Deno | basename `deno` |
| Python | basename matche `python(\d(\.\d+)?)?`, ou exec dans `…/venv/bin/` |
| Ruby | basename `ruby`, ou `puma`/`rails`/`unicorn` dans argv |
| Rust | `execPath` contient `/target/debug/` ou `/target/release/`, ou `Cargo.toml` dans cwd **[HYPOTHÈSE — à valider : faux négatifs pour un binaire installé]** |
| Go | `execPath` contient `/go-build` ou `$GOPATH/bin`, ou `go.mod` dans cwd **[HYPOTHÈSE — à valider]** |

**Package runner** : préfixe de `env["npm_config_user_agent"]` (`pnpm/9.15.0 npm/? node/v22.18.0 darwin arm64` → pnpm) **[VÉRIFIÉ pnpm ; HYPOTHÈSE pour npm/yarn/bun]** ; **script** : `npm_lifecycle_script` puis `npm_lifecycle_event` **[VÉRIFIÉ]** ; fallback chaîne parents (REQ-SRV-21, P2).

Les tests unitaires de `ServerIdentifier.classify` couvrent chaque ligne des deux tables avec des `ProcessIdentity` fabriquées (fonction pure, aucune dépendance système).

### 3.5 Séquence d'arrêt

```
UI (row, MainActor)                ServerStopper (Task.detached)              noyau
────────────────────               ───────────────────────────────            ─────
clic 1 → stopState = .confirming(until: now+3s)
clic 2 (< 3 s) → stopState = .terminating
        │ stop(snapshot) ─────────► validateStopTarget(snapshot)
        │                            ├─ pid ≥ 100 ?                    (sinon .refused)
        │                            ├─ pid ≠ getpid(), pas ancêtre ?  (sinon .refused)
        │                            ├─ proc_pidinfo TBSDINFO ────────► pbi_uid == getuid() ?
        │                            └─ start_time + execPath == snapshot ?  // anti-réutilisation PID
        │                           kill(pid, SIGTERM) ───────────────► signal
        │                           boucle 15 × 200 ms : kill(pid, 0)
        │                            └─ ESRCH → .terminated(SIGTERM)
        │                           sinon kill(pid, SIGKILL), sonde 1 s
        │                            ├─ ESRCH → .terminated(SIGKILL)
        │                            └─ vivant → .stillAlive (ou zombie, cf. REQ-SRV-36)
        ◄──── outcome ──────┘
outcome appliqué : .terminated/.alreadyGone → scanNow() → row disparaît (.gone)
                   .stillAlive/.refused     → badge « Couldn't stop », stopState = .none
```

Si le scan suivant montre que le port n'écoute plus alors que `kill(pid, 0)` réussit encore (zombie non moissonné), l'arrêt est considéré réussi (REQ-SRV-36).

### 3.6 Intégration dans l'app

- La composition root (`AgentDashApp`) consomme `portScanner.deltas` dans une `Task` et appelle `serverStore.apply(delta)` sur MainActor — deltas `Sendable`, aucune UI dans ServersKit.
- L'ouverture/fermeture du panel et du popover pilote `setCadence` + `scanNow()` (REQ-SRV-03) ; `NotchUI`/`MenuBarUI` n'observent que `ServerStore`.
- `scanDuration` de chaque delta alimente `DoctorStore` (médiane glissante ; alerte si > 5 ms persistant, REQ-SRV-04).

---

## 4. Spécification UX/UI

Textes d'interface en anglais, comme AgentPeek. Dimensions en points, densité `regular` (les variantes `compact`/`colossal` appliquent les facteurs du système de densité global défini dans le fichier Appearance).

### 4.1 Emplacements

- **Panel du notch** : section « Local Servers » sous les sessions (au-dessus de Quick Routes), repliable comme les autres sections du panel.
- **Popover menu bar** : section plate équivalente ; le résumé de la barre de menus inclut le **compteur de serveurs** (features §2.2).

### 4.2 En-tête de section

```
Local Servers  ③              ⟳ scanning…
└─ titre        └─ compteur     └─ indicateur (droite)
```

- Titre : « Local Servers », graisse selon `titleWeight`.
- Compteur : pastille discrète avec `servers.count` ; masquée si 0.
- Indicateur de scan : petit spinner + « scanning… » (11 pt, opacité 0,6), affiché quand `isScanning` (minimum perçu 600 ms sur un scan déclenché par l'utilisateur — REQ-SRV-07).

### 4.3 Row serveur

```
┌────────────────────────────────────────────────────────────────────────┐
│ [Next.js] :3000  dune-web                                    2h        │
│  pnpm · next dev                             [↗ Open][⧉ Copy][■ Stop]  │
└────────────────────────────────────────────────────────────────────────┘
```

- Hauteur : 44 pt (`regular`) / 36 pt (`compact`) / 56 pt (`colossal`) — deux lignes de texte. **[HYPOTHÈSE — à valider : métriques exactes d'AgentPeek inconnues]**
- Ligne 1 : **badge** framework ou runtime (chip 10 pt, fond teinté), **port** en fonte monospace semi-bold (« :3000 »), **nom du projet** (`basename(projectPath)`, tooltip = chemin complet abrégé `~/…`), **uptime** aligné à droite (« 45s », « 2m », « 3h », « 5d »).
- Ligne 2 : détail process en 11 pt, opacité 0,65 : `packageRunner · script` (« pnpm · next dev ») ; sinon `runner · basename(execPath)` ; sinon `basename(execPath)` seul.
- Actions : trois boutons icône révélés au survol (toujours visibles dans le popover menu bar, qui n'a pas d'état hover fiable) :
  - **Open** (icône `arrow.up.forward`) — tooltip « Open in browser » ;
  - **Copy** (icône `doc.on.doc`) — tooltip « Copy URL » ; après clic, remplacement bref par « Copied » (1 s) ;
  - **Stop** (icône `stop.fill`, teinte rouge au survol) — tooltip « Stop server ».
- États du bouton Stop :
  - `confirming` : le bouton s'élargit en pilule rouge « **Confirm?** » pendant 3 s (animation `.spring` courte) ; dans la menu bar c'est le tap de confirmation exigé par les features §6 ;
  - `terminating` : spinner + « Stopping… », les trois actions désactivées ;
  - échec : pilule « Couldn't stop » 3 s, puis retour normal.
- Apparition/disparition de rows : transition insert/remove douce (opacité + hauteur, ~200 ms), cohérente avec les animations de sessions v0.2.11.

### 4.4 État vide et état désactivé

- État vide (scan actif, 0 résultat) :
  - ligne 1 : « **No local servers** » (13 pt, secondaire) ;
  - ligne 2 : « Dev servers on ports 3000–9999 will show up here. » (11 pt, tertiaire) ;
  - hauteur fixe ≈ 56 pt — la section ne « saute » pas quand le premier serveur apparaît.
- `serverScanEnabled == false` : la section n'est pas rendue du tout (panel et popover), le compteur menu bar disparaît (REQ-SRV-09).

### 4.5 Sizing de la liste

- Panel : jusqu'à 5 rows visibles puis scroll interne (indicateurs de scroll masqués, fondu haut/bas de 8 pt) — sizing « list-style » des features §6 ; la section ne participe pas au mode `growable` des sessions (cap fixe). **[HYPOTHÈSE — à valider]**
- Popover menu bar : jusqu'à 8 rows puis scroll.

---

## 5. Cas limites & gestion d'erreurs

| # | Cas | Comportement spécifié |
|---|---|---|
| 1 | **Plusieurs serveurs, même projet** (ex. Next.js :3000 + Storybook :6006 dans le même cwd) | Deux rows distinctes (identité `(pid, port)`), même `projectPath` affiché ; pas de regroupement visuel en v1 (tri par port). Regroupement par projet = évolution P2 éventuelle. |
| 2 | **Un même PID écoute sur plusieurs ports** (serveur + HMR/websocket) | Une row par port. Arrêter l'une tue le process ⇒ toutes ses rows disparaissent au scan de rafraîchissement — assumé, documenté. Le libellé de confirmation reste « Confirm? » (pas d'énumération des autres ports en v1). |
| 3 | **Doublon IPv4/IPv6** du même `(pid, port)` | Fusionné à l'étape 3 du scan (REQ-SRV-05). **[VÉRIFIÉ — cas réels observés]** |
| 4 | **Process zombie** | Un zombie n'a plus de fd : il disparaît naturellement du scan. Après un stop, `kill(pid, 0)` peut encore réussir sur un zombie non moissonné → le critère « port disparu du scan » valide l'arrêt (REQ-SRV-36). |
| 5 | **Process mort entre l'énumération et `proc_pidinfo`** (course) | Chaque appel libproc qui échoue ⇒ `continue` silencieux ; jamais d'erreur UI. La row éventuelle disparaît au scan suivant. |
| 6 | **Port réutilisé** par un nouveau process entre deux scans | Nouvelle identité `(pid, port)` ⇒ ancienne row `disappeared`, nouvelle row `appeared`, uptime repart de zéro. Aucun héritage d'identification (cache par `(pid, start_time)`). |
| 7 | **PID réutilisé** par le système entre l'affichage et le clic Stop | Garde-fou 4 de `validateStopTarget` : `start_time` ou `execPath` différents ⇒ `.refused(.identityChanged)`, aucun signal envoyé, scan de rafraîchissement. **[VÉRIFIÉ — réutilisation de PID documentée XNU]** |
| 8 | **Serveurs non-user** (root, autres comptes, ex. `httpd` root sur 8080) | Invisibles par construction (`PROC_UID_ONLY`) — périmètre produit « serveurs de dev de l'utilisateur » et garantie de sécurité du Stop. Documenté dans la FAQ/Doctor. |
| 9 | **Bruit système/apps** dans la plage (ControlCenter/AirPlay 5000 et 7000, Spotify, Figma, Raycast…) | Exclusion par préfixe d'`execPath` (défaut `/System/`) ; le reste s'affiche (AgentPeek semble afficher large). Liste ajustable sans release via Settings avancés. **[HYPOTHÈSE — à valider : comportement produit exact]** |
| 10 | **Serveur supervisé qui respawne** (nodemon, `next dev` relancé par turbo…) | Après un Stop réussi, le superviseur peut relancer : une nouvelle row apparaît (nouveau pid). Comportement correct par construction ; pas de « kill du parent » (jamais `killpg`). |
| 11 | **Échec du kill** (`EPERM` inattendu, process protégé) | `kill()` retourne −1 ⇒ `.stillAlive` ⇒ badge « Couldn't stop », log `.notice` avec errno ; jamais de nouvelle tentative automatique. |
| 12 | **AgentDash lui-même ou un ancêtre** écoute dans la plage (app lancée par un script de dev) | Garde-fou 2 : `.refused(.isOurselfOrAncestor)` — le Stop est refusé ; la row reste affichée. |
| 13 | **`cwd == "/"`** (apps GUI type Figma) | Dossier projet remplacé par le nom d'app depuis `execPath` (REQ-SRV-18). **[VÉRIFIÉ]** |
| 14 | **Échec de lecture argv/env** (course, buffer) | Mode dégradé REQ-SRV-22 : basename + port, pas de framework/runner. |
| 15 | **Serveur HTTPS ou lié à une interface précise** | L'URL construite est toujours `http://localhost:<port>` — pas de sonde TLS ni de lecture d'adresse locale en v1. **[HYPOTHÈSE — à valider : AgentPeek ne documente pas mieux]** |
| 16 | **Docker Desktop** publiant des ports | Le process en écoute est `com.docker.backend` (process utilisateur) ⇒ row affichée avec basename Docker ; Stop tuerait le backend Docker — les garde-fous n'interdisent pas ce cas, la confirmation en 2 temps est la protection. **[HYPOTHÈSE — à valider sur machine avec Docker]** |
| 17 | **Veille/réveil** | Timers muets pendant le sommeil ; `didWakeNotification` ⇒ `scanNow()` — purge les serveurs morts, uptimes recalculés (absolus, donc justes). |
| 18 | **> 20 serveurs** (plages de microservices) | Liste scrollable (REQ-SRV-26) ; le scan reste O(nb PID), pas O(nb serveurs) — coût inchangé. |
| 19 | **Écriture pasteboard refusée** (cas exotique) | `setString` retourne `false` ⇒ pas de « Copied », log `.debug` ; pas d'alerte. |
| 20 | **Expiration de la confirmation** (3 s sans 2ᵉ clic) | `confirming(until:)` dépassé ⇒ retour à `.none` au tick d'horloge UI ; aucun signal envoyé. |

---

## 6. Critères d'acceptation

1. **Détection de base** — *Given* `python3 -m http.server 8000` lancé dans `~/Documents/demo`, *When* le panel du notch est ouvert, *Then* une row apparaît en ≤ 2 s avec badge « Python », port « :8000 », projet « demo », uptime croissant.
2. **Framework Next.js** — *Given* `pnpm dev` (Next.js) dans un projet avec `next.config.ts`, *When* la row apparaît, *Then* le badge indique « Next.js » (pas « Node »), la ligne de détail « pnpm · next dev », le port « :3000 ».
3. **Scan immédiat + indicateur** — *Given* le panel fermé et un serveur lancé depuis > 10 s, *When* j'ouvre le panel, *Then* l'indicateur « scanning… » est visible brièvement et la liste est à jour sans attendre le tick de 2 s.
4. **Fusion v4/v6** — *Given* un serveur Node écoutant en double v4+v6 sur le même port (vérifiable via `lsof`), *When* la section s'affiche, *Then* une seule row existe pour ce couple `(pid, port)`.
5. **Open** — *Given* une row « :3000 », *When* je clique Open, *Then* le navigateur par défaut ouvre `http://localhost:3000` et AgentDash ne prend pas le focus.
6. **Copy** — *Given* une row « :8787 », *When* je clique Copy, *Then* le presse-papiers contient exactement `http://localhost:8787` et « Copied » s'affiche ~1 s.
7. **Stop nominal** — *Given* un serveur Vite, *When* je clique Stop puis « Confirm? » dans les 3 s, *Then* le bouton passe en « Stopping… », le process reçoit SIGTERM, la row disparaît en ≤ 4 s, et aucun autre process n'est affecté.
8. **Confirmation expirée** — *Given* l'état « Confirm? », *When* j'attends > 3 s sans cliquer, *Then* le bouton revient à l'état normal et `ps` confirme que le process est intact.
9. **Tap de confirmation menu bar** — *Given* le popover menu bar ouvert, *When* je tape une fois Stop, *Then* rien n'est tué et le bouton affiche « Confirm? » ; un second tap dans les 3 s arrête le serveur.
10. **Garde-fou anti-PID recyclé** — *Given* une row affichée puis le serveur tué en externe et (simulation en test) un autre process prenant le même PID, *When* je confirme Stop, *Then* aucun signal n'est envoyé (`.refused(.identityChanged)`) et la liste se rafraîchit.
11. **SIGKILL de secours** — *Given* un process qui ignore SIGTERM (`trap '' TERM` + serveur), *When* je confirme Stop, *Then* le process est tué par SIGKILL après ~3 s et la row disparaît.
12. **État vide** — *Given* aucun serveur dans la plage, *When* la section est visible, *Then* elle affiche « No local servers » + « Dev servers on ports 3000–9999 will show up here. ».
13. **Non-user invisible** — *Given* un serveur lancé via `sudo` sur le port 8080, *When* la section s'affiche, *Then* ce serveur n'apparaît pas.
14. **CPU au repos** — *Given* le panel fermé pendant 10 min avec 3 serveurs actifs, *When* je mesure le CPU d'AgentDash (Moniteur d'activité), *Then* la contribution du scan reste indiscernable (budget global idle < 0,5 % tenu).
15. **Toggle** — *Given* `serverScanEnabled` désactivé dans Settings, *When* je rouvre le panel et le popover, *Then* la section et le compteur ont disparu et aucun scan ne tourne (vérifiable par log `.debug`).
16. **`/clear` du cache** — *Given* un serveur arrêté puis relancé sur le même port, *When* la nouvelle row apparaît, *Then* son uptime repart de zéro et son identification est recalculée (nouveau pid).

---

## 7. Dépendances (autres fichiers du plan) et risques

### Dépendances

| Fichier | Ce qu'on en attend |
|---|---|
| `01-architecture.md` | module ServersKit, `actor PortScanner` (§5.1), cadences 2 s/10 s, budgets CPU (§6), décisions D2–D5, threading (deltas Sendable → MainActor). |
| `02-data-model.md` §5 | `DevServer`, `DevServer.ID (pid, port)`, `FrameworkKind`, `RuntimeKind`, `PackageRunner`, `StopState` — repris tels quels, non redéfinis ici. |
| Fichier plan **notch** | conteneur de la section (panel, sections repliables, densité, animations d'insertion). |
| Fichier plan **menu bar** | popover plat, compteur de serveurs dans le résumé, contrainte « pas de hover fiable » (actions toujours visibles). |
| Fichier plan **settings** | exposition de `serverScanEnabled` et `serverScanExclusions`. |
| Fichier plan **doctor** | consommation du comparateur `lsof -F` (REQ-SRV-11) et de `scanDuration` (REQ-SRV-04). |
| `research/system-integration.md` §1–3 | code libproc validé, mesures (1,3 ms/scan, 0,65 ms IPC sans objet ici), tables de détection, séquence et garde-fous de kill. |

### Risques

| Risque | Impact | Mitigation |
|---|---|---|
| `npm_config_user_agent` absent pour npm/yarn/bun ou perdu après `exec` (question ouverte n°3) | runner non détecté | dégradé propre (ligne de détail sans runner) ; fallback chaîne parents en P2 (REQ-SRV-21) ; banc d'essai `scripts/experiments/` avant implémentation. |
| Heuristiques Rust/Go trop faibles (binaire installé hors `target/`) | runtime « other » affiché | acceptable (basename affiché) ; enrichir la table par itérations. |
| Filtrage du bruit mal calibré (trop ou pas assez de rows vs AgentPeek) | UX divergente du produit de référence | liste d'exclusion dans `AppSettings` (modifiable sans release) ; question ouverte n°7 suivie. |
| Layout des structures libproc modifié par une future version de macOS | scan cassé | en-têtes publics du SDK stables depuis 10.5 (risque faible) ; le check croisé `lsof` du Doctor détecterait une divergence. |
| Kill d'un process critique de l'utilisateur (Docker backend, tunnel…) | perte de travail | garde-fous D5 + confirmation en 2 temps + jamais `killpg` + périmètre uid ; aucun kill automatique, toujours une action humaine. |
| Scan sur des machines à très grand nombre de PID (> 2 000) | dépassement du budget 5 ms | mesure `scanDuration` remontée au Doctor ; si besoin, énumération des fd limitée aux process ayant des sockets (pré-filtre) — optimisation différée. |

---

## 8. Découpage en tâches

| # | Tâche | Taille | Dépend de |
|---|---|---|---|
| T1 | ServersKit : scan libproc (`listPids`, `listeningPorts`), plage + dédup v4/v6, tests contre `lsof -F` | **M** | — |
| T2 | ServersKit : lecture d'identité (`proc_pidpath`, `KERN_PROCARGS2`, cwd, `TBSDINFO`) + `ProcessIdentity`, gestion des courses | **M** | — |
| T3 | ServersKit : `ServerIdentifier.classify` — tables frameworks/runtimes/runner/script + tests unitaires exhaustifs (1 test par ligne de table) | **M** | T2 |
| T4 | ServersKit : `actor PortScanner` — cadences, `scanNow`, diff, cache par `(pid, start_time)`, `AsyncStream<ScanDelta>` | **M** | T1, T3 |
| T5 | DashCore : `ServerStore` (@MainActor) — apply/tri stable/`isScanning`/`setStopState` + branchement composition root (cadence pilotée par panel/popover, `didWakeNotification`) | **S** | T4 |
| T6 | ServersKit : `validateStopTarget` + `ServerStopper.stop` (SIGTERM→SIGKILL, critère zombie) + tests (process de test `trap '' TERM`) | **M** | T2 |
| T7 | NotchUI : section « Local Servers » — en-tête + indicateur, rows 2 lignes, actions hover, états Stop, état vide, scroll 5 rows, animations | **L** | T5 |
| T8 | MenuBarUI : section popover + compteur résumé + tap de confirmation (actions toujours visibles) | **M** | T5, T7 (composants partagés) |
| T9 | Actions Open/Copy (`NSWorkspace`, `NSPasteboard`) + retours visuels | **S** | T7 |
| T10 | Banc d'hypothèses `scripts/experiments/servers/` : `npm_config_user_agent` (npm/yarn/bun), chaîne parents, Docker, exclusions — valide REQ-SRV-16/21 et cas 9/16 | **S** | T2 |
| T11 | Doctor : export du comparateur `lsof -F` + remontée `scanDuration` (intégration côté DoctorKit spécifiée dans le fichier doctor) | **S** | T4, T6 |

Chemin critique MVP (P0) : T1 → T2 → T3 → T4 → T5 → T7 (+ T6, T9 en parallèle après T2/T5). Total estimé : 2 tailles S de marge incluses dans T10/T11 hors MVP.
