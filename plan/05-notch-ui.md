# 5. Surface notch (NotchUI)

> Spécification du package `NotchUI` et de la fenêtre notch d'AgentDash (nom provisoire), rédigée le 3 juillet 2026.
> Conforme à `plan/01-architecture.md` (décisions A4, A5, A6, A9) et `plan/02-data-model.md` (types `Session`, `PendingPrompt`, `AppSettings`).
> Base factuelle : `plan/research/notch-ui.md` (code source inspecté de boring.notch/NotchDrop/DynamicNotchKit, doc Apple). Tout ce qui relève du design interne d'AgentPeek (non inspectable) est marqué **[HYPOTHÈSE]**.

---

## 1. Objectif & périmètre

Ce document spécifie la **surface notch** complète : la fenêtre `NSPanel` qui recouvre le notch (ou simule une encoche sur écran externe), ses deux états **Pill** (réduit) et **Panel** (étendu), la machine à états d'expansion, les layouts, toutes les options d'Appearance qui s'y appliquent, les animations, le rendu Liquid Glass avec fallback macOS 14, les avatars pixel-grid, le focus clavier et l'accessibilité.

Sections d'`AGENTPEEK_FEATURES.md` couvertes :
- **§2.2 Surfaces UI** — notch Pill/Panel, auto-expand, délai d'intention au survol, notch ouvert pendant Settings, fausse encoche externe, animations v0.2.11.
- **§3.2 Carte de session** — uniquement l'avatar pixel-grid animé et le rendu couleur+mouvement des états (le contenu des cartes est spécifié dans le document sessions/timeline du plan).
- **§5.2** — mode usage du pill (jauges live, largeur verrouillée Wide/Ultra-wide, Auto width).
- **§10 Appearance** — largeurs (dont Ultra-wide), densité (dont Colossal), liste fixe/growable, graisse des titres, horloge 12/24 h, options du pill (count/usage/hide when idle/expanded only), Liquid Glass (opacité + Opaque, frosted rim, depth-lit), opacité des métriques.
- **§14.2** (périmètre du clone) — « Notch UI : Pill + Panel, auto-expand, animations, Liquid Glass, support écran externe ».

Hors périmètre de ce fichier (traités ailleurs, la surface notch les *héberge* seulement) : contenu détaillé des cartes de session et de la timeline, logique des prompts actionnables et raccourcis ⌘A/⌘N/⌥A/⌥T, calcul des jauges d'usage, scan des serveurs, Quick Routes/Fast Actions (logique), menu bar, Settings.

---

## 2. Exigences détaillées

