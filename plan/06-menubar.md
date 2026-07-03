# 6. Surface menu bar

> Spécification du module `MenuBarUI` (package SPM, dépend uniquement de `DashCore` — cf. `plan/01-architecture.md` §3). Rédigée le 3 juillet 2026, en conformité stricte avec `plan/01-architecture.md` (décision A4 : `NSStatusItem` AppKit, `MenuBarExtra` écarté), `plan/02-data-model.md` (stores, `UsageWindow`, `DevServer.StopState`, `AppSettings`) et `plan/research/notch-ui.md` §6 (recettes vérifiées `NSStatusItem` + `NSPopover`).
> Convention : **[VÉRIFIÉ]** = adossé aux recherches ou à la doc officielle ; **[HYPOTHÈSE — à valider]** = déduction à confirmer en implémentation (AgentPeek n'étant pas installé sur cette machine, son rendu exact n'est pas inspectable).

---

## 1. Objectif & périmètre

La menu bar est la **seconde surface UI** d'AgentDash (nom provisoire), indépendante du notch et togglable séparément. Elle offre un résumé permanent (icône + texte d'usage optionnel + compteur de serveurs optionnel + point d'attention orange) et un popover de détail avec **sections plates** : usage par agent, serveurs de dev locaux (avec confirmation d'arrêt en deux temps), raccourci vers Settings.

Sections d'`AGENTPEEK_FEATURES.md` couvertes :

| Section features | Élément repris ici |
|---|---|
| §2.2 (Surfaces UI, point 2) | surface résumé séparée : usage tokens + serveurs ; popover à sections plates ; fermeture au clic sur une autre app ; point orange « attention » quand un agent attend ; clic droit → Quit |
| §5.2 (Usage, détails) | bouton refresh usage dans le popover menu bar ; shimmer pendant le refresh ; jauges qui retiennent la dernière valeur ; `--` si jamais de valeur ; jauges batterie ; option countdown depuis 100 % |
| §6 (Serveurs locaux) | « arrêter le serveur (avec garde-fous / **tap de confirmation dans la menu bar**) » ; open URL / copy URL ; port, dossier, uptime |
| §10 General | « Toggles indépendants notch / menu bar » |
| §13 changelog | v0.1.13 « popover menu bar aplati », v0.1.20–0.1.21 « point orange menu bar », v0.2.8 « clic droit menu bar → Quit » |
| §14.3 | « Menu bar : résumé usage + serveurs, point d'attention, popover » |

**Hors périmètre de ce fichier** : le contenu détaillé des jauges d'usage (calculs des fenêtres 5 h/7 j/mensuel — fichier usage du plan), la détection des serveurs (fichier serveurs), le notch (fichier notch), la fenêtre Settings (fichier settings). Ce fichier consomme leurs stores et leurs API, il ne les redéfinit pas.

---

## 2. Exigences détaillées

### Status item (icône dans la barre de menus)

