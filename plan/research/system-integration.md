# Recherche technique — Intégration système macOS pour AgentDash

> **AgentDash** (nom provisoire) — clone d'AgentPeek pour Claude Code + Cursor.
> Document de recherche : scan de ports, identification de process, arrêt de serveurs, IPC hooks ↔ app, tail des transcripts, raccourcis clavier globaux, divers (login item, notifications, NSWorkspace, sobriété RAM/CPU).
>
> **Machine de validation** : MacBook Apple Silicon (arm64), macOS 26.5 (build 25F71), Xcode avec Swift 6.3, SDK macOS 26.4. Cible du projet : macOS 14+ — toutes les API retenues ici existent depuis macOS 13 ou avant (indiqué au cas par cas).
>
> **Convention** : chaque affirmation est marquée **[VÉRIFIÉ]** (testée sur cette machine ou lue dans les en-têtes du SDK local) ou **[HYPOTHÈSE]** (à valider en implémentation). Les programmes de test compilés et exécutés pour ce document sont conservés dans le scratchpad de session (`portscan_test.swift`, `env_test.swift`, `hook_test.swift`, `unixsock_test.swift`, `fsevents_test.swift`, `misc_test.swift`).

---

## 0. Contrainte structurante : pas d'App Sandbox

Tout ce que fait AgentDash — lire les fd d'autres process via `libproc`, envoyer des signaux, lire `~/.claude` et `~/.cursor`, créer un socket UNIX partagé, écrire dans `~/.claude/settings.json` — est **incompatible avec l'App Sandbox** (le sandbox interdit l'introspection des autres process, `kill()` vers l'extérieur, et l'accès arbitraire au home). **[VÉRIFIÉ en principe — comportement documenté du sandbox]**

**Décision induite** : distribution hors Mac App Store, en **Developer ID signé + notarisé** (c'est exactement ce que fait AgentPeek : DMG signé/notarisé). Aucune permission TCC n'est requise pour les briques retenues ci-dessous (ni Accessibility, ni Full Disk Access — `~/.claude` et `~/.cursor` ne sont pas des emplacements protégés par TCC). **[VÉRIFIÉ : tous les tests de ce document ont tourné sans aucune permission accordée]**

---

## 1. Scan des ports 3000–9999

### 1.1 Comparaison des trois approches

| Critère | (a) libproc | (b) `sysctl net.inet.tcp.pcblist_n` | (c) parsing `lsof` |
|---|---|---|---|
| Fonctionne sans root | **Oui** pour les process du même utilisateur **[VÉRIFIÉ]** | Oui, lecture du buffer OK sans root **[VÉRIFIÉ]** | Oui pour les process de l'utilisateur **[VÉRIFIÉ]** |
| Coût mesuré | **1,3 ms/scan** soutenu (591 PID, 27 sockets LISTEN), 4,6 ms à froid **[VÉRIFIÉ]** | 1 lecture de ~84 Ko **[VÉRIFIÉ]**, parsing non mesuré | 30–40 ms réel par exécution + spawn de process **[VÉRIFIÉ]** |
| Association port → PID | Directe (on part du PID) | Indirecte : les structures `xtcpcb_n`/`xsocket_n` n'exposent pas de PID fiable ; il faut de toute façon repasser par libproc **[HYPOTHÈSE : `netstat -anv` affiche `process:pid`, donc une association existe, mais via des structures non documentées]** | Directe (colonne PID) |
| Stabilité de l'API | En-têtes publics du SDK (`libproc.h`, `sys/proc_info.h`), utilisée par Apple depuis 10.5 **[VÉRIFIÉ dans le SDK]** | Structures kernel non documentées, layout susceptible de changer entre versions de macOS | Format texte semi-stable ; noms de commande tronqués à 9 caractères (`ControlCe`, `figma_age`), espaces échappés (`Expo\x20O`) **[VÉRIFIÉ]** |
| Dépendance externe | Aucune | Aucune | Spawn de `/usr/sbin/lsof` à chaque scan |

**Recommandation : approche (a) libproc.** C'est la seule qui soit à la fois native, rapide, sans spawn, et qui donne directement le PID (dont on a besoin ensuite pour l'identification et le kill). L'approche (c) reste utile comme **outil de vérification croisée dans l'onglet Doctor** (comparer nos résultats à `lsof -iTCP -sTCP:LISTEN -P -n -F pcnPn` — le format machine `-F` évite la troncature des noms). L'approche (b) est écartée : elle ne fait gagner que l'énumération des PID mais repose sur des structures non documentées.

Limite assumée de (a) sans root : on ne voit que les serveurs **de l'utilisateur courant** (`PROC_UID_ONLY`). C'est exactement le périmètre voulu (serveurs de dev locaux) et une garantie de sécurité gratuite pour la fonction « arrêter le serveur ».

### 1.2 Code Swift validé (compilé et exécuté sur cette machine)

Constantes confirmées dans `$SDK/usr/include/sys/proc_info.h` **[VÉRIFIÉ]** : `PROC_ALL_PIDS=1`, `PROC_UID_ONLY=4`, `PROC_PIDLISTFDS=1`, `PROC_PIDTBSDINFO=3`, `PROC_PIDVNODEPATHINFO=9`, `PROX_FDTYPE_SOCKET=2`, `PROC_PIDFDSOCKETINFO=3`, `SOCKINFO_TCP=2` (enum), `TSI_S_LISTEN=1`. Toutes sont importées automatiquement par `import Darwin` (attention : `SOCKINFO_TCP` est importé comme `Int`, pas comme enum Swift).

```swift
import Darwin
import Foundation

/// Énumère les PID de l'utilisateur courant. [VÉRIFIÉ : 591 PID énumérés]
func listPids(uid: uid_t) -> [pid_t] {
    var size = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), nil, 0)
    guard size > 0 else { return [] }
    let capacity = Int(size) / MemoryLayout<pid_t>.stride + 64   // marge : des process naissent entre les 2 appels
    var pids = [pid_t](repeating: 0, count: capacity)
    size = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(uid), &pids,
                         Int32(capacity * MemoryLayout<pid_t>.stride))
    guard size > 0 else { return [] }
    return pids[0..<(Int(size) / MemoryLayout<pid_t>.stride)].filter { $0 > 0 }
}

struct ListenInfo: Hashable { let pid: pid_t; let port: UInt16; let ipv6: Bool }

/// Sockets TCP en état LISTEN d'un process. [VÉRIFIÉ]
func listeningPorts(pid: pid_t) -> [ListenInfo] {
    let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bufSize > 0 else { return [] }   // échoue silencieusement (EPERM) pour les process d'autres users
    let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.stride + 32
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
    let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                               Int32(count * MemoryLayout<proc_fdinfo>.stride))
    guard written > 0 else { return [] }
    var out: [ListenInfo] = []
    for i in 0..<(Int(written) / MemoryLayout<proc_fdinfo>.stride)
        where fds[i].proc_fdtype == PROX_FDTYPE_SOCKET {
        var sock = socket_fdinfo()
        let r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO,
                               &sock, Int32(MemoryLayout<socket_fdinfo>.size))
        guard r == Int32(MemoryLayout<socket_fdinfo>.size),
              sock.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = sock.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
        // insi_lport est un Int32 contenant le port 16 bits en ordre réseau
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        let isV6 = (tcp.tcpsi_ini.insi_vflag & UInt8(INI_IPV6)) != 0
        out.append(ListenInfo(pid: pid, port: port, ipv6: isV6))
    }
    return out
}
```

Résultat du test réel sur cette machine (extrait) — **strictement identique à la sortie de `lsof` sur la plage 3000–9999** **[VÉRIFIÉ]** :

```
PIDs utilisateur énumérés : 591
Durée du scan complet : 4.6 ms
  port 8081 [v6] pid=57034  exe: …/node   cwd: /Users/bastien/Documents/dune/apps/mobile
                            argv: node …/expo/bin/cli start
  port 8080 [v6] pid=79769  exe: …/caddy  cwd: /Users/bastien/Documents/dune
                            argv: caddy run --config Caddyfile
  port 5037 [v4] pid=3341   exe: …/adb    argv: adb -L tcp:5037 fork-server
  …
bench : 100 scans en 0.13 s → 1.3 ms/scan
```

### 1.3 Fréquence de polling et budget CPU

- Coût mesuré : **1,3 ms de CPU par scan complet** (100 scans consécutifs en 0,13 s). **[VÉRIFIÉ]**
- Recommandation :
  - **panel visible avec la section serveurs** : scan toutes les **2 s**, plus un scan immédiat à l'ouverture du panel (c'est « l'indicateur de scan visible » d'AgentPeek) ;
  - **panel fermé / menu bar seule** : toutes les **10 s** (le compteur de serveurs de la menu bar n'a pas besoin de plus) ;
  - budget résultant : 2 s → ~0,07 % CPU ; 10 s → ~0,013 % CPU. Négligeable.
- **Dédoublonnage** : un même serveur écoute souvent en double v4 + v6 (observé : `rapportd`, `ControlCenter`), et un même PID peut avoir plusieurs ports. Clé d'identité d'une ligne serveur : `(pid, port)` ; fusionner v4/v6 du même couple. **[VÉRIFIÉ sur les données réelles]**
- **Filtrage du bruit** : la plage 3000–9999 attrape des process système/apps (ControlCenter 5000/7000 = AirPlay Receiver, Spotify, Figma, Raycast…). Prévoir une liste d'exclusion par chemin d'exécutable (`/System/…`, apps signées connues sans intérêt dev) **et** ne pas exclure trop agressivement : AgentPeek affiche visiblement tout ce qui écoute. À trancher en design produit. **[HYPOTHÈSE sur le comportement exact d'AgentPeek]**
- Diff d'état entre deux scans → événements « serveur apparu / disparu » pour l'UI et l'uptime.

---

## 2. Identification des process

### 2.1 Les quatre sources d'information (toutes validées sans root, même user)

| Donnée | API | Test sur cette machine |
|---|---|---|
| Chemin de l'exécutable | `proc_pidpath(pid, buf, 4096)` | **[VÉRIFIÉ]** — fonctionne même sur les process root (testé sur pid 1 → `/sbin/launchd`) |
| argv complet | `sysctl [CTL_KERN, KERN_PROCARGS2, pid]` | **[VÉRIFIÉ]** pour les process du même user ; **refusé errno 22 (EINVAL)** sur les process d'autres users |
| Environnement complet | même buffer `KERN_PROCARGS2`, après argv | **[VÉRIFIÉ]** — voir 2.3, lecture de `npm_config_user_agent` sur un process tiers |
| cwd | `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)` → `pvi_cdir.vip_path` | **[VÉRIFIÉ]** pour les process du même user ; **refusé errno 1 (EPERM)** sur pid 1 |
| Date de lancement (uptime) | `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` → `proc_bsdinfo.pbi_start_tvsec/usec` | **[VÉRIFIÉ]** — uptimes cohérents (jusqu'à 19 jours sur les daemons) |
| PID parent, UID | `proc_bsdinfo.pbi_ppid`, `pbi_uid` | **[VÉRIFIÉ dans le SDK]** (champs présents ; parcours de la chaîne parent non testé) |

### 2.2 Parsing de `KERN_PROCARGS2` (format vérifié empiriquement)

Format du buffer : `Int32 argc` | `exec_path\0` | bourrage `\0…` | `argv[0]\0 … argv[argc-1]\0` | `envp[0]\0 …` | double `\0` final. Allouer directement `kern.argmax` octets (l'appel taille-puis-lecture est sujet à une course si les args changent).

```swift
struct ProcArgs { let execPath: String; let argv: [String]; let env: [String: String] }

func procArgs(pid: pid_t) -> ProcArgs? {
    var argmax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&mibMax, 2, &argmax, &size, nil, 0) == 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: Int(argmax))
    var bufSize = Int(argmax)
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buf, &bufSize, nil, 0) == 0 else { return nil } // errno 22 si autre user
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = MemoryLayout<Int32>.size
    var execBytes: [UInt8] = []
    while i < bufSize, buf[i] != 0 { execBytes.append(buf[i]); i += 1 }   // exec_path
    while i < bufSize, buf[i] == 0 { i += 1 }                              // bourrage
    var strings: [String] = []
    var current: [UInt8] = []
    while i < bufSize {
        if buf[i] == 0 {
            if current.isEmpty { break }                                   // double NUL = fin
            strings.append(String(decoding: current, as: UTF8.self)); current = []
        } else { current.append(buf[i]) }
        i += 1
    }
    var env: [String: String] = [:]
    for e in strings.dropFirst(argc) {
        if let eq = e.firstIndex(of: "=") {
            env[String(e[..<eq])] = String(e[e.index(after: eq)...])
        }
    }
    return ProcArgs(execPath: String(decoding: execBytes, as: UTF8.self),
                    argv: Array(strings.prefix(argc)), env: env)
}
```

### 2.3 Le raccourci décisif : `npm_config_user_agent` dans l'environnement

Test réel sur le process Expo qui tournait sur cette machine (pid 57034) **[VÉRIFIÉ]** :

```
argv=node /Users/bastien/Documents/dune/apps/mobile/node_modules/.bin/../expo/bin/cli start
env : 289 variables, dont :
  npm_lifecycle_event=dev:go
  npm_lifecycle_script=expo start
  npm_config_user_agent=pnpm/9.15.0 npm/? node/v22.18.0 darwin arm64
```

Conséquences majeures pour les tables de détection :
- **Package runner** : `npm_config_user_agent` commence par `npm/`, `pnpm/`, `yarn/` ou `bun/` — détection **directe et fiable** de npm/pnpm/yarn/bun sans heuristique sur la chaîne de process parents. (Variable posée par les quatre runners quand ils exécutent un script — comportement standard documenté de npm et repris par les autres ; **[VÉRIFIÉ pour pnpm ici, HYPOTHÈSE à confirmer pour npm/yarn/bun en implémentation]**.)
- **Script lancé** : `npm_lifecycle_script`/`npm_lifecycle_event` donnent la commande réelle (`expo start`, `next dev`…), plus lisible que l'argv désaliasé.
- Fallback si le serveur n'a pas été lancé via un package runner : remonter la chaîne `pbi_ppid` (2–3 niveaux max) et regarder le nom des parents (`npm`, `node …/yarn.js`, etc.). **[HYPOTHÈSE : chaîne parent à tester ; certains runners `exec` le process enfant et disparaissent]**

### 2.4 Tables de détection

Entrées disponibles : `basename(execPath)`, `argv` complet, `cwd`, `env`. Règles évaluées dans l'ordre, la première qui matche gagne. La détection de framework prime sur le runtime (affichage « Next.js » plutôt que « Node »).

**Frameworks** (périmètre AgentPeek : Next.js, Vite, Astro, Wrangler, Storybook, Playwright, serveurs statiques) :

| Framework | Règle argv (jointure des éléments) | Confirmation cwd (optionnelle) | Port par défaut |
|---|---|---|---|
| Next.js | un élément se termine par `/next` ou `next` suivi de `dev`/`start`, ou contient `next/dist/bin/next` | `next.config.{js,mjs,ts}` existe | 3000 |
| Vite | élément `vite` ou contient `vite/bin/vite.js` ; aussi `node_modules/.bin/vite` | `vite.config.{js,ts,mts}` | 5173 (hors plage ! voir note) |
| Astro | élément `astro` + `dev`/`preview`, ou contient `astro/astro.js` | `astro.config.{mjs,ts}` | 4321 |
| Wrangler | élément `wrangler` + `dev` (ou `pages`) | `wrangler.{toml,jsonc}` | 8787 |
| Storybook | élément `storybook` ou contient `storybook/bin` ou `@storybook` | `.storybook/` existe | 6006 |
| Playwright | élément contient `playwright` (`show-report`, `test --ui`) | `playwright.config.{ts,js}` | 9323 |
| Serveur statique | `serve`, `http-server`, `live-server`, `python(3) -m http.server`, `php -S`, `caddy`, `miniserve` | — | variés |

> **Note plage de ports** : Vite (5173) est dans la plage 3000–9999, mais un `vite --port 2999` sortirait du scan. La plage 3000–9999 est le contrat produit d'AgentPeek, on la garde telle quelle.

**Runtimes** (à partir de `basename(execPath)` d'abord, puis heuristiques) :

| Runtime | Règle |
|---|---|
| Node | basename `node` (attention aux chemins nvm/volta/fnm — se fier au basename, pas au chemin) **[VÉRIFIÉ : `~/.nvm/versions/node/v22.18.0/bin/node`]** |
| Bun | basename `bun` ou `bunx` |
| Deno | basename `deno` |
| Python | basename matche `python(\d(\.\d+)?)?` ; ou exec dans `…/venv/bin/` |
| Ruby | basename `ruby`, ou `puma`, `rails`, `unicorn` dans argv |
| Rust | binaire compilé : `execPath` contient `/target/debug/` ou `/target/release/`, ou `Cargo.toml` dans cwd **[HYPOTHÈSE : heuristique, faux négatifs possibles pour un binaire installé]** |
| Go | `execPath` contient `/go-build` (cas `go run`, binaire dans le cache) ou `$GOPATH/bin`, ou `go.mod` dans cwd **[HYPOTHÈSE idem]** |

**Dossier projet affiché** : `cwd` du process (vérifié pertinent : `caddy` → `~/Documents/dune`, Expo → `~/Documents/dune/apps/mobile`). Cas dégradés observés : les apps GUI ont `cwd=/` → afficher alors le nom de l'app depuis `execPath`. **[VÉRIFIÉ]**

**Uptime** : `Date.now - pbi_start_tvsec` — formaté « 2m », « 3h », « 5d ». **[VÉRIFIÉ]**

**Cache** : l'identification (argv/cwd/env) est immuable pour un `(pid, start_time)` donné → la calculer une seule fois par process découvert et la mettre en cache ; seuls l'existence du process et ses sockets sont re-scannés à chaque tick.

---

## 3. Arrêt de serveurs (« Stop server »)

### 3.1 Séquence recommandée

1. **Re-valider l'identité** juste avant d'agir : re-lire `proc_bsdinfo` du PID et vérifier que `pbi_start_tvsec/usec` **et** `proc_pidpath` correspondent au snapshot affiché à l'utilisateur. Un PID peut être réutilisé par le système entre le scan et le clic — c'est LE garde-fou anti-catastrophe. **[VÉRIFIÉ : start time disponible ; réutilisation de PID = comportement documenté d'XNU]**
2. `kill(pid, SIGTERM)` — arrêt propre (les serveurs dev Node/Vite/Next l'honorent).
3. Attendre jusqu'à **3 s** en sondant toutes les 200 ms : `kill(pid, 0) == -1 && errno == ESRCH` → terminé.
4. Sinon `kill(pid, SIGKILL)`, re-sonder 1 s, puis rafraîchir le scan.

### 3.2 Garde-fous (tous appliqués, dans cet ordre)

```swift
enum KillGuardError: Error { case pidTooLow, notOurUid, identityChanged, isOurself, isAncestor }

func validateKillTarget(_ snapshot: ServerSnapshot) throws {
    // 1. Jamais de PID système. Le seuil 100 couvre launchd (1) et les daemons précoces.
    guard snapshot.pid >= 100 else { throw KillGuardError.pidTooLow }
    // 2. Jamais soi-même ni un ancêtre (le cas « AgentDash lancé par un script » existe).
    guard snapshot.pid != getpid(), !isAncestorOfSelf(snapshot.pid) else { throw KillGuardError.isAncestor }
    // 3. Uniquement les process de l'utilisateur courant.
    var info = proc_bsdinfo()
    let r = proc_pidinfo(snapshot.pid, PROC_PIDTBSDINFO, 0, &info,
                         Int32(MemoryLayout<proc_bsdinfo>.size))
    guard r == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == getuid()
        else { throw KillGuardError.notOurUid }
    // 4. Anti-réutilisation de PID : même start time + même exécutable qu'au moment de l'affichage.
    guard info.pbi_start_tvsec == snapshot.startSec,
          info.pbi_start_tvusec == snapshot.startUsec,
          execPath(pid: snapshot.pid) == snapshot.execPath
        else { throw KillGuardError.identityChanged }
}
```

- **Confirmation UI** : clic « Stop » → second tap de confirmation (comportement AgentPeek observé dans la doc : « tap de confirmation dans la menu bar »). Dans le panel : bouton qui passe en état « Confirm? » 3 s.
- Ne **jamais** utiliser `killpg` ni tuer le groupe : uniquement le PID affiché. Si le serveur a des workers orphelins, un scan suivant les montrera et l'utilisateur pourra les arrêter individuellement.
- `kill()` vers un process d'un autre utilisateur échouerait de toute façon avec `EPERM` — mais le garde-fou 3 évite même la tentative. **[VÉRIFIÉ en principe — sémantique POSIX standard]**

---

## 4. IPC hooks ↔ app

### 4.1 Architecture retenue : socket UNIX + NDJSON, une connexion par événement

```
Claude Code / Cursor (agent)
   └─ spawn → agentdash-hook (binaire Swift, ~56 Ko)       [côté hook]
                 │  connect() sur ~/…/agentdash.sock
                 │  écrit 1 ligne JSON (l'événement, stdin du hook + méta)
                 │  attend 1 ligne JSON (la décision) ou timeout
                 ▼
        AgentDash.app — NWListener (Network.framework)      [côté app]
```

**Pourquoi un socket UNIX plutôt que XPC / CFMessagePort / fichiers ?**
- XPC « service » exige que le client soit dans le même bundle ou passe par un service launchd nommé — lourd et fragile pour un binaire lancé par un CLI tiers. **[VÉRIFIÉ en principe — modèle XPC documenté]**
- CFMessagePort local est legacy et borné en taille de message pratique.
- Fichiers + FSEvents : latence et pas de réponse synchrone (or la décision de permission doit revenir au hook).
- Le socket UNIX donne : bidirectionnel, synchrone, contrôle d'accès par permissions du fichier, et **la corrélation requête/réponse est gratuite** — une connexion = une requête ; la réponse revient sur la même connexion. Pas besoin d'ID de corrélation dans le protocole (on en met un quand même pour les logs).

**Test réel Network.framework** **[VÉRIFIÉ, compilé et exécuté]** :

```
listener: ready
serveur a reçu : {"hook_event_name":"PreToolUse"}
client a reçu : {"decision":"allow"} — aller-retour 0.65 ms
--- socket absent (app fermée) :
waiting en 0.3 ms : POSIXErrorCode(rawValue: 2): No such file or directory
```

Deux faits mesurés à retenir :
1. **Aller-retour complet 0,65 ms** — l'IPC est invisible dans la latence perçue.
2. **Piège vérifié** : quand le fichier socket n'existe pas, `NWConnection` ne passe **pas** en `.failed` mais en **`.waiting`** (avec `ENOENT`) et réessaierait indéfiniment. Le hook doit traiter `.waiting` comme un échec immédiat (app fermée) et basculer sur le comportement par défaut.

### 4.2 Côté app : listener

```swift
import Network

final class HookServer {
    private var listener: NWListener?
    static let socketURL: URL = {
        // ~/Library/Application Support/AgentDash/agentdash.sock
        // Limite sun_path = 104 octets [VÉRIFIÉ : 68 octets ici via $TMPDIR ; ~66 pour App Support].
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var url = dir.appendingPathComponent("agentdash.sock")
        if url.path.utf8.count >= 100 {   // garde-fou : replier sur $TMPDIR (court, par-utilisateur)
            url = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash.sock")
        }
        return url
    }()

    func start() throws {
        try? FileManager.default.removeItem(at: Self.socketURL)  // socket périmé d'un crash précédent
        let params = NWParameters.tcp                            // transport stream ; l'endpoint le rend "unix"
        params.requiredLocalEndpoint = NWEndpoint.unix(path: Self.socketURL.path)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                // seul le propriétaire peut se connecter (write requis pour connect())
                chmod(Self.socketURL.path, 0o600)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buffer = Data()
        func receiveLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, err in
                if let data { buffer.append(data) }
                if let nl = buffer.firstIndex(of: 0x0A) {          // NDJSON : 1 ligne = 1 événement
                    let line = buffer[..<nl]
                    self.dispatchEvent(line, reply: { decision in  // rappelée plus tard (décision user)
                        var out = decision; out.append(0x0A)
                        conn.send(content: out, completion: .contentProcessed { _ in
                            conn.cancel()                          // 1 connexion = 1 requête
                        })
                    })
                } else if done || err != nil { conn.cancel() } else { receiveLoop() }
            }
        }
        receiveLoop()
    }
}
```

Sécurité : dossier `0700` + socket `0600` → seul l'utilisateur courant peut se connecter (permissions POSIX standard des sockets UNIX ; **[VÉRIFIÉ en principe, à tester en implémentation]**). Si on veut plus fort (vérifier le PID pair via `LOCAL_PEERCRED`), il faudrait des sockets BSD bruts — Network.framework n'expose pas le fd — jugé non nécessaire. **[HYPOTHÈSE]**

### 4.3 Côté hook : le binaire embarqué

**Mesures réelles du prototype** (lit stdin JSON, répond JSON) **[VÉRIFIÉ]** :
- Taille du binaire Swift compilé `-O` : **56 Ko** (lié dynamiquement aux libs système, rien à embarquer).
- Latence de démarrage process complet (spawn + exécution + exit) : **min 2,3 ms, médiane 2,7 ms, max 4,2 ms** sur 30 runs. Invisible pour l'agent.

Logique du hook (pseudo-code du flux, à écrire avec des sockets BSD bruts ou Network.framework — les deux conviennent ; BSD brut est plus simple à raisonner pour un client one-shot) :

```swift
// agentdash-hook — flux nominal
// 1. lire stdin en entier (l'événement JSON fourni par Claude Code / Cursor)
// 2. l'envelopper : {"v":1,"id":"<uuid>","source":"claude"|"cursor","event":<stdin>,
//                    "term_program":ENV["TERM_PROGRAM"],"pid":getppid(),"cwd":ENV["PWD"]}
//    → TERM_PROGRAM hérité de l'agent identifie le terminal hôte. [VÉRIFIÉ : hérité, "vscode" sous Cursor]
// 3. connect() au socket. Échec immédiat (ENOENT/ECONNREFUSED) ou .waiting → FALLBACK.
// 4. envoyer la ligne, attendre la réponse avec un deadline :
//    - événements "décision" (permission/plan/question) : deadline LONG (55 s),
//      c'est l'agent qui a le vrai timeout de hook (Claude Code : 60 s par défaut
//      [HYPOTHÈSE — chiffre à confirmer par l'agent de recherche hooks]) ;
//    - événements "notification" (Stop, PostToolUse, SessionStart…) : fire-and-forget,
//      deadline 500 ms sur le send, pas de réponse attendue.
// 5. réponse reçue → l'écrire telle quelle sur stdout, exit 0.
// FALLBACK (app fermée, timeout, erreur JSON) : exit 0 SANS RIEN sur stdout
//    → l'agent applique son comportement par défaut (prompt normal dans le terminal).
//    Ne JAMAIS exit ≠ 0 sur erreur interne : un code d'erreur pourrait bloquer l'outil côté agent.
```

Points de conception :
- **Le hook ne décide jamais** : soit il relaie la décision de l'app, soit il se tait (sortie vide = « pas d'avis », l'agent continue son flux normal). L'utilisateur ne perd jamais la main si AgentDash est fermé — il voit alors le prompt classique dans son terminal.
- Côté app, si l'utilisateur ne répond pas avant ~50 s à une permission relayée, répondre explicitement « pas de décision » (sortie vide) plutôt que laisser l'agent tuer le hook au timeout — la transition vers le prompt terminal est alors propre. **[HYPOTHÈSE sur le comportement exact de l'agent au timeout de hook]**
- Événements > 64 Ko possibles (gros `tool_input`) : lire/écrire en boucle jusqu'au `\n`, pas de buffer fixe.

### 4.4 Chemin stable du binaire et installation dans settings.json / hooks.json

Deux options :

| Option | Avantages | Inconvénients |
|---|---|---|
| (A) Référencer le binaire **dans le bundle** : `/Applications/AgentDash.app/Contents/Helpers/agentdash-hook` | Toujours à jour avec l'app ; zéro copie | Chemin cassé si l'app est déplacée/renommée ; espaces dans le chemin si l'app va ailleurs |
| (B) **Copier** le binaire vers `~/.agentdash/bin/agentdash-hook` au lancement (et à chaque mise à jour, comparaison de version/hash) | Chemin court, sans espace, stable même si l'app bouge ; survit à un déplacement de l'app (le hook échoue alors proprement en fallback si l'app ne tourne pas) | Copie à maintenir (l'app la resynchronise à chaque démarrage — c'est le « installe **et répare** » du toggle AgentPeek) |

**Recommandation : (B)**, avec l'onglet Doctor qui vérifie : existence du binaire, hash attendu, entrée présente dans `~/.claude/settings.json` et `~/.cursor/hooks.json`, socket joignable. Le statut « Ready » = les quatre checks au vert. La commande inscrite dans les configs des agents est alors sans espace ni quoting : `~/.agentdash/bin/agentdash-hook` (+ un argument de source, p. ex. `--source claude`). **[HYPOTHÈSE : la syntaxe exacte des entrées de hooks relève de la recherche dédiée hooks ; contrainte de notre côté : chemin absolu court, exécutable, sans dépendance d'environnement]**

Notarisation : le binaire copié hors du bundle reste signé Developer ID (la signature est dans le Mach-O) — pas de problème Gatekeeper pour une exécution par un process CLI. **[HYPOTHÈSE raisonnable, à valider avec une build signée]**

---

## 5. Tail des transcripts `~/.claude/projects`

### 5.1 État des lieux vérifié sur cette machine

- Arborescence réelle : `~/.claude/projects/<projet-encodé>/<session-uuid>.jsonl`, **plus** des sous-arborescences `…/<session-uuid>/subagents/workflows/<wf-id>/agent-<id>.jsonl` — la surveillance doit donc être **récursive**. **[VÉRIFIÉ]**
- Volumes observés : 2,1 Mo au total ici, plus gros fichier 544 Ko ; 176 lignes, **ligne max 70 007 octets**, moyenne 3 163 octets. Des sessions longues de plusieurs dizaines de Mo sont plausibles chez de gros utilisateurs. **[VÉRIFIÉ pour les chiffres locaux ; HYPOTHÈSE pour les tailles extrêmes]**
- Première ligne d'un transcript : objets JSON `{"type":"queue-operation",…}` puis `{"parentUuid":…,"type":"user","message":{…}}` — parsing ligne à ligne classique. **[VÉRIFIÉ]**

### 5.2 FSEvents vs DispatchSource

| | FSEvents | DispatchSource (kqueue `EVFILT_VNODE`) |
|---|---|---|
| Récursivité | **Oui**, un seul stream pour tout `~/.claude/projects` **[VÉRIFIÉ : événement reçu pour `sub/agent.jsonl`]** | Non — un fd ouvert **par fichier** surveillé |
| Nouveaux fichiers | Détectés (création = événement) **[VÉRIFIÉ]** | Non détectés (il faut déjà connaître le fichier) |
| Latence | Coalescence configurable ; **200 ms testés, fonctionnels** **[VÉRIFIÉ]** | Quasi immédiate |
| Coût | 1 stream, indépendant du nombre de fichiers | 1 fd + 1 source par fichier ; fuite de fd si mal géré |

**Recommandation : FSEvents seul**, latence **0,3 s**, flags `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`. Les hooks fournissent déjà le temps réel « dur » (permissions) ; le tail des transcripts alimente tokens/timeline, pour lesquels 300 ms sont imperceptibles. Option d'optimisation ultérieure : DispatchSource ciblé sur le fichier de la session active si un besoin < 100 ms apparaît. **[HYPOTHÈSE : le hybride est décrit mais non testé]**

Sortie du test réel (latence 0,2 s, création + appends + fichier dans un sous-dossier) **[VÉRIFIÉ]** :

```
event: …/agentdash-fsevents-test                       flags=0x28100  (ItemIsDir|ItemXattrMod|ItemCreated)
event: …/session.jsonl.sb-a16e7522-wsIFKL              flags=0x18900  (fichier temporaire d'écriture atomique !)
event: …/session.jsonl                                 flags=0x11800  (ItemIsFile|ItemModified|ItemRenamed)
event: …/sub/agent.jsonl                               flags=0x11800  (récursivité confirmée)
```

Leçons de ce test : (1) des fichiers temporaires `.sb-*` apparaissent lors d'écritures atomiques → **filtrer sur le suffixe `.jsonl` exact** ; (2) les flags sont coalescés et peu fiables → **ne jamais raisonner sur les flags**, toujours répondre à un événement par un `stat()` + lecture incrémentale ; (3) traiter `kFSEventStreamEventFlagMustScanSubDirs` (débordement de la file d'événements) par un rescan complet.

### 5.3 Lecture incrémentale avec offsets

```swift
final class TranscriptTailer {
    private var offsets: [String: UInt64] = [:]      // chemin → offset validé (fin de la dernière ligne complète)
    private var partial: [String: Data] = [:]        // chemin → fragment de ligne en attente

    /// Appelé pour chaque chemin *.jsonl signalé par FSEvents (après debounce).
    func drain(path: String, onLine: (Data) -> Void) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var offset = offsets[path] ?? 0
        if size < offset {                            // troncature / rotation / réécriture
            offset = 0; partial[path] = nil
        }
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        var buf = partial[path] ?? Data()
        while let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty {
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if !line.isEmpty { onLine(line) }     // JSONDecoder par ligne ; erreur → ignorer la ligne
            }
        }
        partial[path] = buf                           // fragment final : une ligne peut arriver en 2 write()
        offsets[path] = size - UInt64(buf.count)      // on ne « valide » que jusqu'à la dernière ligne complète
    }
}
```

- **Debounce** : la latence FSEvents (0,3 s) fait déjà le gros du travail ; ajouter côté app une coalescence par chemin (max 1 drain / 250 ms / fichier) pour les rafales.
- **Persistance des offsets** : inutile de les écrire sur disque. Au lancement, l'app fait de toute façon un chargement initial (elle doit reconstruire l'état des sessions récentes) : parser intégralement les `.jsonl` dont `mtime` < 48 h, et pour les anciens, poser `offset = taille` sans parser. À 2 Mo locaux c'est instantané ; même 100 Mo se lisent en streaming en < 1 s sur SSD Apple. **[VÉRIFIÉ pour le volume local ; HYPOTHÈSE pour l'extrapolation]**
- **Lignes énormes** (70 Ko observés, images base64 possibles) : le buffer par fragments gère naturellement ; prévoir un plafond de sécurité (p. ex. 10 Mo/ligne → abandon de la ligne) contre un fichier corrompu.
- **Sessions supprimées** (`ItemRemoved` ou fichier absent au `stat`) : purger `offsets[path]` et `partial[path]`.

---

## 6. Raccourcis clavier globaux (⌘A / ⌘N / ⌥A / ⌥T pendant un prompt)

### 6.1 Comparaison des trois mécanismes

| | Carbon `RegisterEventHotKey` | `CGEventTap` | `NSEvent.addGlobalMonitorForEvents` |
|---|---|---|---|
| Permission requise | **Aucune** | **Accessibility (TCC)** — inacceptable pour ce produit | Aucune |
| Consomme l'événement | **Oui** (l'app au premier plan ne le reçoit pas) | Oui (si tap actif) | **Non** — ⌘A déclencherait AUSSI « Tout sélectionner » dans l'app au premier plan → inutilisable |
| Détection de conflit | `RegisterEventHotKey` retourne un `OSStatus` (`eventHotKeyExistsErr = -9878` si déjà pris) | n/a | n/a |
| État de l'API | Carbon HIToolbox, non dépréciée pour les hotkeys, utilisée par tout l'écosystème (MASShortcut, HotKey, Raycast…) | Supportée | Supportée |

**Recommandation : `RegisterEventHotKey`**, exactement parce qu'il consomme l'événement sans permission TCC. **[VÉRIFIÉ en principe — API du SDK local présente et sémantique documentée ; comportement à confirmer par test UI en implémentation]**

### 6.2 Stratégie : enregistrement éphémère

**N'enregistrer les hotkeys QUE pendant qu'un prompt (permission/plan/question) est affiché**, et les désenregistrer dès la décision prise ou le prompt disparu. Raisons :
- ⌘A enregistré en permanence volerait « Tout sélectionner » à tout le système en continu — inacceptable.
- Même pendant un prompt, ⌘A est confisqué (l'utilisateur qui sélectionne du texte dans son éditeur pendant qu'un prompt attend déclencherait « Allow ») : c'est le compromis produit d'AgentPeek. À documenter dans l'onglet Shortcuts. Le panel non-activating n'a pas besoin d'être key : la hotkey est globale.
- En cas d'échec d'enregistrement (`OSStatus != noErr`), remonter l'avertissement dans Settings → Shortcuts (comportement AgentPeek documenté) et laisser les boutons cliquables du panel comme voie nominale.

```swift
import Carbon.HIToolbox

final class PromptHotKeys {
    enum Action: UInt32 { case allow = 1, deny = 2, alwaysAllow = 3, openTerminal = 4 }
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    var onAction: ((Action) -> Void)?

    /// À appeler quand un prompt devient visible. Retourne les actions dont l'enregistrement a échoué.
    @discardableResult
    func register() -> [Action: OSStatus] {
        installHandlerIfNeeded()
        var failures: [Action: OSStatus] = [:]
        let specs: [(Action, UInt32, UInt32)] = [
            (.allow,        keyCode(for: "a") ?? UInt32(kVK_ANSI_A), UInt32(cmdKey)),
            (.deny,         keyCode(for: "n") ?? UInt32(kVK_ANSI_N), UInt32(cmdKey)),
            (.alwaysAllow,  keyCode(for: "a") ?? UInt32(kVK_ANSI_A), UInt32(optionKey)),
            (.openTerminal, keyCode(for: "t") ?? UInt32(kVK_ANSI_T), UInt32(optionKey)),
        ]
        for (action, code, mods) in specs {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x41444B59) /* 'ADKY' */, id: action.rawValue)
            let st = RegisterEventHotKey(code, mods, hkID, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) } else { failures[action] = st }
        }
        return failures
    }

    /// À appeler dès que le prompt disparaît (décision prise, session terminée, panel fermé).
    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event!, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<PromptHotKeys>.fromOpaque(userData!).takeUnretainedValue()
            if let action = Action(rawValue: hkID.id) { me.onAction?(action) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
```

### 6.3 Piège AZERTY (pertinent : machine française)

`kVK_ANSI_A` (= 0) est un code de touche **positionnel** : sur un clavier AZERTY, la touche 0 tape « Q ». Enregistrer `kVK_ANSI_A` en dur ferait que « ⌘A » réagirait en réalité à ⌘Q-physique. **Résoudre le keycode à partir du caractère via la disposition courante** (`TISCopyCurrentKeyboardLayoutInputSource` + `kTISPropertyUnicodeKeyLayoutData` + `UCKeyTranslate`, en itérant les 128 keycodes pour trouver celui qui produit « a »), et ré-enregistrer sur notification de changement de disposition (`kTISNotifySelectedKeyboardInputSourceChanged`). C'est le rôle du `keyCode(for:)` du code ci-dessus. **[VÉRIFIÉ en principe — mécanique standard des layouts macOS ; implémentation `UCKeyTranslate` à écrire et tester]**

---

## 7. Divers

### 7.1 Launch at login — `SMAppService` (macOS 13+)

```swift
import ServiceManagement

func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled { try SMAppService.mainApp.register() }
    else { try SMAppService.mainApp.unregister() }
}
var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
```

- L'app apparaît dans Réglages Système → Général → Ouverture. L'utilisateur peut la désactiver là-bas → re-lire `status` à chaque affichage des Settings plutôt que le mettre en cache.
- `register()` peut lancer `SMAppService.Error` si l'app n'est pas dans `/Applications` (build de dev depuis DerivedData) → afficher un message doux plutôt que crasher. **[HYPOTHÈSE sur les cas d'échec exacts, API vérifiée dans le SDK]**

### 7.2 Notifications — `UNUserNotificationCenter`

**Contrainte vérifiée en principe** : `UNUserNotificationCenter.current()` exige un vrai bundle d'app signé (crash `bundleProxyForCurrentProcess is nil` depuis un exécutable nu). Tous les tests de notifications devront se faire sur l'app bundlée. **[HYPOTHÈSE à confirmer dès le squelette d'app]**

```swift
import UserNotifications

enum NotifCategory: String { case permission = "PERMISSION_REQUEST", budget = "BUDGET_ALERT",
                                  stuck = "STUCK_SESSION", complete = "TASK_COMPLETE" }

func setupNotifications() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    let granted = try await center.requestAuthorization(options: [.alert, .sound])
    // Actions inline sur la notification de permission (miroir de ⌘A/⌘N) :
    let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow")
    let deny  = UNNotificationAction(identifier: "DENY",  title: "Deny", options: [.destructive])
    let permission = UNNotificationCategory(identifier: NotifCategory.permission.rawValue,
                                            actions: [allow, deny], intentIdentifiers: [])
    center.setNotificationCategories([permission,
        UNNotificationCategory(identifier: NotifCategory.budget.rawValue,  actions: [], intentIdentifiers: []),
        UNNotificationCategory(identifier: NotifCategory.stuck.rawValue,   actions: [], intentIdentifiers: []),
        UNNotificationCategory(identifier: NotifCategory.complete.rawValue, actions: [], intentIdentifiers: [])])
    return granted
}

func post(_ category: NotifCategory, title: String, body: String, sound: Bool) async throws {
    let content = UNMutableNotificationContent()
    content.title = title; content.body = body
    content.sound = sound ? .default : nil
    content.categoryIdentifier = category.rawValue
    try await UNUserNotificationCenter.current()
        .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}
// « Test notification » des Settings = post(.complete, …) immédiat.
```

- Le delegate (`userNotificationCenter(_:didReceive:)`) reçoit `ALLOW`/`DENY` → même chemin de code que les hotkeys.
- `interruptionLevel = .timeSensitive` exige un entitlement dédié — rester en `.active` par défaut. **[VÉRIFIÉ en principe]**
- Toggle maître + sons par catégorie : côté app (ne pas poster), pas côté système.

### 7.3 `NSWorkspace` — ouvrir Finder / Terminal / URL

```swift
import AppKit

// Ouvrir l'URL d'un serveur local :
NSWorkspace.shared.open(URL(string: "http://localhost:3000")!)

// Quick Routes — ouvrir un dossier dans le Finder :
NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.claude/skills", isDirectory: true))
// … ou révéler un fichier précis (settings.json) sélectionné dans sa fenêtre Finder :
NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")])

// ⌥T — ouvrir le Terminal (au cwd de la session si connu) :
func openTerminal(at directory: String?, termProgram: String?) {
    // Le hook transmet TERM_PROGRAM hérité de l'agent [VÉRIFIÉ : "vscode" sous Cursor,
    // "Apple_Terminal" / "iTerm.app" / "ghostty" / "WarpTerminal" selon l'hôte].
    let bundleID: String
    switch termProgram {
    case "iTerm.app":     bundleID = "com.googlecode.iterm2"
    case "WarpTerminal":  bundleID = "dev.warp.Warp-Stable"
    case "ghostty":       bundleID = "com.mitchellh.ghostty"
    case "vscode":        bundleID = "com.todesktop.230313mzl4w4u92" // Cursor ; sinon com.microsoft.VSCode [HYPOTHÈSE : distinguer via __CFBundleIdentifier hérité]
    default:              bundleID = "com.apple.Terminal"           // [VÉRIFIÉ : /System/Applications/Utilities/Terminal.app]
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
    if let directory {
        NSWorkspace.shared.open([URL(fileURLWithPath: directory, isDirectory: true)],
                                withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    } else {
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
    }
}

// Copier l'URL d'un serveur :
NSPasteboard.general.clearContents()
NSPasteboard.general.setString("http://localhost:3000", forType: .string)
```

Quick Routes : filtrer par `FileManager.default.fileExists(atPath:)` avant affichage (« seuls les chemins existants s'affichent »). Sur cette machine : `~/.claude/{skills,plugins,projects,settings.json}` existent tous ; `~/.cursor/hooks.json` n'existe pas (sera créé par notre installeur de hooks). **[VÉRIFIÉ]**

### 7.4 Sobriété : auto-surveillance RAM/CPU via `task_info`

Testé et fonctionnel **[VÉRIFIÉ]** (le prototype CLI mesure 1 Mo de `phys_footprint` — c'est la métrique du Moniteur d'activité, pas `resident_size`) :

```swift
struct SelfStats { let footprintMB: Double; let cpuSeconds: Double }

func selfStats() -> SelfStats? {
    var vm = task_vm_info_data_t()
    var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr1 = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
        }
    }
    var times = task_thread_times_info_data_t()
    var tCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr2 = withUnsafeMutablePointer(to: &times) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(tCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &tCount)
        }
    }
    guard kr1 == KERN_SUCCESS, kr2 == KERN_SUCCESS else { return nil }
    let cpu = Double(times.user_time.seconds) + Double(times.user_time.microseconds) / 1e6
            + Double(times.system_time.seconds) + Double(times.system_time.microseconds) / 1e6
    return SelfStats(footprintMB: Double(vm.phys_footprint) / 1_048_576, cpuSeconds: cpu)
}
```

Usage : échantillonner toutes les 30 s ; `%CPU = Δ cpuSeconds / 30`. Budgets proposés (AgentPeek annonce des « réductions RAM/CPU » en v0.2.6-0.2.7, sans chiffres publics) : **< 150 Mo de footprint, < 1 % CPU au repos, < 5 % en pic d'activité** — dépassement persistant → signal dans l'onglet Doctor. **[HYPOTHÈSE : budgets à calibrer sur l'app réelle]**

---

## 8. Décisions d'implémentation recommandées

| # | Sujet | Décision | Statut |
|---|---|---|---|
| D1 | Distribution | Hors App Store, Developer ID + notarisation ; **pas d'App Sandbox** (incompatible avec libproc/kill/hooks) | Ferme |
| D2 | Scan de ports | **libproc** (`proc_listpids(PROC_UID_ONLY)` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, état `TSI_S_LISTEN`) ; `lsof -F` seulement comme vérification croisée dans Doctor | Ferme (mesuré : 1,3 ms/scan) |
| D3 | Polling serveurs | 2 s panel ouvert (+ scan immédiat à l'ouverture), 10 s sinon ; identité de ligne `(pid, port)`, fusion v4/v6 | Ferme |
| D4 | Identification | `proc_pidpath` + `KERN_PROCARGS2` (argv **et env**) + `PROC_PIDVNODEPATHINFO` (cwd) + `pbi_start_tvsec` (uptime) ; package runner via `npm_config_user_agent` ; cache par `(pid, start_time)` | Ferme |
| D5 | Stop serveur | SIGTERM → 3 s → SIGKILL ; garde-fous : PID ≥ 100, uid == user, re-validation `(start_time, execPath)` anti-réutilisation de PID, jamais soi-même/ancêtre, confirmation UI en 2 temps | Ferme |
| D6 | IPC hooks | Socket UNIX `~/Library/Application Support/AgentDash/agentdash.sock` (repli `$TMPDIR` si > 100 octets), `NWListener`/`NWConnection` endpoint `.unix`, dossier 0700 + socket 0600 ; protocole NDJSON, **1 connexion = 1 requête** (corrélation implicite) | Ferme (aller-retour mesuré 0,65 ms) |
| D7 | Hook côté agent | Binaire Swift ~56 Ko, spawn médian 2,7 ms ; **copié** vers `~/.agentdash/bin/agentdash-hook` (resynchronisé à chaque lancement = « réparer ») ; `.waiting` sur le connect = app fermée → **exit 0 sans sortie** (fallback : comportement par défaut de l'agent) ; jamais d'exit ≠ 0 | Ferme sur le canal ; syntaxe des entrées settings.json/hooks.json → recherche hooks |
| D8 | Tail transcripts | FSEvents unique récursif sur `~/.claude/projects`, latence 0,3 s, `FileEvents|NoDefer` ; filtrer `*.jsonl` ; lecture incrémentale par offsets en mémoire + buffer de ligne partielle ; troncature (size < offset) → relire de 0 ; au lancement, parse complet si mtime < 48 h sinon offset = taille | Ferme |
| D9 | Hotkeys | `RegisterEventHotKey` (aucune permission TCC, consomme l'événement) ; **enregistrées uniquement pendant qu'un prompt est visible** ; keycodes résolus par caractère via `UCKeyTranslate` (AZERTY !) ; échec `OSStatus` → avertissement dans Settings → Shortcuts | Ferme sur le mécanisme ; test UI à faire |
| D10 | Login item | `SMAppService.mainApp` (macOS 13+), relire `status` à chaque affichage | Ferme |
| D11 | Notifications | `UNUserNotificationCenter`, 4 catégories (permission avec actions Allow/Deny, budget, stuck, complete), sons optionnels, bouton test = post immédiat | Ferme |
| D12 | Sobriété | Auto-mesure `task_info` (`phys_footprint` + `TASK_THREAD_TIMES_INFO`) toutes les 30 s, budgets < 150 Mo / < 1 % CPU repos, alerte Doctor | Budgets à calibrer |

---

## 9. Questions ouvertes (à valider en implémentation)

1. **Syntaxe exacte des hooks Claude Code et Cursor** (noms d'événements, format de réponse attendu sur stdout, timeout par hook — 60 s par défaut chez Claude Code à confirmer, sémantique des exit codes) — couverte par la recherche dédiée hooks ; ce document ne fige que le contrat du canal IPC.
2. **Comportement de l'agent quand le hook dépasse son timeout** (prompt terminal propre ou erreur affichée ?) — détermine si l'app doit répondre « pas de décision » à ~50 s.
3. **`npm_config_user_agent` posé par npm/yarn/bun** (vérifié seulement pour pnpm ici) et survie de la variable quand le runner `exec` le process serveur.
4. **Exécution du binaire hook copié hors bundle sur une machine tierce** (Gatekeeper/quarantaine avec une build signée-notarisée réelle ; la copie via l'app ne pose pas l'attribut de quarantaine, à confirmer).
5. **`RegisterEventHotKey` depuis un `NSPanel` non-activating** : confirmer par test UI que la consommation de ⌘A fonctionne pendant que le focus est dans un terminal tiers, et mesurer les conflits (`eventHotKeyExistsErr`) avec les apps répandues (Raycast, etc.).
6. **`UNUserNotificationCenter` sur app non signée en dev** (build Xcode locale) : vérifier que la demande d'autorisation apparaît bien.
7. **Filtrage produit du scan de ports** : liste d'exclusion exacte (ControlCenter/AirPlay 5000-7000, Spotify…) vs affichage brut — comportement précis d'AgentPeek inconnu.
8. **Volumes extrêmes de transcripts** (> 100 Mo, milliers de fichiers) : valider le temps de chargement initial et, si besoin, persister les offsets sur disque.
9. **Budgets RAM/CPU réels** de l'app complète (SwiftUI + blur du notch) — les chiffres D12 sont des cibles, pas des mesures.
10. **`SMAppService` hors `/Applications`** : messages d'erreur exacts en build de dev.