### 2.1 Fenêtre et positionnement

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-01 | La surface notch est une sous-classe `NotchPanel: NSPanel` avec `styleMask = [.borderless, .nonactivatingPanel]`, `isFloatingPanel = true`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `isMovable = false`, `isReleasedWhenClosed = false`, `appearance = NSAppearance(named: .darkAqua)`. Aucune interaction avec le panel ne doit activer AgentDash ni retirer le statut actif à l'app frontale (vérifiable : curseur clignotant conservé dans l'IDE pendant un clic sur le pill). | P0 |
| REQ-NUI-02 | `canBecomeKey` retourne `true`, `canBecomeMain` retourne `false`, et `becomesKeyOnlyIfNeeded = true` : le panel ne devient key window que sur demande explicite (clic dans un champ texte, `makeKey()` programmatique à l'apparition d'un prompt). | P0 |
| REQ-NUI-03 | `level = .statusBar + 3` : le panel recouvre la barre de menus (nécessaire pour que le pill épouse le notch) sans passer au niveau `.screenSaver`. | P0 |
| REQ-NUI-04 | `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` : visible sur tous les Spaces et par-dessus les apps fullscreen, immobile pendant Mission Control, exclu du cycle ⌘\`. | P0 |
| REQ-NUI-05 | La fenêtre est créée **une seule fois par écran** à sa **taille maximale fixe** (largeur du panel Ultra-wide + 2 × 20 pt de marge d'ombre ; hauteur = hauteur max du panel growable + 20 pt) et n'est **jamais redimensionnée** : toute l'animation Pill ↔ Panel est réalisée en SwiftUI à l'intérieur. | P0 |
| REQ-NUI-06 | Affichage via `orderFrontRegardless()` exclusivement ; `NSApp.activate(ignoringOtherApps:)` et `makeKeyAndOrderFront(_:)` sont interdits dans `NotchUI`. | P0 |
| REQ-NUI-07 | Le bord supérieur de la fenêtre coïncide avec `screen.frame.maxY`, la fenêtre est centrée horizontalement sur l'écran ; la forme SwiftUI alignée `.top` se superpose exactement à la découpe physique. | P0 |
| REQ-NUI-08 | Les zones transparentes de la fenêtre laissent passer les clics vers les fenêtres dessous (aucun `contentShape` hors de la forme visible du notch) : un clic sur un item de la barre de menus situé sous la partie invisible de la fenêtre doit fonctionner normalement. | P0 |
| REQ-NUI-09 | Si `AppSettings.hideFromScreenRecording == true`, `sharingType = .none` est appliqué au panel (le notch n'apparaît pas dans les captures/enregistrements d'écran). | P2 |
| REQ-NUI-10 | Le toggle Settings `notchEnabled` masque/affiche la surface (fermeture ordonnée : repli animé puis `orderOut`) sans redémarrage. | P0 |
| REQ-NUI-11 | Aucune API privée (CGSSpace, SkyLight) : la surface n'est pas visible sur l'écran de verrouillage, comportement assumé. | P0 |

### 2.2 Géométrie du notch et multi-écrans

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-12 | La taille du notch physique est calculée par l'extension `NSScreen.notchSize` : `safeAreaInsets.top` pour la hauteur, `frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` pour la largeur ; retourne `.zero` si l'une des conditions manque. Le pill dessine un **débord horizontal de +4 pt** (2 pt de chaque côté) pour masquer les liserés d'anticrénelage. | P0 |
| REQ-NUI-13 | Sur un écran **sans notch** (externe, ou dalle interne en résolution supprimant la safe area), une **fausse encoche** est dessinée au ras du bord supérieur, centrée : hauteur = hauteur de la barre de menus de l'écran (`frame.maxY − visibleFrame.maxY`) avec un plancher de **24 pt** si la barre est masquée, largeur de repos **190 pt** [HYPOTHÈSE — dimensions AgentPeek inconnues, valeurs alignées sur boring.notch/NotchDrop, à calibrer visuellement]. | P0 |
| REQ-NUI-14 | Chaque écran est identifié par `displayUUID` (`CGDisplayCreateUUIDFromDisplayID`) ; le choix des écrans porteurs suit `AppSettings.preferredScreen` (`.builtinThenMain` par défaut, `.uuid(String)`, `.active`). | P0 |
| REQ-NUI-15 | Sur `NSApplication.didChangeScreenParametersNotification` (et `NSWorkspace.didWakeNotification`), l'ensemble `{displayUUID: frame}` est comparé au précédent ; en cas de changement, les fenêtres sont détruites, recréées et repositionnées, et `notchSize` est recalculée (les changements de résolution modifient la largeur du notch en points). L'état d'expansion courant est restauré après reconstruction. | P0 |
| REQ-NUI-16 | Le mode « tous les écrans » (une fenêtre + un view model par UUID, contenu identique) est disponible en P2 ; la v1 n'affiche la surface que sur un seul écran à la fois. | P2 |

### 2.3 Machine à états d'expansion

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-17 | La surface a quatre états : `pill` (fermé), `opening`, `panel` (ouvert), `closing`. Les transitions sont exclusivement celles du diagramme §3.3 ; toute demande d'ouverture pendant `closing` (et inversement) annule l'animation en cours et repart de l'état visuel courant (les ressorts SwiftUI sont interruptibles). | P0 |
| REQ-NUI-18 | **Hover avec délai d'intention** : le survol du pill n'ouvre le panel qu'après `hoverIntentDelayMs` (défaut 200 ms, réglable) de survol continu ; la sortie du curseur pendant ce délai annule l'ouverture. À la sortie du panel ouvert, une **hystérésis fixe de 100 ms** tolère les sorties/rentrées rapides avant fermeture. Implémentation par `Task` annulable (toute nouvelle transition hover annule la tâche précédente). | P0 |
| REQ-NUI-19 | **Clic** : un clic sur le pill ouvre le panel immédiatement (sans délai d'intention) ; un clic sur la zone du notch quand le panel est ouvert (en dehors d'un contrôle interactif) le referme. | P0 |
| REQ-NUI-20 | **Auto-expand sur attention** : si `autoExpandOnAttention == true` et `promptHandling ∈ {.notch, .both}`, l'arrivée d'un `PendingPrompt` (ou d'un passage en `waiting`) ouvre le panel programmatiquement par le même chemin que le hover, et fait défiler la section prompt en tête. Latence conforme au budget A9 : l'animation démarre < 150 ms après l'événement hook. | P0 |
| REQ-NUI-21 | **Fermeture au clic extérieur** : un moniteur `NSEvent` global + local sur `leftMouseDown` ferme le panel si le clic est hors de son rect. Exception : le panel **reste ouvert tant que la fenêtre Settings d'AgentDash est key** (comportement AgentPeek « Reste ouvert quand la fenêtre Settings a le focus ») — la fermeture par survol sortant est également suspendue dans ce cas. | P0 |
| REQ-NUI-22 | Le panel ne se ferme jamais automatiquement tant qu'un champ texte du panel a le focus (réponse à une question en cours de frappe) ; la fermeture au clic extérieur reste possible. | P0 |
| REQ-NUI-23 | Aucun moniteur global `keyDown` (permission Accessibilité requise — interdit). Les raccourcis de prompt sont gérés par le statut key du panel et par hotkeys Carbon éphémères (spécifiés dans le document « actions inline » du plan). | P0 |

### 2.4 Pill (état réduit)

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-24 | Le pill est une forme `NotchShape` **noire pure** (aucun matériau de flou : il doit se fondre dans la découpe physique), rayons fermés `(top: 6, bottom: 14)`, surmontée d'une ligne noire de 1 pt masquant la couture d'anticrénelage avec le bord d'écran. | P0 |
| REQ-NUI-25 | **Variante count** (`pillShowsSessionCount == true`, défaut) : le pill affiche, dans ses ailes latérales (à gauche et à droite de la découpe physique), un indicateur d'état agrégé — à gauche un mini-avatar pixel-grid (ou point de couleur) reflétant l'état le plus prioritaire (`waiting` > `executing` > `thinking` > `idle`), à droite le nombre de sessions live non idle (ex. « 3 »). [HYPOTHÈSE — répartition gauche/droite AgentPeek inconnue.] | P0 |
| REQ-NUI-26 | **Mode usage** (`pillUsageMode == true`) : les ailes du pill affichent des **mini-jauges d'usage live** au style batterie miniature, empilées horizontalement — de **1 à 3** selon les toggles et le compte prioritaire : Claude 5 h, Claude 7 j, Cursor mensuel (spécification canonique : 09-token-usage.md §4.2 et REQ-USG-35). Dans ce mode, la largeur du pill est **verrouillée** sur `pillWidthMode ∈ {.wide, .ultraWide}` ; la valeur `.auto` y est indisponible (le picker Settings force `.wide`). | P1 |
| REQ-NUI-27 | **Largeurs du pill** : `.auto` = largeur du notch + contenu nécessaire des ailes (croît/rétrécit avec le contenu, animé) ; `.wide` = notch + 120 pt ; `.ultraWide` = notch + 200 pt [HYPOTHÈSE — valeurs à calibrer]. Sur écran externe, la base est la largeur de la fausse encoche (190 pt). | P1 |
| REQ-NUI-28 | **Hide when idle** (`pillHideWhenIdle == true`) : quand aucune session live n'est ≠ `idle` **et** qu'aucun `PendingPrompt` n'existe, le pill se réduit à la seule découpe physique (ailes fondues, largeur = notch exactement ; sur écran externe : encoche masquée complètement). Toute activité ou attention le fait réapparaître en fondu ≤ 300 ms. La zone de hover reste active (le survol rouvre normalement). [HYPOTHÈSE sur la sémantique exacte AgentPeek.] | P1 |
| REQ-NUI-29 | **Expanded only** (`pillExpandedOnly == true`) : le pill ne dessine jamais d'ailes ni de contenu ; seul le panel étendu existe visuellement (hover/clic sur la zone du notch continue d'ouvrir). [HYPOTHÈSE sur la sémantique exacte.] | P2 |
| REQ-NUI-30 | Rien d'important n'est dessiné dans la zone de la LED caméra (extrémité droite intérieure de la découpe) : la LED est physique et ne peut être recouverte. Les contenus des ailes gardent une marge intérieure ≥ 8 pt par rapport à la découpe. | P0 |
| REQ-NUI-31 | Quand `LicenseState == .trialExpired`, le pill passe en rendu **grisé** (contenu désaturé, opacité 0,5) et le panel n'ouvre que l'écran d'achat (conforme à `02-data-model.md` §6). | P1 |

### 2.5 Panel (état étendu)

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-32 | Le panel étendu utilise `NotchShape` rayons `(top: 19, bottom: 24)`, largeur selon `panelWidth` : `.normal` = 640 pt, `.wide` = 760 pt, `.ultraWide` = 880 pt [HYPOTHÈSE — seule l'existence des trois crans est vérifiée ; valeurs à calibrer]. Hauteur pilotée par le contenu. | P0 |
| REQ-NUI-33 | Sections du panel, dans l'ordre vertical : **(1) header** (horloge, bouton refresh usage), **(2) prompt en cours** (permission/plan/question — visible uniquement si `PendingPrompt` existe et `promptHandling ≠ .terminalOnly`), **(3) sessions** (liste triée par projet), **(4) usage** (jauges par fenêtre), **(5) serveurs locaux**, **(6) Quick Routes**, **(7) Fast Actions**. [HYPOTHÈSE — ordre exact AgentPeek inconnu ; le prompt en tête est imposé par l'exigence d'attention.] Le contenu de (2)–(7) est fourni par les vues des documents dédiés ; NotchUI définit le conteneur, les titres de section et le scroll. | P0 |
| REQ-NUI-34 | **Liste fixe/growable** (`sessionListSizing`) : `.fixed` = hauteur de liste plafonnée (3 cartes visibles en densité regular, scroll au-delà) ; `.growable` = le panel grandit avec le contenu jusqu'à `screen.visibleFrame.height − 40 pt`, puis la liste scrolle. Le changement de réglage s'applique immédiatement, animé. | P1 |
| REQ-NUI-35 | Le scroll fonctionne **sans** que le panel soit key (les scroll events suivent le curseur, comportement AppKit standard) ; vérifiable en scrollant la liste pendant que l'IDE garde le focus clavier. | P0 |
| REQ-NUI-36 | État vide : si aucune session, la section sessions affiche un état vide soigné (texte + icône, cf. §4.4) ; les sections serveurs/usage suivent le même principe. Une section optionnelle vide (Fast Actions sans action définie) est masquée entièrement. | P1 |

### 2.6 Appearance

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-37 | **Densité** (`density`) : trois crans `.compact` / `.regular` / `.colossal` pilotant hauteurs de rangée, tailles de police et espacements via une table `DensityMetrics` unique (aucune valeur en dur dans les vues). Valeurs de référence en §4.6 [HYPOTHÈSE — à calibrer]. | P1 |
| REQ-NUI-38 | **Graisse des titres** (`titleWeight`) : `.regular` / `.medium` / `.semibold` (défaut) / `.bold`, appliquée aux titres de session et de section. | P2 |
| REQ-NUI-39 | **Horloge 12/24 h** (`clock24h`) : horloge du header du panel, format « 14:32 » ou « 2:32 PM », mise à jour par le timer mutualisé 1 s (architecture §5.2), suspendue quand le panel est fermé. Le réglage s'applique aussi aux heures de refill (« refills Sun at 3:47 PM » vs « refills Sun at 15:47 »). | P1 |
| REQ-NUI-40 | **Opacité Liquid Glass** (`glassOpacity` 0…1) : le fond du panel est composé de couches [matériau flou → `Color.black.opacity(glassOpacity)` → contenu]. À `1.0` (« Opaque »), le matériau de flou est **réellement retiré de la hiérarchie** (pas seulement recouvert) — gain GPU mesurable. | P1 |
| REQ-NUI-41 | **Frosted rim** (`frostedRim`) : liseré de 1 pt en `strokeBorder` dégradé (blanc 0,25 → 0,05, haut → bas) sur le pourtour du panel ; togglable. | P1 |
| REQ-NUI-42 | **Depth-lit** (`depthLitEnabled`) : cartes en relief (ombre externe basse + lumière interne haute) et puits en creux (ombre interne simulée par `strokeBorder` sombre flouté clippé) pour les jauges et zones encastrées ; togglable. | P2 |
| REQ-NUI-43 | **Opacité des métriques** (`metricsOpacity` 0…1, défaut 0,85) : opacité du texte des métriques secondaires (tokens, compteurs, temps écoulé) pour régler la lisibilité sur le fond sombre. | P2 |
| REQ-NUI-44 | Tout changement d'un réglage d'Appearance s'applique **immédiatement** (< 1 frame après la mutation de `SettingsStore`), sans réouverture du panel (« mises à jour immédiates au changement de réglage »). | P0 |
| REQ-NUI-45 | **Rendu Liquid Glass** : le fond du panel passe par le modificateur `agentGlass(shape:opacity:)` — branche `#available(macOS 26.0, *)` → `glassEffect(_:in:)`, sinon fallback `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `state: .active`) wrappé en `NSViewRepresentable`. Le **pill n'utilise jamais** de matériau (noir pur, REQ-NUI-24). | P0 |