- **REQ-MBR-01 (P0)** — Un `NSStatusItem` de longueur `variableLength` est créé au démarrage si `AppSettings.menuBarEnabled == true`, et détruit (`NSStatusBar.system.removeStatusItem`) quand le réglage passe à `false`. Le changement prend effet **immédiatement**, sans redémarrage, et est **totalement indépendant** de `notchEnabled` (les 4 combinaisons on/off sont valides).
- **REQ-MBR-02 (P0)** — Le contenu du bouton est un `NSHostingView` SwiftUI (icône glyphe + texte optionnel + point d'attention), jamais un `NSImage` template seul — condition nécessaire au point orange coloré (limitation `MenuBarExtra` **[VÉRIFIÉ]** research §6.1). Hauteur de rendu 22 pt, adaptation automatique clair/sombre via `Color(nsColor: .labelColor)`.
- **REQ-MBR-03 (P1)** — Texte d'usage optionnel dans la barre : si `AppSettings.menuBarShowsUsage == true` (nouvelle clé, cf. note §7), afficher à droite de l'icône le **pourcentage de la fenêtre d'usage la plus consommée** parmi les comptes/fenêtres activés, en chiffres `monospacedDigit` (ex. `82%`). Si `countdownFrom100 == true`, afficher le restant (ex. `18%`). Si aucune valeur n'a jamais été obtenue, le texte est **masqué** (pas de `--` en barre, pour ne pas gaspiller la place). [HYPOTHÈSE — à valider : format exact d'AgentPeek non inspectable ; le choix « pire fenêtre » est une décision produit locale.]
- **REQ-MBR-04 (P0)** — Point d'attention orange : un disque de 7 pt (`.orange` système, non-template) apparaît en haut à droite de l'icône **si et seulement si** au moins une session non dismissée et `liveness == .live` est en état `waiting(*)` (helper `SessionStore.hasPendingAttention`, dans `DashCore`, partagé avec le notch). Apparition/disparition animées (`.transition(.scale.combined(with: .opacity))`, ressort). Jamais déclenché par `isStale` seul (une session lente n'est pas une session qui attend — cf. `02-data-model.md` §3.3).
- **REQ-MBR-05 (P0)** — La longueur du status item s'adapte au contenu (`variableLength`) : icône seule ≈ 28 pt, icône + texte ≈ 28 + largeur du texte. Aucun saut visuel de plus d'une frame lors du changement de texte (coalescence des mises à jour, cf. REQ-MBR-22).
- **REQ-MBR-06 (P2)** — Tooltip du bouton (`button.toolTip`) : `"AgentDash — N sessions · M waiting"` (masquer `· M waiting` si M = 0), mis à jour avec le contenu.
- **REQ-MBR-07 (P2)** — Accessibilité : `accessibilityDescription = "AgentDash"` sur le bouton ; le point orange expose la valeur VoiceOver `"attention needed"`.
- **REQ-MBR-08 (P1)** — Le status item n'est **pas** supprimable par ⌘-drag (comportement par défaut, `behavior` sans `.removalAllowed`) : l'unique source de vérité du toggle est Settings → General, aucune divergence d'état possible. [HYPOTHÈSE — à valider : comportement AgentPeek inconnu ; décision locale de simplicité.]

### Clics et menu contextuel

- **REQ-MBR-09 (P0)** — Clic gauche sur l'icône : **toggle** du popover (ouvert → fermé, fermé → ouvert). Le bouton reste surligné pendant que le popover est visible.
- **REQ-MBR-10 (P0)** — Clic droit (ou ⌃-clic gauche) : menu `NSMenu` minimal avec l'unique item **« Quit AgentDash »** (key equivalent `q`), via le pattern vérifié « assignation temporaire de `statusItem.menu` + `performClick` + remise à `nil` » (research §6.2 **[VÉRIFIÉ]**). L'action appelle `NSApp.terminate(nil)` après fermeture propre (le serveur IPC répond « pas d'avis » aux prompts en vol — fail-open, cf. `01-architecture.md` §7.1).
- **REQ-MBR-11 (P0)** — Le clic droit n'ouvre jamais le popover ; le clic gauche n'ouvre jamais le menu (le `menu` est remis à `nil` immédiatement après usage).

### Popover

- **REQ-MBR-12 (P0)** — Le popover est un `NSPopover` avec `behavior = .transient` : il se ferme automatiquement au clic n'importe où ailleurs, y compris sur une autre app (comportement AgentPeek §2.2, reproduit gratuitement — research §6.3 **[VÉRIFIÉ]**). Échap le ferme également (comportement système du transient — [HYPOTHÈSE — à valider en pratique]).
- **REQ-MBR-13 (P0)** — L'ouverture du popover ne doit **pas** activer AgentDash ni voler le focus de l'app frontale (l'utilisateur code pendant que les agents tournent). [HYPOTHÈSE — à valider : le couple status item + `NSPopover` n'active normalement pas l'app, mais le popover peut devenir key window ; si un vol de focus est constaté, plan B acté par la recherche §6.3 : petit `NSPanel` non-activant ancré sous le bouton, réutilisant le moniteur global `leftMouseDown` du notch.]
- **REQ-MBR-14 (P0)** — Contenu : **sections plates**, sans disclosure ni sous-menus (v0.1.13 « popover aplati ») dans cet ordre : ① Usage (par agent), ② Local Servers, ③ pied de page avec « Settings… ». Largeur fixe 320 pt ; hauteur auto-dimensionnée par le contenu (via `NSHostingController` + `sizingOptions = .preferredContentSize`), plafonnée à 560 pt puis scroll interne de la section serveurs.
- **REQ-MBR-15 (P0)** — Section Usage : une sous-carte par agent activé. **Claude Code** : jauges batterie « 5h » et « 7d » avec pourcentage + libellés de reset exacts (`resets in 2h 14m` pour la 5 h, `refills Sun at 3:47 PM` pour la 7 j — formats du fichier usage du plan). **Cursor** : jauge mensuelle selon la mesure choisie (`Spend/Weighted/Auto/API`) avec libellé `$12.40 of $20` quand les dollars sont connus, sinon pourcentage seul. Les jauges reprennent la même sémantique de couleur que le notch (vert → jaune → rouge, type unique `GaugeColor` de `DashCore` et fonction `gaugeColor(consumed:previous:)` — seuils 70/90 + hystérésis de 2 points, `09-token-usage.md` REQ-USG-15).
- **REQ-MBR-16 (P0)** — Bouton **refresh** (`arrow.clockwise`) dans l'en-tête de la section Usage : déclenche `UsageStore.refreshAll(manual: true)` (anti-rafale 10 s partagé avec le bouton du notch — `01-architecture.md` §5.1) ; pendant le refresh, les jauges affichent un **shimmer** (dégradé animé en overlay) et le bouton tourne. Le même état `isRefreshing` pilote le shimmer du notch : source unique dans `UsageStore`.
- **REQ-MBR-17 (P0)** — Rétention des valeurs : une jauge dont le dernier refresh a échoué **conserve** sa dernière valeur (`UsageWindow.isStale == true` → pastille d'horodatage discrète `as of 14:02`) ; `--` uniquement si aucune valeur n'a jamais été obtenue (invariant n°5 de `02-data-model.md` §8.1).
- **REQ-MBR-18 (P0)** — Section Local Servers : une ligne par `DevServer` (port, nom affiché — framework sinon runtime sinon basename —, dossier projet en secondaire, uptime), avec trois actions : **ouvrir l'URL** (navigateur par défaut), **copier l'URL** (`NSPasteboard`), **arrêter**.
- **REQ-MBR-19 (P0)** — Arrêt avec **confirmation en deux temps** (feature §6 : « tap de confirmation dans la menu bar ») : premier clic sur le bouton stop → la ligne passe en `StopState.confirming(until: now + 3 s)`, le bouton devient le texte rouge **« Confirm? »** (libellé canonique de `10-local-servers.md` REQ-SRV-31/34, cohérent avec le Kill des sessions) ; second clic dans les 3 s → `ServerStore.confirmStop(id:)` (chaîne SIGTERM → 3 s → SIGKILL avec re-validation `(pid, start_time, execPath)`, garde-fous de `01-architecture.md` §8.4) et la ligne passe `terminating` (spinner) puis disparaît (`gone`). Sans second clic, retour automatique à `none` à l'échéance.
- **REQ-MBR-20 (P0)** — Pied de page : ligne **« Settings… »** (raccourci affiché `⌘,`) qui ouvre la fenêtre Settings, **active l'app pour cette fenêtre uniquement** (`NSApp.activate`) et ferme le popover.
- **REQ-MBR-21 (P1)** — États vides et sections masquées : `claudeUsageEnabled == false` masque la carte Claude (idem Cursor) ; les deux à `false` → section Usage entièrement masquée. `serverScanEnabled == false` → section Local Servers masquée. Aucun serveur détecté → état vide canonique de `10-local-servers.md` §4.4 : `No local servers` + sous-texte `Dev servers on ports 3000–9999 will show up here.` (hauteur fixe ≈ 56 pt, pas de saut à l'apparition du premier serveur). Usage activé mais jamais de valeur → jauges `--`. Si tout est masqué, le popover contient au minimum le pied de page Settings et le texte `Enable usage or server tracking in Settings`.

### Synchronisation, rafraîchissement, multi-écrans

- **REQ-MBR-22 (P0)** — `MenuBarUI` observe **les mêmes instances** de stores que le notch (`SessionStore`, `UsageStore`, `ServerStore`, `SettingsStore`), injectées par la composition root (`AgentDashApp`). Le module ne crée **aucun** poller, timer d'ingestion ni I/O : le texte d'usage et le point orange se mettent à jour en arrière-plan par simple observation `@Observable`, popover fermé compris. Les mises à jour du status item sont coalescées (au plus 1 réécriture de contenu / 300 ms, aligné sur la coalescence des stores).
- **REQ-MBR-23 (P0)** — Rafraîchissement en arrière-plan des jauges : les pollers (`ClaudeUsagePoller` 180 s, `CursorUsagePoller` 300 s) tournent indépendamment de la visibilité du popover ; l'ouverture du popover n'est **pas** nécessaire pour que le résumé en barre soit à jour.
- **REQ-MBR-24 (P0)** — À l'ouverture du popover : scan de ports immédiat puis tick rapide 2 s tant que le popover est ouvert (même mécanique que le panel du notch, refcount de visibilité dans `ServerStore` — `01-architecture.md` §5.1) ; retour à 10 s à la fermeture. L'usage n'est **pas** re-fetché automatiquement à l'ouverture (respect du rate limit ; le bouton refresh existe pour ça).
- **REQ-MBR-25 (P1)** — Multi-écrans / Spaces : aucun code de positionnement custom. Le système affiche le status item dans la barre de menus de **chaque** écran ; le `NSPopover` s'ancre au bouton effectivement cliqué (`show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`) et suit l'écran/Space courant (**[VÉRIFIÉ]** research §6.3). `didChangeScreenParametersNotification` ne requiert aucune action côté `MenuBarUI`.
- **REQ-MBR-26 (P1)** — Si l'utilisateur désactive la menu bar alors que le notch est déjà désactivé, Settings affiche un avertissement inline non bloquant : `AgentDash will have no visible surface. Reopen Settings by launching AgentDash again.` (relancer l'app depuis le Finder ré-affiche la fenêtre Settings — géré dans le fichier settings du plan). [HYPOTHÈSE — à valider : comportement AgentPeek inconnu.]
- **REQ-MBR-27 (P1)** — Budget performance : contribution de `MenuBarUI` au CPU idle ≤ 0,1 % (aucune animation permanente en barre ; le shimmer et le spinner n'existent que popover ouvert et refresh actif) ; le popover fermé ne retient aucune hiérarchie de vues serveur (contenu détruit à la fermeture, `contentViewController` reconstruit à l'ouverture).
- **REQ-MBR-28 (P2)** — Clic gauche quand `hasPendingAttention == true` : le popover affiche en tête une bannière `1 agent waiting for you` avec un bouton **« Open notch »** (appelle l'action `openNotch` si le notch est activé ; masquée sinon). [HYPOTHÈSE — à valider : AgentPeek ne documente pas ce raccourci ; ajout produit optionnel.]
- **REQ-MBR-29 (P1)** — Compteur de serveurs dans la barre (complète le status item, REQ-MBR-02 à 05) : le résumé de la barre de menus couvre « usage tokens **+ serveurs** » (features §2.2, repris par `10-local-servers.md` REQ-SRV-28 et §4.1). Si `AppSettings.menuBarShowsServers == true` (nouvelle clé, défaut `true`, cf. note §7), `serverScanEnabled == true` **et** `ServerStore.count ≥ 1`, le status item affiche le nombre de serveurs à droite du texte d'usage, séparé par un point médian (ex. `82% · 3` ; `3` seul si le texte d'usage est masqué), en chiffres `monospacedDigit` teintés `.secondary`. Masqué si `count == 0` ou `serverScanEnabled == false` (cohérence avec `10-local-servers.md` REQ-SRV-09 : « le compteur menu bar disparaît »). [HYPOTHÈSE — à calibrer : rendu exact d'AgentPeek non inspectable ; la **présence** du compteur dans le résumé est en revanche actée par features §2.2.]

---

## 3. Conception technique

### 3.1 API publique du module `MenuBarUI`

```swift
// Packages/MenuBarUI/Sources/MenuBarController.swift
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {

    /// Actions injectées par la composition root — MenuBarUI ne connaît ni SettingsKit ni NotchUI.
    public struct Actions {
        public var openSettings: @MainActor () -> Void
        public var quit:         @MainActor () -> Void
        public var openNotch:    (@MainActor () -> Void)?   // nil si notch désactivé
        public init(openSettings: @escaping @MainActor () -> Void,
                    quit: @escaping @MainActor () -> Void,
                    openNotch: (@MainActor () -> Void)? = nil)
    }

    public init(sessionStore: SessionStore,
                usageStore: UsageStore,
                serverStore: ServerStore,
                settingsStore: SettingsStore,
                actions: Actions)

    /// Création / destruction du NSStatusItem. Appelé par la composition root
    /// à chaque changement de `AppSettings.menuBarEnabled` (withObservationTracking).
    public func setEnabled(_ enabled: Bool)
    public private(set) var isEnabled: Bool

    // — interne —
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    @objc private func statusItemClicked(_ sender: NSStatusBarButton)
    private func showRightClickMenu()
    private func togglePopover()
}
```

### 3.2 Types partagés ajoutés à `DashCore` (utilisés aussi par NotchUI)

```swift
// DashCore — la sémantique de couleur des jauges est UNIQUE et définie par 09-token-usage.md §3.1 :
//   public enum GaugeColor: Sendable { case green, yellow, red }
//   func gaugeColor(consumed p: Double, previous: GaugeColor?) -> GaugeColor
// Seuils normatifs (09 REQ-USG-15, repris par 05 §4.4) : < 70 % vert, 70–89,9 % jaune, ≥ 90 % rouge,
// hystérésis de 2 points à la redescente. MenuBarUI consomme ce type tel quel — AUCUN type
// « GaugeLevel » distinct n'est défini ici (un doublon divergerait, cf. risque §7).

// DashCore — attention dérivée, source unique pour le point orange ET l'auto-expand du notch
public extension SessionStore {
    var hasPendingAttention: Bool {
        sessions.contains { !$0.isDismissed && $0.liveness == .live && $0.state.isWaiting }
    }
    var waitingCount: Int { sessions.count { !$0.isDismissed && $0.state.isWaiting } }
}
```

```swift
// AppSettings — clés AJOUTÉES (à reporter dans 02-data-model.md §6.1, cf. note §7)
var menuBarShowsUsage = true      // texte d'usage à côté de l'icône (REQ-MBR-03)
var menuBarShowsServers = true    // compteur de serveurs à côté du texte d'usage (REQ-MBR-29)
```

### 3.3 Création du status item

```swift
func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    if enabled {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])          // [VÉRIFIÉ] research §6.2
        button.toolTip = "AgentDash"
        let hosting = NSHostingView(rootView: StatusItemView(
            sessionStore: sessionStore, usageStore: usageStore,
            serverStore: serverStore, settingsStore: settingsStore))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([   // le bouton suit la taille intrinsèque du contenu SwiftUI
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        statusItem = item
    } else {
        popover?.performClose(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
```

[HYPOTHÈSE — à valider] : l'auto-dimensionnement du bouton par contraintes sur le `NSHostingView` fonctionne avec `variableLength` (pattern répandu). Plan B si la largeur ne suit pas : observer la taille du contenu (`onGeometryChange`) et écrire `statusItem.length` explicitement.

### 3.4 Routage des clics

```
clic sur NSStatusBarButton
  └─ sendAction(on: [.leftMouseUp, .rightMouseUp]) → statusItemClicked()
       │  event = NSApp.currentEvent
       ├─ .rightMouseUp  OU  (.leftMouseUp + modifierFlags.contains(.control))
       │     └─ menu = NSMenu(["Quit AgentDash" → actions.quit])
       │        statusItem.menu = menu ; button.performClick(nil) ; statusItem.menu = nil
       └─ .leftMouseUp
             ├─ popover.isShown  → popover.performClose()          (toggle, REQ-MBR-09)
             └─ sinon            → showPopover()
                    ├─ popover = NSPopover()
                    │    behavior = .transient                      (REQ-MBR-12)
                    │    delegate = self
                    │    contentViewController = NSHostingController(
                    │        rootView: MenuBarPopoverView(stores…, actions…))
                    │    (sizingOptions = .preferredContentSize)
                    ├─ popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    └─ serverStore.surfaceDidAppear(.menuBarPopover)   → scan immédiat + tick 2 s
popoverDidClose (NSPopoverDelegate)
  └─ serverStore.surfaceDidDisappear(.menuBarPopover)                → retour tick 10 s
     popover = nil                                                    (REQ-MBR-27 : contenu détruit)
```

`ServerStore.surfaceDidAppear/Disappear(_ surface: VisibleSurface)` est un refcount (`enum VisibleSurface { case notchPanel, menuBarPopover }`) : le tick rapide reste actif tant qu'au moins une surface montrant les serveurs est visible — API définie dans le fichier serveurs du plan, consommée ici.

### 3.5 Flux de rafraîchissement en arrière-plan (aucun poller dans MenuBarUI)

```
ClaudeUsagePoller (actor, 180 s) ──┐
CursorUsagePoller (actor, 300 s) ──┼─► UsageStore (@MainActor, @Observable)
PortScanner       (actor, 2/10 s) ─┼─► ServerStore (@MainActor, @Observable)
HookServer / ingestion            ─┴─► SessionStore (@MainActor, @Observable)
                                            │ observation SwiftUI (pas de timer côté MenuBarUI)
              ┌─────────────────────────────┼──────────────────────────────┐
              ▼                             ▼                              ▼
   StatusItemView (barre,          MenuBarPopoverView             NotchUI (même stores,
   toujours montée)                (montée si popover ouvert)      autre fichier du plan)
   · texte % usage (REQ-03)        · jauges + shimmer
   · point orange (REQ-04)         · lignes serveurs + StopState
   · compteur serveurs (REQ-29)
```

### 3.6 Vues SwiftUI

```swift
// Contenu du bouton de barre — hauteur 22 pt
struct StatusItemView: View {
    // stores @Observable observés directement (mêmes instances que le notch)
    var body: some View {
        HStack(spacing: 4) {
            Image(/* glyphe AgentDash, rendu vectoriel monochrome */)
                .foregroundStyle(Color(nsColor: .labelColor))
                .overlay(alignment: .topTrailing) {
                    if sessionStore.hasPendingAttention {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            if settingsStore.settings.menuBarShowsUsage,
               let percent = usageStore.menuBarSummaryPercent {   // pire fenêtre activée, cf. REQ-03
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(color(for: usageStore.menuBarSummaryColor))
            }
            if settingsStore.settings.menuBarShowsServers,
               settingsStore.settings.serverScanEnabled,
               serverStore.count >= 1 {                            // compteur serveurs, cf. REQ-29
                Text("· \(serverStore.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .animation(.spring(response: 0.3, dampingFraction: 0.8),
                   value: sessionStore.hasPendingAttention)
    }
}

// Popover — 320 pt de large, sections plates
struct MenuBarPopoverView: View { /* AttentionBanner? · UsageSection · ServersSection · FooterRow */ }

struct UsageSection: View {
    // par agent activé : AgentUsageCard(label:, windows: [UsageWindow])
    // en-tête : "Usage" + Button(refresh) → usageStore.refreshAll(manual: true)
    // shimmer : overlay LinearGradient animé si usageStore.isRefreshing
}

struct ServerRow: View {
    let server: DevServer
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(String(server.id.port)).font(.system(.body).monospacedDigit()).bold()
                    Text(server.displayName)                         // « Next.js », « Vite »…
                    if server.framework != nil { FrameworkBadge(server) }
                }
                Text("\(server.projectPath.abbreviatedHome) · up \(server.uptimeText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton("arrow.up.right")  { NSWorkspace.shared.open(server.url) }    // Open
            IconButton("doc.on.doc")      { copyToPasteboard(server.url) }           // Copy URL
            StopButton(state: server.stopState,
                       request: { serverStore.requestStop(server.id) },              // 1er clic
                       confirm: { serverStore.confirmStop(server.id) })              // 2e clic ≤ 3 s
        }
    }
}
```

### 3.7 Machine à états du bouton Stop (miroir de `DevServer.StopState`, possédée par `ServerStore`)

```
   .none ── clic stop ──► .confirming(until: now+3s) ── clic « Confirm? » ──► .terminating ──► .gone
     ▲                            │                                            │        (ligne retirée
     └──── échéance `until` ──────┘                              SIGTERM → 3 s → SIGKILL   au scan suivant)
                                                       (re-validation pid/start_time/execPath AVANT signal)
```

La temporisation de retour à `.none` est un `Task` MainActor armé par `ServerStore.requestStop` — l'état vit dans le store (pas dans la vue) pour que le notch et la menu bar montrent le **même** état de confirmation simultanément.

### 3.8 Résumé d'usage pour la barre (calcul dans `UsageStore`, pas dans la vue)

```swift
// UsageStore (DashCore)
var menuBarSummaryPercent: Int? {
    let enabled = windows.filter { isEnabled(window: $0) && $0.hasEverHadValue }
    guard let worst = enabled.max(by: { $0.utilization < $1.utilization }) else { return nil }
    let value = settings.countdownFrom100 ? (100 - worst.utilization) : worst.utilization
    return Int(value.rounded())
}
var menuBarSummaryColor: GaugeColor {
    gaugeColor(consumed: /* utilisation brute de la pire fenêtre, jamais inversée */,
               previous: lastMenuBarSummaryColor)   // seuils 70/90 + hystérésis, 09 §3.1 (REQ-USG-15)
}
```

Le niveau de couleur reste calculé sur l'**utilisation réelle** même en mode countdown (18 % restants = rouge, pas vert).

---

## 4. Spécification UX/UI

### 4.1 Status item

| Élément | Spécification |
|---|---|
| Hauteur | 22 pt (hauteur standard de contenu de barre de menus) |
| Icône | glyphe AgentDash monochrome 16 × 16 pt, `labelColor` (s'adapte au clair/sombre et au surlignage du bouton) |
| Texte usage (optionnel) | 12 pt medium `monospacedDigit`, teinté `GaugeColor` (vert/jaune/rouge système, seuils 70/90 de `09-token-usage.md` REQ-USG-15) ; exemples : `82%`, `18%` (countdown) |
| Compteur serveurs (optionnel) | 12 pt medium `monospacedDigit`, `.secondary`, précédé d'un point médian ; exemples : `82% · 3`, `· 3` (usage masqué) ; masqué si 0 serveur (REQ-MBR-29) |
| Point d'attention | disque orange 7 pt, ancré top-trailing de l'icône (offset +3, −2), apparition ressort `response 0.3` |
| Espacements | 6 pt de padding horizontal, 4 pt entre icône et texte |
| Surlignage | bouton surligné pendant l'affichage du popover et du menu contextuel (comportement `NSStatusBarButton`) |

États visuels du status item : `normal` (icône seule) · `usage` (icône + %) · `servers` (compteur, cumulable avec le %) · `attention` (point orange, cumulable avec le texte) · `pressed` (surligné).

### 4.2 Menu clic droit

```
┌──────────────────────┐
│ Quit AgentDash    ⌘Q │
└──────────────────────┘
```

Texte exact : `Quit AgentDash`. Aucun autre item (parité AgentPeek v0.2.8).

### 4.3 Popover (320 pt de large)

```
┌──────────────────────────────────────────┐
│ ⚠ 1 agent waiting for you   [Open notch] │  ← bannière REQ-MBR-28 (P2, seulement si attention)
├──────────────────────────────────────────┤
│ USAGE                                col ↻│  ← en-tête section + bouton refresh (shimmer si actif)
│  Claude Code                              │
│   5h  ▓▓▓▓▓▓▓▓░░ 82%    resets in 2h 14m  │  ← jauge batterie, teinte GaugeColor
│   7d  ▓▓▓▓░░░░░░ 41%  refills Sun 3:47 PM │
│  Cursor                                   │
│   Monthly ▓▓▓▓▓▓░░░░ 62%   $12.40 of $20  │
├──────────────────────────────────────────┤
│ LOCAL SERVERS                             │
│  3000  Next.js   ~/dev/shop · up 2h 14m   │
│                            [↗] [⧉] [Stop] │
│  5173  Vite      ~/dev/site · up 12m      │
│                       [↗] [⧉] [Confirm?] │  ← état confirming : texte rouge 3 s
├──────────────────────────────────────────┤
│ Settings…                              ⌘, │
└──────────────────────────────────────────┘
```

- **En-têtes de section** : `Usage`, `Local Servers` — 11 pt, `.secondary`, casse majuscules, padding 12/8.
- **Textes exacts (anglais, parité AgentPeek ; libellés serveurs canoniques dans `10-local-servers.md` §4.3–4.4)** : `resets in 2h 14m` · `refills Sun at 3:47 PM` · `$12.40 of $20` · `Confirm?` · `Stopping…` · `Settings…` · état vide serveurs : `No local servers` + `Dev servers on ports 3000–9999 will show up here.` · `Usage disabled in Settings` (carte agent désactivée : masquée, pas ce texte — réservé au cas section vide) · `1 agent waiting for you` · `Open notch` · bannière vide totale : `Enable usage or server tracking in Settings` · pastille de rétention : `as of 14:02`.
- **Jauges** : style batterie horizontal 8 pt de haut, coins arrondis 4 pt, remplissage animé (`.spring(response: 0.4)`), `--` centré gris si jamais de valeur. Shimmer : bande claire diagonale traversant la jauge en 1,2 s en boucle pendant `isRefreshing`.
- **Lignes serveurs** : hauteur 44 pt, boutons d'action 24 × 24 pt (symbols `arrow.up.right`, `doc.on.doc`, `stop.circle`), feedback de copie : le symbole devient `checkmark` 0,8 s. `Confirm?` : label rouge `.bold`, largeur stable (pas de reflow). `terminating` : `ProgressView` 12 pt à la place du bouton.
- **Section serveurs > 8 rows** : `ScrollView` interne, hauteur max ≈ 352 pt (8 × 44 pt) — cap canonique du popover fixé par `10-local-servers.md` REQ-SRV-26/§4.5 (« au plus 8 rows dans le popover »). [HYPOTHÈSE — à valider : seuil exact d'AgentPeek inconnu, hérité de 10.]
- **Animations** : apparition/disparition de lignes serveurs en `.move(edge:) + .opacity` ; aucune animation permanente popover fermé (budget CPU).
- **Densité/largeur** : le popover n'est **pas** affecté par les réglages `panelWidth`/`density` du notch (surface indépendante, sizing propre). [HYPOTHÈSE — à valider : AgentPeek ne documente pas l'inverse.]

---

## 5. Cas limites & gestion d'erreurs

1. **Toggle off pendant que le popover est ouvert** : `setEnabled(false)` ferme d'abord le popover (`performClose`), puis retire l'item — jamais de popover orphelin.
2. **Toggle off pendant qu'un serveur est `confirming`/`terminating`** : l'état vit dans `ServerStore`, la séquence kill continue ; à la réactivation, l'UI reflète l'état courant.
3. **Quit demandé avec des prompts en vol** : `actions.quit` ferme le serveur IPC proprement ; les connexions ouvertes se ferment → les hooks sortent en fail-open, les agents affichent leurs dialogues natifs (`01-architecture.md` §4.1). Aucune confirmation demandée.
4. **Barre de menus saturée / item masqué par le notch physique** : macOS peut masquer des status items sans notification ni API de détection — comportement système assumé, documenté dans la FAQ ; le notch d'AgentDash reste la surface principale. Aucun contournement (pas d'API publique).
5. **Serveur mort entre le scan et le clic Stop** : la re-validation `(pid, start_time, execPath)` échoue → `ServerStore` passe la ligne en `.gone`, aucun signal envoyé (invariant n°6 de `02-data-model.md`).
6. **Port réapparu avec un autre pid pendant `confirming`** : l'identité `DevServer.ID = (pid, port)` change → nouvelle ligne à l'état `.none` ; l'ancienne disparaît, pas de kill du mauvais process.
7. **Usage indisponible au premier lancement** (Keychain refusé, réseau coupé, toggles off) : jauges `--`, texte de barre masqué (REQ-MBR-03), pas d'erreur bloquante ; bouton refresh reste actif.
8. **Refresh manuel en rafale** : anti-rafale 10 s dans `UsageStore` — les clics excédentaires sont ignorés silencieusement (le shimmer en cours suffit comme feedback).
9. **Échec de refresh** : jauges retenues + `isStale` + `as of HH:mm` ; jamais de valeur régressée silencieusement (invariant n°5).
10. **Rollover de fenêtre 5 h/7 j pendant que le popover est ouvert** : `UsageStore` reset la jauge à l'échéance exacte (timer armé à date, `01-architecture.md` §5.2) → la jauge s'anime vers sa nouvelle valeur, libellé `resets in…` recalculé.
11. **Changement de réglage (mesure Cursor, compte, countdown)** : mise à jour **immédiate** des jauges du popover et du texte de barre (feature §5.2 « mises à jour immédiates au changement de réglage ») — garanti par l'observation des mêmes stores.
12. **Aucun écran avec barre de menus visible** (barre auto-masquée partout) : le status item existe toujours, accessible au survol du bord supérieur — aucun code spécifique.
13. **Reconfiguration d'écrans (dock/undock, résolution)** : rien à faire côté `MenuBarUI` (le système redistribue les barres) ; le popover ouvert est fermé par le système si son ancrage disparaît [HYPOTHÈSE — à valider ; sinon `performClose` sur `didChangeScreenParametersNotification`].
14. **Clic droit pendant que le popover est ouvert** : le popover `.transient` se ferme (clic hors de lui), puis le menu s'ouvre — séquence naturelle, pas de superposition.
15. **VoiceOver / contrôle clavier** : le popover est navigable au clavier une fois key ; les boutons d'action serveur ont des labels d'accessibilité (`Open URL`, `Copy URL`, `Stop server`).
16. **`hideFromScreenRecording`** : ne s'applique **pas** à la surface menu bar (le réglage vise le notch, cf. fichier Appearance/notch) — un status item est de toute façon composité par le système. Documenté pour éviter toute attente contraire.
17. **Deux surfaces affichant la même confirmation Stop** : état unique dans `ServerStore` → cliquer « Confirm? » dans le notch puis dans la menu bar ne double-kill pas (le second clic voit `terminating` et est inerte).

---

## 6. Critères d'acceptation

1. **Given** `menuBarEnabled = true` et `notchEnabled = false`, **When** l'app démarre, **Then** l'icône apparaît dans la barre de menus et aucune fenêtre notch n'existe (indépendance des toggles).
2. **Given** l'icône affichée, **When** on désactive « Menu bar » dans Settings → General, **Then** l'icône disparaît immédiatement sans redémarrage, et réapparaît à la réactivation.
3. **Given** une session Claude Code passe en `waiting(.permission)` (déclencher une commande nécessitant une permission), **When** l'état atteint `SessionStore`, **Then** le point orange apparaît sur l'icône en < 1 s avec une animation de scale ; **When** la permission est résolue (dans le notch ou le terminal), **Then** le point disparaît.
4. **Given** le popover fermé, **When** clic gauche sur l'icône, **Then** le popover s'ouvre ancré sous l'icône avec les sections Usage, Local Servers, Settings… ; **When** re-clic gauche, **Then** il se ferme (toggle).
5. **Given** le popover ouvert, **When** on clique sur une autre app (ou n'importe où hors du popover), **Then** il se ferme automatiquement, et l'app frontale n'a jamais perdu son statut actif pendant l'ouverture.
6. **Given** l'icône affichée, **When** clic droit, **Then** un menu avec l'unique entrée « Quit AgentDash » apparaît ; **When** on la choisit, **Then** l'app se termine et une session agent en cours continue de fonctionner (prompt natif dans le terminal — fail-open).
7. **Given** un serveur Vite lancé sur le port 5173, **When** on ouvre le popover, **Then** la ligne `5173 · Vite` apparaît en < 2 s avec dossier et uptime ; **When** premier clic sur Stop, **Then** le bouton devient « Confirm? » rouge ; **When** on attend 3 s sans cliquer, **Then** il redevient « Stop » ; **When** on re-clique « Confirm? » dans les 3 s, **Then** le process reçoit SIGTERM et la ligne disparaît.
8. **Given** `menuBarShowsUsage = true` et une jauge 5 h à 82 %, **Then** la barre affiche `82%` en **jaune** (70 ≤ 82 < 90, seuils de `09-token-usage.md` REQ-USG-15) ; **When** on active `countdownFrom100`, **Then** le texte passe immédiatement à `18%` sans changer de couleur de seuil.
9. **Given** le popover ouvert, **When** clic sur le bouton refresh de la section Usage, **Then** un shimmer traverse les jauges pendant le fetch et les valeurs se mettent à jour ; **When** on re-clique dans les 10 s, **Then** aucun nouveau fetch ne part (anti-rafale).
10. **Given** le réseau coupé et des jauges déjà peuplées, **When** le prochain poll échoue, **Then** les jauges du popover et le texte de barre **conservent** leurs valeurs avec la mention `as of HH:mm` — jamais de `--` ni de régression.
11. **Given** un MacBook + écran externe (« Displays have separate Spaces » actif), **When** on clique l'icône dans la barre de l'écran externe, **Then** le popover s'ouvre sur cet écran, ancré à l'icône cliquée.
12. **Given** le popover ouvert 60 s sans interaction, **Then** l'échantillonnage CPU de l'app reste dans le budget (< 5 % actif) et, popover fermé, la contribution de MenuBarUI au CPU idle est ≤ 0,1 % (vérifiable via l'auto-mesure Doctor).

---

## 7. Dépendances (autres fichiers du plan) et risques

### Dépendances

| Fichier | Ce que 06-menubar en consomme |
|---|---|
| `plan/01-architecture.md` | décision A4 (`NSStatusItem` AppKit, pas de `MenuBarExtra`), threading §5 (stores MainActor, coalescence 300 ms), budgets §6, fail-open §7 |
| `plan/02-data-model.md` | `UsageWindow` (+ `isStale`, `dollars`, `resetsAt`), `DevServer`/`StopState`, `SessionState.waiting`, `AppSettings` (`menuBarEnabled`, `countdownFrom100`, `claudeUsageEnabled`, `cursorUsageEnabled`, `serverScanEnabled`) |
| Fichier du plan « notch » (05, numérotation présumée) | partage de `hasPendingAttention` (auto-expand), du bouton refresh/shimmer (`UsageStore.isRefreshing`), action `openNotch` |
| Fichier du plan « usage » | formats exacts `resets in…` / `refills … at …` / `$X of $Y`, `refreshAll(manual:)`, anti-rafale, rollover, `menuBarSummaryPercent` |
| Fichier du plan « serveurs » (10) | `ServerStore.requestStop/confirmStop`, `ServerStore.count` (compteur du résumé, REQ-MBR-29), `surfaceDidAppear/Disappear`, cadence de scan 2 s/10 s, garde-fous kill ; **libellés et sizing canoniques** : « Confirm? »/« Stopping… » (REQ-SRV-31/34), état vide §4.4, cap popover 8 rows (REQ-SRV-26) |
| Fichier du plan « settings » | toggle « Menu bar » + nouvelle clé `menuBarShowsUsage`, avertissement « aucune surface » (REQ-MBR-26), ouverture de la fenêtre Settings |

**Éléments que ce fichier IMPOSE aux autres** (à répercuter) : ① ajout de `menuBarShowsUsage: Bool = true` et `menuBarShowsServers: Bool = true` dans `AppSettings` (`02-data-model.md` §6.1) ; ② `SessionStore.hasPendingAttention` dans `DashCore` (partagé notch/menu bar) — la couleur de jauge, elle, **réutilise** `GaugeColor`/`gaugeColor` définis par `09-token-usage.md` §3.1, aucun type doublon ; ③ refcount `surfaceDidAppear/Disappear` dans `ServerStore` ; ④ `menuBarSummaryPercent/Color` dans `UsageStore`.

### Risques

| Risque | Impact | Mitigation |
|---|---|---|
| `NSPopover` depuis un status item active l'app ou vole le focus clavier (REQ-MBR-13, [HYPOTHÈSE]) | vol de focus pendant que l'utilisateur code — inacceptable | banc d'essai `scripts/experiments/` dès la première itération ; plan B acté : `NSPanel` non-activant ancré (research §6.3) |
| Auto-dimensionnement `NSHostingView` dans le bouton non fiable ([HYPOTHÈSE §3.3]) | icône tronquée ou largeur figée | fallback `statusItem.length` explicite piloté par `onGeometryChange` |
| Point orange illisible selon le fond d'écran (barre de menus translucide) | attention manquée | disque orange plein non-template + liseré 0,5 pt `labelColor` en cas de contraste insuffisant (à juger visuellement) |
| Status item masqué par macOS (barre saturée / notch physique) | surface invisible sans diagnostic possible | documentation FAQ ; le notch reste la surface primaire ; pas d'API publique — assumé |
| Divergence visuelle jauges notch vs menu bar (composants non partagés entre packages UI) | incohérence produit | sémantique (niveaux, formats, seuils) centralisée dans `DashCore`/`UsageStore` ; seul le dessin est dupliqué, revue visuelle croisée en checklist de release |

---

## 8. Découpage en tâches

| # | Tâche | Taille | REQ couvertes |
|---|---|---|---|
| T1 | `MenuBarController` : cycle de vie du `NSStatusItem`, `setEnabled`, réaction au toggle Settings | **S** | 01, 08 |
| T2 | `StatusItemView` : icône + texte d'usage optionnel + compteur de serveurs + point orange animé ; helpers `DashCore` (`hasPendingAttention`, `menuBarSummaryPercent/Color` — `GaugeColor` réutilisé de 09) | **M** | 02, 03, 04, 05, 29 |
| T3 | Routage des clics : gauche → toggle popover, droit/⌃-clic → menu « Quit AgentDash » (pattern menu temporaire) | **S** | 09, 10, 11 |
| T4 | `NSPopover` `.transient` + `NSHostingController` auto-dimensionné + delegate (destruction du contenu, refcount serveurs) + banc d'essai focus (risque n°1) | **M** | 12, 13, 14, 27 |
| T5 | Section Usage : cartes par agent, jauges batterie compactes, libellés reset, `--`, rétention `as of`, bouton refresh + shimmer | **L** | 15, 16, 17 |
| T6 | Section Local Servers : lignes, actions open/copy, bouton Stop en deux temps câblé sur `StopState`, scroll > 8 rows (10 REQ-SRV-26), feedback copie | **M** | 18, 19 |
| T7 | Pied de page Settings…, états vides et sections masquées, bannière « aucune surface » (avec le fichier settings) | **S** | 20, 21, 26 |
| T8 | Synchronisation/perf : observation des stores partagés, coalescence, scan rapide à l'ouverture, vérification budget CPU via l'auto-mesure Doctor | **M** | 22, 23, 24, 27 |
| T9 | Multi-écrans (test manuel dock/undock, Spaces séparés), tooltip, accessibilité | **S** | 06, 07, 25 |
| T10 | Bannière attention + « Open notch » (P2, après le MVP) | **S** | 28 |

**Total estimé** : 2 S de plomberie AppKit, le gros du travail dans T5 (jauges) et T6 (serveurs) qui réutilisent la sémantique des fichiers usage/serveurs. Chemin critique MVP : T1 → T3 → T4 → T5/T6 → T8.