### 2.7 Animations

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-46 | Ouverture pill → panel : `.spring(response: 0.42, dampingFraction: 0.8)` (léger rebond) ; fermeture : `.spring(response: 0.45, dampingFraction: 1.0)` (aucun rebond). Les rayons de `NotchShape` sont animés conjointement (`animatableData`). | P0 |
| REQ-NUI-47 | Le contenu du panel entre avec la transition `.scale(0.8, anchor: .top).combined(with: .opacity)` et sort symétriquement ; le fond noir déborde de `−50 pt` pour que l'overshoot du ressort ne découvre jamais un bord. | P0 |
| REQ-NUI-48 | Premier affichage d'une fenêtre notch : fenêtre créée non affichée, animation SwiftUI lancée, puis `orderFrontRegardless()` avec fondu `alphaValue` 0 → 1 en 0,15 s (`NSAnimationContext`). Fermeture de fenêtre (toggle off, écran retiré) : repli SwiftUI, fondu 1 → 0, puis `orderOut`. | P1 |
| REQ-NUI-49 | **Changement de session / mutations de liste** (animations v0.2.11) : insertion/retrait/réordonnancement de cartes animés par `.spring(response: 0.35, dampingFraction: 0.85)` avec identités stables (`Session.id`) ; le remplacement visuel d'une session `/clear` par sa successeure est un cross-fade + glissement de 8 pt, sans saut de layout. | P1 |
| REQ-NUI-50 | Hover sur le pill (avant ouverture) : léger grossissement des ailes (`.interactiveSpring(response: 0.38, dampingFraction: 0.8)`, +2 pt de hauteur) comme affordance. L'ombre portée (`.shadow`, radius 10 → 20, opacité 0,5 → 0,8) n'est rendue qu'aux états hover/ouvert. | P2 |
| REQ-NUI-51 | **Reduced Motion** (`accessibilityReduceMotion`) : les ressorts sont remplacés par `.easeOut(duration: 0.15)`, les transitions de contenu par un fondu simple, les avatars pixel-grid figés sur une frame statique, le shimmer de refresh remplacé par un changement d'opacité. | P1 |

### 2.8 Avatars pixel-grid

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-52 | Avatar de session : grille **5×5** (motif identicon stable dérivé de `hash(SessionID)`, symétrie verticale — spécification canonique : 07-sessions.md §3.3 et REQ-SES-17) rendue en `TimelineView(.animation(minimumInterval: 1/20))` + `Canvas`, 24×24 pt (mise à l'échelle par densité). Animations par état : **vague diagonale** quand `executing` (1,2 Hz) et `thinking` (0,5 Hz, amplitude réduite), **rotation calme** quand `waiting`, **rendu statique atténué** quand `idle`/`ended` (aucun tick). [HYPOTHÈSE — rendu AgentPeek non inspectable ; constantes à calibrer visuellement.] | P0 |
| REQ-NUI-53 | Teinte de l'avatar = couleur de l'état (§4.5) ; l'état est indiqué par **couleur + mouvement** (jamais couleur seule — accessibilité daltonisme). | P0 |
| REQ-NUI-54 | Les avatars des **cartes de session** sont **en pause** (`paused: true`) quand le panel est fermé, quand la carte est hors du viewport de scroll, ou quand la session est `idle`/`ended`. **Exception** : l'unique avatar agrégé du **pill** (REQ-NUI-25) reste animé panel fermé, à fréquence réduite (10 fps max), et est figé si toutes les sessions sont `idle` ou si Reduced Motion est actif. Le budget CPU idle < 0,5 % (architecture A9) s'entend avec ce seul avatar pill actif. | P0 |

### 2.9 Focus clavier & accessibilité

| ID | Exigence | Priorité |
|---|---|---|
| REQ-NUI-55 | À l'apparition d'un prompt actionnable dans le panel ouvert, `panel.makeKey()` est appelé (sans activation de l'app) pour router les frappes vers le panel ; à la disparition du prompt ou à la fermeture du panel, le panel `resignKey()` et le focus revient à l'app frontale. Le panel ne devient jamais key en dehors de ces cas et du clic dans un champ texte. | P0 |
| REQ-NUI-56 | Quand une question avec réponse texte libre s'affiche, le champ reçoit le focus automatiquement (`makeKey()` + `@FocusState`) ; Échap rend le focus (resignKey) sans fermer le panel ; Tab circule entre les contrôles du prompt. | P1 |
| REQ-NUI-57 | **VoiceOver** : le pill est un élément d'accessibilité unique dont le label agrège l'état (ex. « AgentDash. 2 sessions running, 1 waiting for permission ») avec l'action « Expand panel » ; chaque carte de session, jauge et bouton du panel porte `accessibilityLabel`/`accessibilityValue` explicites ; l'apparition d'un prompt poste une annonce `.announcement`. | P1 |
| REQ-NUI-58 | **Reduce Transparency** (`accessibilityReduceTransparency`) : force le rendu Opaque (équivalent `glassOpacity = 1.0`) indépendamment du réglage. | P2 |
| REQ-NUI-59 | Tous les contrôles du panel ont une cible de clic ≥ 24×24 pt, y compris en densité `.compact`. | P1 |

---

## 3. Conception technique

### 3.1 Types et API publiques (package `NotchUI`)

```swift
// MARK: - Fenêtre

public final class NotchPanel: NSPanel {
    public override var canBecomeKey: Bool { true }     // REQ-NUI-02
    public override var canBecomeMain: Bool { false }
    // init : styleMask [.borderless, .nonactivatingPanel], configuration REQ-NUI-01/03/04
}

// MARK: - Coordination multi-écrans (MainActor, possédé par la composition root)

@MainActor
public final class NotchSurfaceCoordinator {
    public init(sessions: SessionStore, prompts: PromptStore, usage: UsageStore,
                servers: ServerStore, settings: SettingsStore, license: LicenseStore)
    public func start()          // création des fenêtres, abonnements écran/veille
    public func stop()           // repli + orderOut (toggle notchEnabled off)
    public func open(reason: NotchOpenReason)   // .hover, .click, .attention, .settingsMirror
    public func close(reason: NotchCloseReason) // .hoverExit, .clickOutside, .clickNotch, .programmatic
}

public enum NotchOpenReason: Sendable { case hover, click, attention, settingsMirror }
public enum NotchCloseReason: Sendable { case hoverExit, clickOutside, clickNotch, programmatic }

// MARK: - État par écran

@MainActor @Observable
public final class NotchViewModel {
    public enum SurfaceState: Equatable { case pill, opening, panel, closing }
    public private(set) var state: SurfaceState = .pill
    public var geometry: NotchGeometry           // recalculée à chaque reconfiguration
    public var isHoveringPill: Bool = false
    public var keyFocusOwner: KeyFocusOwner = .none  // .none / .prompt / .textField
}

// MARK: - Géométrie

public struct NotchGeometry: Equatable, Sendable {
    public let screenUUID: String
    public let hasPhysicalNotch: Bool
    public let notchSize: CGSize          // .zero → fausse encoche (REQ-NUI-13)
    public let pillRestSize: CGSize       // notch + débord +4 pt, ou 190 × hauteur barre de menus (min 24)
    public func pillSize(mode: PillWidthMode, usageMode: Bool, hideWhenIdle: Bool,
                         isIdle: Bool) -> CGSize
    public func panelSize(width: PanelWidth, contentHeight: CGFloat,
                          sizing: ListSizing, screenVisibleHeight: CGFloat) -> CGSize
    public static let shadowPadding: CGFloat = 20
    public static let overshootBleed: CGFloat = 50   // REQ-NUI-47
}

extension NSScreen {
    var notchSize: CGSize { /* formule safeAreaInsets + auxiliaryTop*Area, cf. recherche §3.1 */ }
    var isBuiltinDisplay: Bool { /* CGDisplayIsBuiltin */ }
    var displayUUID: String? { /* CGDisplayCreateUUIDFromDisplayID */ }
    var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}

// MARK: - Forme (variante MIT de DynamicNotchKit — pas de code GPL)

public struct NotchShape: Shape {
    public var topCornerRadius: CGFloat      // fermé 6, ouvert 19
    public var bottomCornerRadius: CGFloat   // fermé 14, ouvert 24
    public var animatableData: AnimatablePair<CGFloat, CGFloat> { get set }
    public func path(in rect: CGRect) -> Path  // 4 addQuadCurve, cf. recherche §5.1
}

// MARK: - Rendu verre

public extension View {
    /// macOS 26 : glassEffect(.regular, in: shape). Avant : VisualEffectView(.hudWindow, .behindWindow)
    /// + Color.black.opacity(opacity). opacity == 1.0 → branche opaque SANS matériau (REQ-NUI-40).
    func agentGlass(in shape: some Shape, opacity: Double) -> some View
}

// MARK: - Avatar (spécification canonique : 07-sessions.md §3.3)

public struct PixelAvatarView: View {
    public init(seed: UInt64, state: SessionState, paused: Bool, sideLength: CGFloat = 24)
    // TimelineView(.animation(minimumInterval: 1/20, paused: paused)) + Canvas 5×5 (identicon
    // seedé par SessionID) ; teinte = token d'état §4.5. Avatar agrégé du pill : instance dédiée
    // à minimumInterval 1/10 (REQ-NUI-54).
}

// MARK: - Densité

public struct DensityMetrics: Sendable {
    public let rowHeight: CGFloat, sectionSpacing: CGFloat, cardPadding: CGFloat
    public let titleFont: Font, bodyFont: Font, metricFont: Font, avatarSide: CGFloat
    public static func metrics(for density: Density, titleWeight: TitleWeight) -> DensityMetrics
}
```

Le contenu des sections (2)–(7) est injecté par la composition root sous forme de vues conformes à un protocole `NotchSectionProviding` (une vue + un booléen `isEmpty`), pour respecter la règle « NotchUI ne dépend que de DashCore » (architecture §3.2).

### 3.2 Hover à délai d'intention (algorithme, REQ-NUI-18)

```swift
@State private var hoverTask: Task<Void, Never>?

func handleHover(_ hovering: Bool) {
    hoverTask?.cancel()
    if hovering {
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.8)) {
            vm.isHoveringPill = true                                   // affordance REQ-NUI-50
        }
        guard vm.state == .pill else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(settings.hoverIntentDelayMs)) // intention
            guard !Task.isCancelled, vm.state == .pill, vm.isHoveringPill else { return }
            coordinator.open(reason: .hover)
        }
    } else {
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))             // hystérésis fixe
            guard !Task.isCancelled else { return }
            withAnimation { vm.isHoveringPill = false }
            guard vm.state == .panel, !settingsWindowIsKey,            // REQ-NUI-21 exception
                  vm.keyFocusOwner != .textField else { return }       // REQ-NUI-22
            coordinator.close(reason: .hoverExit)
        }
    }
}
```

Le `.onHover` est posé sur un `.contentShape(NotchShape(...))` qui suit la taille courante : la zone réactive grandit avec le panel (hystérésis géométrique naturelle). Aucune autre zone de la fenêtre n'est hit-testable (REQ-NUI-08).

### 3.3 Machine à états d'expansion

```
                    hover ≥ delay │ clic pill │ attention (auto-expand) │ settingsMirror
        ┌─────────┐ ──────────────────────────────────────────────────► ┌─────────┐
        │  pill   │                                                     │ opening │──┐ fin de
        └─────────┘ ◄──┐                                                └─────────┘  │ ressort
             ▲         │ fin de ressort                                      │ open() │
             │         │                                              inversé│        ▼
        ┌─────────┐    │      hoverExit (100 ms) │ clic extérieur │      ┌─────────┐
        │ closing │◄───┴──────── clic zone notch │ close()  ◄─────────── │  panel  │
        └─────────┘                                                      └─────────┘
   Interruptions : open() pendant closing → opening (le ressort repart de la valeur courante) ;
                   close() pendant opening → closing. Aucune file d'attente d'animations.
   Gardes de fermeture : settingsWindowIsKey == true → close() ignoré (REQ-NUI-21) ;
                         keyFocusOwner == .textField → hoverExit ignoré (REQ-NUI-22).
```

### 3.4 Séquence auto-expand sur attention (REQ-NUI-20)

```
agent → agentdash-hook → HookServer → EventRouter → PromptStore (MainActor)
                                                        │ pendingPrompts.append(p)
                                                        ▼
                            NotchSurfaceCoordinator.observePrompts()   (withObservationTracking)
                                                        │ autoExpandOnAttention && promptHandling ≠ .terminalOnly
                                                        ▼
                    open(reason: .attention) ── état .opening, ressort 420 ms ──► .panel
                                                        │
                                                        ▼
                    panel.makeKey()  (REQ-NUI-55 : hotkeys ⌘A/⌘N/⌥A actives, app frontale inchangée)
                                                        │
                                                        ▼
                    scrollTo(sectionID: .prompt, anchor: .top)
   Budget : événement hook → premier frame de l'animation < 150 ms (chaîne mesurée ≈ 25 ms, A9).
```

### 3.5 Fermeture au clic extérieur — `EventMonitors`

Singleton MainActor possédant un moniteur **global** + un moniteur **local** limités à `.leftMouseDown` (pas de `mouseMoved` global : le hover est déjà couvert par `.onHover`, économie CPU). À chaque clic : si `state == .panel` et `!panelScreenRect.contains(NSEvent.mouseLocation)` et `!settingsWindowIsKey` → `close(reason: .clickOutside)`. Les moniteurs ne sont installés que lorsqu'au moins un panel est ouvert (démontés sinon).

### 3.6 Reconfiguration d'écrans (REQ-NUI-15)

```
didChangeScreenParametersNotification / didWakeNotification
  → snapshot = { screen.displayUUID : (frame, notchSize) pour chaque NSScreen.screens }
  → si snapshot == précédent → rien
  → sinon : mémoriser l'état (panel ouvert ? prompt affiché ?)
            détruire toutes les NotchPanel (orderOut sans animation)
            résoudre les écrans porteurs selon settings.preferredScreen
              .builtinThenMain : builtin notché sinon .main
              .uuid(u)         : écran d'UUID u s'il existe, sinon fallback .builtinThenMain
              .active          : écran de NSScreen.main
            recréer NotchPanel + NotchViewModel par écran porteur, repositionner (REQ-NUI-07)
            restaurer l'état d'expansion (panel rouvert sans animation si un prompt est actif)
```

### 3.7 Composition du fond du panel (couches, REQ-NUI-40/41/42/45)

```
ZStack(alignment: .top) {                       // clipShape(NotchShape ouvert)
  1. agentGlass(in: shape, opacity: glassOpacity)
     ├─ #available(macOS 26): glassEffect(.regular, in: shape) + Color.black.opacity(opacity)
     ├─ sinon, opacity < 1  : VisualEffectView(.hudWindow, .behindWindow, .active)
     │                        + Color.black.opacity(opacity)
     └─ opacity == 1.0      : Color.black          // matériau ABSENT de la hiérarchie
  2. contenu (sections) — padding(-50) sur le fond noir seul (anti-overshoot)
  3. frostedRim ? strokeBorder(LinearGradient(.white 0.25 → 0.05), lineWidth: 1) : rien
  4. Rectangle noir 1 pt aligné .top (couture d'anticrénelage, REQ-NUI-24)
}
.shadow(color: .black.opacity(state == .panel ? 0.8 : 0), radius: 20)   // jamais NSWindow.hasShadow
```

---

## 4. Spécification UX/UI

### 4.1 Pill — layout (état fermé, écran notché, variante count)

```
        ◄─ aile gauche ─►◄────── découpe physique (notch) ──────►◄─ aile droite ─►
┌───────┬───────────────┬───────────────────────────────────────┬───────────────┬───────┐
│ +2 pt │ ▓▓ avatar 14pt│              (noir pur,               │  « 3 »  12 pt │ +2 pt │
│ débord│  état agrégé  │        LED caméra à droite : vide)    │ sess. actives │ débord│
└───────┴───────────────┴───────────────────────────────────────┴───────────────┴───────┘
Hauteur = safeAreaInsets.top (notché) ; rayons (6, 14) ; marge interne ≥ 8 pt côté découpe.
Mode usage : ailes remplacées par 1 à 3 mini-jauges batterie (22×7 pt, espacement 6 pt, sans
texte, tooltip au survol — spécification canonique : 09 §4.2), largeur verrouillée Wide/Ultra-wide.
Écran externe : même dessin sur base 190 × max(menuBarHeight, 24) pt, ras du bord supérieur.
```

### 4.2 Panel — layout (densité regular, largeur normal 640 pt)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ⟳ (refresh, shimmer pendant refresh)                             14:32      │  header 28 pt
│──────────────────────────────────────────────────────────────────────────────│
│  ┌ PENDING PROMPT ────────────────────────────────────────────────────────┐  │  si prompt
│  │ (contenu spécifié dans le document « actions inline » ; boutons :      │  │
│  │  Allow ⌘A · Deny ⌘N · Always Allow ⌥A · Deny with feedback…)           │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│  SESSIONS                                                                    │  titres de
│  ┌ my-project ────────────────────────────────────────────────────────────┐  │  section 11 pt
│  │ ▓▓ avatar 24  Fixing auth flow        24.6k / 66   +120 −34   2m       │  │  .uppercase
│  │ (cartes : cf. document sessions/timeline ; hauteur regular 52 pt)      │  │  tracking 0.6
│  └────────────────────────────────────────────────────────────────────────┘  │
│  USAGE                                                                       │
│  [jauge 5 h ▓▓▓▓▓░░ 64 % · resets in 2h 14m] [7 j ▓▓░ 31 % · refills Sun…]  │
│  LOCAL SERVERS                                                               │
│  :3000  Next.js · my-project · 2h 14m                     [Open][Copy][Stop] │
│  QUICK ROUTES   Skills · Plugins · Config · Logs · Hooks · Root              │
│  FAST ACTIONS   [ ▶ build & test ]  [ ▶ deploy preview ]                     │
└──────────────────────────────────────────────────────────────────────────────┘
Padding externe 16 pt ; espacement inter-sections 12 pt (regular). Coins (19, 24).
```

### 4.3 Textes exacts de l'interface (anglais)

Vérifiés dans les features : « Show more » / « Show less », « Copy Session as Markdown », « resets in … », « refills Sun at 3:47 PM », « $X of $Y », « -- » (usage indisponible), « Deny with feedback ». Fixés par ce document [HYPOTHÈSE — wording AgentPeek exact non inspectable] : titres de section « SESSIONS », « USAGE », « LOCAL SERVERS », « QUICK ROUTES », « FAST ACTIONS » ; boutons de prompt « Allow », « Deny », « Always Allow », « Approve », « Reject », « Answer », « Open Terminal » ; état vide sessions « No active sessions — start an agent in your terminal or IDE » ; état vide serveurs : « No local servers » + « Dev servers on ports 3000–9999 will show up here. » (source canonique : 10-local-servers.md §4.4) ; trial expiré « Trial ended — Unlock AgentDash » (pill grisée).

### 4.4 États visuels du pill

| Condition | Rendu |
|---|---|
| ≥ 1 session `waiting` ou `PendingPrompt` | avatar/point **orange**, pulsation d'échelle 1,0 → 1,15 (1 s, ease-in-out, répétée ; figée si Reduced Motion) |
| ≥ 1 session `executing` | avatar **vert**, vague diagonale |
| ≥ 1 session `thinking` (aucune executing) | avatar **cyan**, vague diagonale lente (0,5 Hz au lieu de 1,2 Hz) |
| toutes `idle` | avatar **gris**, statique atténué (avatar pill figé, REQ-NUI-54) ; masqué si `pillHideWhenIdle` |
| `trialExpired` | contenu désaturé, opacité 0,5, pas d'animation |
| usage mode | jauges batterie vert → jaune (≥ 70 %) → rouge (≥ 90 %), teinte de seuil près de la limite |

### 4.5 Couleurs d'état (tokens `DashCore`, teintes adoucies v0.1.8)

`stateExecuting` vert (#34C759 atténué), `stateThinking` cyan (#5AC8FA atténué), `stateWaiting` orange (#FF9F0A), `stateIdle` gris (#98989D), `stateError` rouge (#FF453A) [HYPOTHÈSE — valeurs exactes AgentPeek inconnues ; contraste ≥ 3:1 sur fond noir exigé].

### 4.6 Table de densité (REQ-NUI-37) [HYPOTHÈSE — à calibrer]

| Métrique | compact | regular | colossal |
|---|---|---|---|
| Hauteur de carte session | 40 pt | 52 pt | 68 pt |
| Avatar | 18 pt | 24 pt | 32 pt |
| Police titre / corps / métriques | 12 / 11 / 10 | 13 / 12 / 11 | 16 / 14 / 13 |
| Espacement inter-sections | 8 pt | 12 pt | 16 pt |
| Padding de carte | 8 pt | 10 pt | 14 pt |

### 4.7 Récapitulatif des animations

| Animation | Courbe | Durée effective |
|---|---|---|
| Ouverture pill → panel | `.spring(response: 0.42, dampingFraction: 0.8)` | ≈ 420 ms |
| Fermeture panel → pill | `.spring(response: 0.45, dampingFraction: 1.0)` | ≈ 450 ms, sans rebond |
| Hover pill (affordance) | `.interactiveSpring(response: 0.38, dampingFraction: 0.8)` | ≈ 380 ms |
| Entrée du contenu du panel | `.scale(0.8, anchor: .top) + .opacity` | liée à l'ouverture |
| Fondu de fenêtre (création/destruction) | `alphaValue` linéaire | 150 ms |
| Mutations de liste de sessions | `.spring(response: 0.35, dampingFraction: 0.85)` | ≈ 350 ms |
| Remplacement `/clear` | cross-fade + glissement 8 pt | 300 ms |
| Pulsation d'attention | échelle 1,0 ↔ 1,15, ease-in-out répétée | période 1 s |
| Shimmer refresh usage | balayage de dégradé linéaire répété | période 1,2 s |
| Progression de jauge | `.easeOut` | 250 ms |
| Largeur Auto du pill | `.spring(response: 0.35, dampingFraction: 0.9)` | ≈ 350 ms |

---

## 5. Cas limites & gestion d'erreurs

1. **Écran builtin en résolution supprimant la safe area** (`safeAreaInsets.top == 0` sur dalle notchée) : basculer sur la fausse encoche (REQ-NUI-13) — jamais de `guard` qui masquerait la surface [HYPOTHÈSE — cas rapporté par des utilisateurs, à reproduire].
2. **Barre de menus auto-masquée** : sur écran notché, `safeAreaInsets.top` reste correct (notch physique) ; sur écran externe, `menuBarHeight == 0` → plancher 24 pt, l'encoche flotte au-dessus du contenu (assumé, documenté).
3. **App fullscreen** : le panel reste visible (`.fullScreenAuxiliary`) ; sur écran externe sans barre de menus visible, la fausse encoche flotte — comportement v1 assumé, option de masquage en P2.
4. **Clamshell / écran débranché à chaud** : l'écran porteur disparaît → reconfiguration (§3.6) ; si `preferredScreen == .uuid` introuvable, fallback `.builtinThenMain` sans erreur visible ; un prompt actif force la réouverture du panel sur le nouvel écran.
5. **Changement de résolution pendant panel ouvert** : reconstruction avec restauration d'état ; le contenu ne doit jamais apparaître décentré par rapport à la découpe (recalcul de `notchSize` obligatoire).
6. **Réveil de veille** : `didWakeNotification` → même chemin que la reconfiguration (les frames d'écran peuvent avoir changé pendant le sommeil).
7. **Hover pendant `closing`** : ré-ouverture immédiate depuis la valeur courante du ressort (interruptible), pas de repli complet préalable (REQ-NUI-17).
8. **Prompt arrivant panel fermé + `autoExpandOnAttention == false`** : pas d'ouverture ; le pill passe en état attention (pulsation orange) ; l'ouverture reste manuelle.
9. **Prompt arrivant pendant que l'utilisateur tape dans le champ réponse d'un autre prompt** : pas de vol de focus (le `makeKey()` n'est pas répété) ; le nouveau prompt s'empile visuellement sous le premier.
10. **Clic extérieur pendant la frappe** : le panel se ferme (choix assumé : le clic est une intention forte) mais le brouillon de réponse est conservé dans `PromptStore` et restauré à la réouverture.
11. **Fenêtre Settings key** : ni hoverExit ni clic extérieur ne ferment le panel (REQ-NUI-21) ; la fermeture par clic sur la zone du notch reste possible.
12. **Deux écrans notchés** (builtin + Sidecar/ASD) : un seul porteur en v1 selon `preferredScreen` ; pas de double surface tant que REQ-NUI-16 n'est pas livrée.
13. **LED caméra active** : aucune dégradation — la zone est déjà réservée (REQ-NUI-30).
14. **Menu Apple/items sous la fenêtre invisible** : clics traversants garantis (REQ-NUI-08) ; test manuel dédié (critère AC-10).
15. **`glassOpacity` modifié pendant l'ouverture** : recomposition sans à-coup (la couche noire est animée par `.animation(.easeOut(0.25), value:)`, le matériau n'est ajouté/retiré qu'aux bornes 1.0).
16. **Reduced Motion + auto-expand** : l'ouverture reste fonctionnelle (fondu 150 ms au lieu du ressort).
17. **VoiceOver + panel non-activant** : le curseur VoiceOver peut atteindre les éléments du panel même sans activation [HYPOTHÈSE — interaction VoiceOver/`nonactivatingPanel` à valider tôt sur prototype ; plan B : activer l'app temporairement quand VoiceOver est détecté (`NSWorkspace.isVoiceOverEnabled`)].
18. **Perte du statut key pendant un prompt** (l'utilisateur clique dans son IDE) : les hotkeys SwiftUI cessent ; les hotkeys Carbon éphémères prennent le relais (document « actions inline ») ; le panel reste ouvert.
19. **Écran verrouillé** : surface invisible (pas d'API privées) — aucun état corrompu au déverrouillage (les timers d'horloge se resynchronisent via le tick suivant).
20. **Mission Control / bascule de Space** : `.stationary` garantit l'immobilité ; vérifier l'absence de flash à l'arrivée sur un nouveau Space (connu des trois projets de référence comme réglé par cette combinaison).
21. **Storage de `hoverIntentDelayMs` hors bornes** (édition manuelle des defaults) : clamp 0–2000 ms à la lecture.
22. **Fermeture de l'app** : `stop()` replie et détruit les fenêtres avant la fin de `applicationWillTerminate` ; les moniteurs `NSEvent` sont retirés (pas de fuite de handlers).

---

## 6. Critères d'acceptation

- **AC-01 (non-activation)** — Étant donné VS Code au premier plan avec le curseur dans l'éditeur, quand je clique sur le pill puis sur une carte de session, alors le panel s'ouvre et VS Code reste l'app active (son curseur texte clignote toujours), et aucune icône AgentDash n'apparaît dans le Dock.
- **AC-02 (délai d'intention)** — Étant donné le pill fermé et `hoverIntentDelayMs = 200`, quand je traverse le notch avec la souris en < 200 ms, alors le panel ne s'ouvre pas ; quand je stationne ≥ 200 ms, alors il s'ouvre ; quand je sors puis rentre en < 100 ms panel ouvert, alors il ne se ferme pas (aucun flicker).
- **AC-03 (auto-expand)** — Étant donné `autoExpandOnAttention = true` et le panel fermé, quand un `PermissionRequest` arrive, alors l'animation d'ouverture démarre en < 150 ms, la section prompt est visible en tête, et ⌘A fonctionne immédiatement sans cliquer dans le panel.
- **AC-04 (Settings garde le panel ouvert)** — Étant donné le panel ouvert et la fenêtre Settings key, quand je déplace la souris hors du panel ou clique dans Settings, alors le panel reste ouvert ; quand je ferme Settings et clique sur le bureau, alors il se ferme.
- **AC-05 (fausse encoche)** — Étant donné un écran externe sans notch défini comme porteur, quand AgentDash démarre, alors une encoche noire (~190 pt, hauteur de la barre de menus) apparaît au ras du bord supérieur centré, avec hover/clic/panel identiques à l'écran notché.
- **AC-06 (reconfiguration)** — Étant donné le panel ouvert sur l'écran builtin, quand je branche/débranche un écran externe ou change la résolution, alors la surface est reconstruite sans crash, correctement centrée sur la découpe, et rouverte si un prompt était affiché.
- **AC-07 (pill usage mode)** — Étant donné `pillUsageMode = true`, quand le pill est fermé, alors les mini-jauges batterie live s'affichent dans les ailes (1 à 3 : Claude 5 h, Claude 7 j, Cursor mensuel selon les toggles et le compte prioritaire, cf. 09 §4.2), la largeur est verrouillée (le picker Auto est indisponible dans Settings), et un changement de mesure Cursor met les jauges à jour immédiatement.
- **AC-08 (hide when idle)** — Étant donné `pillHideWhenIdle = true` et toutes les sessions idle, alors le pill ne montre aucune aile ; quand une session passe `executing`, alors les ailes réapparaissent en fondu ≤ 300 ms.
- **AC-09 (Opaque)** — Étant donné `glassOpacity = 1.0`, quand j'inspecte la hiérarchie (Xcode View Debugger), alors aucune `NSVisualEffectView` n'est présente sous le panel ; à 0,55, elle est présente et active.
- **AC-10 (click-through)** — Étant donné le pill fermé sur un écran notché, quand je clique sur un menu de la barre de menus situé sous la zone invisible de la fenêtre (à gauche du pill), alors le menu s'ouvre normalement.
- **AC-11 (growable)** — Étant donné `sessionListSizing = .growable` et 15 sessions, alors le panel grandit jusqu'à `visibleFrame.height − 40 pt` puis la liste scrolle à la molette sans que le panel soit key.
- **AC-12 (avatars et budget)** — Étant donné le panel fermé et 3 sessions actives, alors la consommation CPU d'AgentDash reste < 0,5 % (avatars des cartes en pause, seul l'avatar agrégé du pill animé à 10 fps max) ; panel ouvert, les avatars des cartes s'animent (vague pour executing/thinking, rotation pour waiting, statique pour idle/ended) à ≤ 20 fps.
- **AC-13 (Reduced Motion)** — Étant donné « Réduire les animations » activé dans macOS, quand j'ouvre/ferme le panel et qu'un prompt arrive, alors toutes les transitions sont des fondus ≤ 150 ms et les avatars sont statiques.
- **AC-14 (immédiateté des réglages)** — Étant donné le panel ouvert et Settings ouvert à côté, quand je change densité, largeur, graisse de titre, frosted rim ou opacité des métriques, alors le panel reflète chaque changement instantanément sans réouverture.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances entrantes** (ce que NotchUI consomme) :
- `plan/01-architecture.md` — décisions A4 (NSPanel non-activant key-able), A6 (`agentGlass()`), A9 (budgets), threading §5 (stores MainActor observés).
- `plan/02-data-model.md` — `Session`, `SessionState`, `PendingPrompt`, `AppSettings` (tous les réglages d'Appearance cités ici y sont définis), `LicenseState`.
- Document **hooks/IPC** du plan — la latence hook → PromptStore conditionne REQ-NUI-20.
- Document **sessions & timeline** — contenu des cartes et de la session étendue hébergées dans la section (3).
- Document **actions inline** — contenu de la section prompt, raccourcis ⌘A/⌘N/⌥A/⌥T, hotkeys Carbon éphémères (NotchUI fournit `makeKey`/`resignKey` et l'ancrage visuel).
- Documents **usage**, **serveurs**, **Quick Routes/Fast Actions** — vues des sections (4)–(7) via `NotchSectionProviding`.
- Document **settings** — l'onglet Appearance pilote tous les réglages consommés ici ; « prompt handling location » conditionne REQ-NUI-20/33.

**Risques** :
1. **VoiceOver × panel non-activant** (cas limite 17) : comportement incertain — prototype d'accessibilité à faire dès le squelette de fenêtre. Mitigation : activation temporaire de l'app si VoiceOver actif.
2. **Dimensions et wording** : la majorité des valeurs visuelles (largeurs, densités, textes) sont des hypothèses faute d'accès à AgentPeek — prévoir une passe de calibrage visuel sur captures publiques du site.
3. **`.statusBar + 3` vs overlays système** (Spotlight, Centre de notifications) : niveau retenu moins agressif que `.screenSaver` ; vérifier qu'aucun overlay système légitime ne passe *sous* le pill de façon gênante [HYPOTHÈSE].
4. **Coût GPU du matériau** en `behindWindow` sur grand panel Ultra-wide : mesuré tard = refonte risquée ; instrumenter tôt (auto-mesure Doctor, A9).
5. **REQ-NUI-28/29** : sémantiques « hide when idle »/« expanded only » hypothétiques — valider contre le comportement réel d'AgentPeek (vidéos/démos publiques) avant de figer.
6. **Sur-notification `didChangeScreenParametersNotification`** (peut tirer en rafale) : le diff de snapshot (§3.6) est la protection ; à tester en dock/undock répété.

---

## 8. Découpage en tâches

| # | Tâche | Contenu | Taille |
|---|---|---|---|
| N1 | Fenêtre & géométrie | `NotchPanel`, extensions `NSScreen` (notchSize, displayUUID, menuBarHeight), positionnement, fausse encoche, `orderFrontRegardless`, click-through (REQ-NUI-01…13) | **M** |
| N2 | Multi-écrans & cycle de vie | `NotchSurfaceCoordinator`, résolution des écrans porteurs, reconfiguration/veille avec restauration d'état, toggle `notchEnabled` (REQ-NUI-14…16) | **M** |
| N3 | Machine à états & interactions | `NotchViewModel`, hover à délai d'intention, clic, `EventMonitors` clic extérieur, exceptions Settings/champ texte, interruptibilité (REQ-NUI-17…23) | **L** |
| N4 | `NotchShape` & animations socle | forme animable, ressorts ouverture/fermeture, transitions de contenu, fondus de fenêtre, anti-overshoot, ombre SwiftUI (REQ-NUI-46…48) | **M** |
| N5 | Pill complet | variantes count/usage/hide-when-idle/expanded-only, largeurs Auto/Wide/Ultra-wide, états visuels, zone LED, pill grisé trial (REQ-NUI-24…31) | **L** |
| N6 | Panel conteneur | header (horloge 12/24 h, refresh + shimmer), sections injectées `NotchSectionProviding`, scroll sans focus, fixed/growable, états vides (REQ-NUI-32…36, 39) | **L** |
| N7 | Rendu verre & Appearance | `agentGlass()` (fallback + branche macOS 26), couche d'opacité + Opaque réel, frosted rim, depth-lit, `DensityMetrics`, graisse de titre, opacité des métriques, application immédiate (REQ-NUI-37, 38, 40…45) | **L** |
| N8 | Avatars pixel-grid | `PixelAvatarView` (Canvas 5×5 identicon, vague/rotation/statique, ≤ 20 fps, pause cartes + fréquence réduite pill), intégration pill + cartes, teintes d'état (REQ-NUI-52…54) | **M** |
| N9 | Focus clavier | `makeKey`/`resignKey` pilotés par PromptStore, `@FocusState` du champ réponse, Échap/Tab, `keyFocusOwner` (REQ-NUI-55, 56) | **M** |
| N10 | Accessibilité & animations de liste | VoiceOver (labels, annonce, prototype non-activant), Reduced Motion/Transparency, cibles 24 pt, animations de mutations de sessions et `/clear` (REQ-NUI-49…51, 57…59) | **M** |
| N11 | Calibrage & performance | passe visuelle sur références publiques AgentPeek, mesure CPU/GPU (avatars en pause, Opaque), validation des budgets A9, checklist AC-01…14 | **M** |

Ordre recommandé : N1 → N3 → N4 (squelette interactif de bout en bout, prototype VoiceOver du risque n°1 inclus) → N5/N6 en parallèle → N7 → N8/N9 → N2 → N10 → N11. Total indicatif : 4 tâches L, 6 M, 1 M de calibrage.
