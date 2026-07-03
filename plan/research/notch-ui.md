# Recherche technique — UI dans le notch macOS pour AgentDash (nom provisoire)

> **Statut** : recherche préalable à l'implémentation. Rédigée le 3 juillet 2026.
> **Sources principales** : lecture intégrale du code source de trois projets open-source clonés localement (boring.notch, NotchDrop, DynamicNotchKit), documentation Apple, articles techniques de référence.
> **Convention** : chaque affirmation est marquée **[VÉRIFIÉ]** (code source inspecté ou doc officielle) ou **[HYPOTHÈSE]** (à valider en implémentation). AgentPeek n'étant pas installé sur cette machine et son code étant fermé, tout ce qui concerne son implémentation interne est par définition **[HYPOTHÈSE]**.

---

## 1. Projets open-source étudiés

| | boring.notch | NotchDrop | DynamicNotchKit |
|---|---|---|---|
| URL | github.com/TheBoredTeam/boring.notch | github.com/Lakr233/NotchDrop | github.com/MrKai77/DynamicNotchKit |
| Licence | **GPL-3.0** ⚠️ | MIT | MIT |
| Cible | macOS 14+ | macOS notché (11+) | macOS 13+ |
| Classe fenêtre | `NSPanel` (2 variantes) | `NSWindow` | `NSPanel` |
| `styleMask` | `[.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]` | `[.borderless, .fullSizeContentView]` | `[.borderless, .nonactivatingPanel]` |
| `level` | `.mainMenu + 3` (= 27) | `.statusBar + 8` (= 33) | `.screenSaver` (= 1000) |
| `canBecomeKey` | `false` | `true` (+ `NSApp.activate`) | `true` |
| Taille de fenêtre | Fixe : taille panel ouvert + marge ombre (640 × 210) | Fixe : largeur écran × 200 pt en haut | Demi-écran, recréée à chaque affichage |
| Hover | SwiftUI `.onHover` + délai `Task.sleep` | Moniteurs globaux `NSEvent` (`mouseMoved`) | SwiftUI `.onHover` |
| Fermeture clic extérieur | `.onHover` (sortie) | Moniteur global `leftMouseDown` + test de rect | Non géré (API programmatique) |
| Multi-écrans | Une fenêtre par écran (UUID d'affichage) | Une fenêtre (écran builtin prioritaire) | Fenêtre recréée sur l'écran demandé |

⚠️ **Licence** : boring.notch est sous **GPL-3.0** — on peut s'inspirer des techniques mais **aucune copie de code** dans AgentDash si la distribution n'est pas GPL. NotchDrop et DynamicNotchKit sont MIT (réutilisation possible avec attribution). **[VÉRIFIÉ]**

Aucun des trois projets n'utilise `NSTrackingArea` : le hover est géré soit par SwiftUI `.onHover`, soit par moniteurs `NSEvent` globaux. **[VÉRIFIÉ]** (grep exhaustif sur les trois dépôts)

---

## 2. Configuration de la fenêtre

### 2.1 Les trois recettes réelles

**NotchDrop — `NotchWindow.swift`** (sous-classe `NSWindow`) **[VÉRIFIÉ]** :

```swift
class NotchWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isOpaque = false
        alphaValue = 1
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = NSColor.clear
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        level = .statusBar + 8   // commentaire du code original : « kills ibar lol »
        hasShadow = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

**boring.notch — `BoringNotchWindow.swift`** (sous-classe `NSPanel`) **[VÉRIFIÉ]** :

```swift
class BoringNotchWindow: NSPanel {
    // ... init identique, plus :
    isFloatingPanel = true
    isReleasedWhenClosed = false
    level = .mainMenu + 3
    collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    hasShadow = false
    // Créée avec : styleMask [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

La variante `BoringNotchSkyLightWindow` ajoute `appearance = NSAppearance(named: .darkAqua)` (apparence sombre forcée, cohérent avec un notch noir) et `sharingType = .none` optionnel pour **masquer le notch des enregistrements d'écran**. **[VÉRIFIÉ]**

**DynamicNotchKit — `DynamicNotchPanel.swift`** **[VÉRIFIÉ]** :

```swift
final class DynamicNotchPanel: NSPanel {
    // styleMask: [.borderless, .nonactivatingPanel]
    hasShadow = false
    backgroundColor = .clear
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .stationary]
    override var canBecomeKey: Bool { true }
}
```

### 2.2 Analyse des choix

- **`NSPanel` + `.nonactivatingPanel`** : cliquer dans le panel n'active pas l'app (pas de vol de focus à l'IDE de l'utilisateur — critique pour AgentDash où l'utilisateur code pendant que les agents tournent). NotchDrop fait l'inverse (`NSWindow` + `NSApp.activate(ignoringOtherApps: true)` à l'ouverture), ce qui **vole le focus de l'app frontale** — à éviter pour nous. **[VÉRIFIÉ]**
- **Niveaux de fenêtre** (valeurs `CGWindowLevel` sous-jacentes : `.mainMenu` = 24, `.statusBar` = 25, `.screenSaver` = 1000) : il faut être **au-dessus de la barre de menus** pour que le pill dessiné autour du notch la recouvre. `.statusBar + N` ou `.mainMenu + N` suffisent. `.screenSaver` (DynamicNotchKit) fonctionne mais passe au-dessus de *tout* (y compris certains overlays système) — plus agressif que nécessaire. **[VÉRIFIÉ]** pour les usages, **[HYPOTHÈSE]** sur les effets de bord précis de `.screenSaver`.
- **`collectionBehavior`** : le quatuor `[.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]` est la combinaison éprouvée : visible sur tous les Spaces, visible par-dessus les apps fullscreen, immobile pendant Mission Control, exclue du cycle ⌘`. **[VÉRIFIÉ]**
- **`isOpaque = false` + `backgroundColor = .clear` + `hasShadow = false`** : la fenêtre est un « canevas » transparent ; la forme noire du notch est dessinée en SwiftUI à l'intérieur, l'ombre aussi (`.shadow(...)` SwiftUI). `hasShadow = true` sur une fenêtre non rectangulaire produit des artefacts de bord — tous les projets le désactivent. **[VÉRIFIÉ]**
- **Hébergement SwiftUI** : `window.contentView = NSHostingView(rootView: ContentView().environmentObject(vm))` (boring.notch) ou `NSHostingController` comme `contentViewController` (NotchDrop). Les deux marchent ; `NSHostingView` direct est plus simple. **[VÉRIFIÉ]**
- **Recouvrement du notch** : la fenêtre est positionnée pour que son bord supérieur coïncide avec `screen.frame.maxY` ; la forme SwiftUI, alignée `.top` et centrée horizontalement, se superpose exactement au notch physique (qui est une découpe d'écran : tout pixel dessiné en noir s'y fond visuellement) :

```swift
// boring.notch — positionWindow(_:on:changeAlpha:)  [VÉRIFIÉ]
window.setFrameOrigin(NSPoint(
    x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
    y: screenFrame.origin.y + screenFrame.height - window.frame.height
))
```

- **Affichage sans activation** : `window.orderFrontRegardless()` (et non `makeKeyAndOrderFront`). **[VÉRIFIÉ]**
- **Hit-testing / click-through** : aucun projet n'utilise `ignoresMouseEvents`. Les zones SwiftUI **totalement transparentes ne participent pas au hit-testing** : les clics passent aux fenêtres dessous. Preuve dans NotchDrop, qui doit utiliser `Color.black.opacity(0.001)` pour rendre sa zone de détection de drag cliquable (commentaire du code : « 0.001 is the smallest we can have »). Pour rendre une zone interactive, on lui donne un `.contentShape(Rectangle())`. **[VÉRIFIÉ]**
- **Lock screen / au-dessus de tout** : boring.notch utilise l'API privée `CGSSpace` (`CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel` au niveau max 2147483647) et le framework privé SkyLight (`SLSRemoveWindowsFromSpaces`) pour rester visible sur l'écran de verrouillage. **API privées → risque App Store et fragilité entre versions macOS ; à éviter pour AgentDash** (pas de besoin d'écran verrouillé). **[VÉRIFIÉ]** que c'est leur technique ; recommandation de l'éviter.

---

## 3. Géométrie du notch

### 3.1 Calcul de la taille exacte **[VÉRIFIÉ]**

Les trois projets convergent sur la même formule (doc Apple : `NSScreen.safeAreaInsets`, `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`) :

```swift
extension NSScreen {
    /// Taille du notch physique ; .zero si absent (NotchDrop, Ext+NSScreen.swift)
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else { return .zero }
        let notchHeight = safeAreaInsets.top
        let leftPadding  = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        guard leftPadding > 0, rightPadding > 0 else { return .zero }
        return CGSize(width: frame.width - leftPadding - rightPadding, height: notchHeight)
    }

    /// L'écran est-il la dalle intégrée du MacBook ?
    var isBuiltinDisplay: Bool {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return CGDisplayIsBuiltin(id.uint32Value) == 1
    }
}
```

Points importants :
- `safeAreaInsets.top` vaut **0 sur un écran sans notch** ; sur un écran notché il vaut la hauteur du notch (= hauteur de la barre de menus, que le notch impose). **[VÉRIFIÉ]**
- boring.notch ajoute un jeu de `+4 pt` à la largeur calculée (`notchWidth = frame.width - left - right + 4`) pour que le pill dessine légèrement plus large que la découpe et masque les liserés d'anticrénelage. NotchDrop utilise au contraire un `inset` de `-4` sur le rect de détection. Prévoir un petit débord réglable. **[VÉRIFIÉ]**
- La hauteur de la barre de menus se calcule par `screen.frame.maxY - screen.visibleFrame.maxY` (utilisé par DynamicNotchKit `menubarHeight` et boring.notch mode `matchMenuBar`). **[VÉRIFIÉ]**

### 3.2 Fausse encoche sur écran externe **[VÉRIFIÉ]**

- **NotchDrop** : si `notchSize == .zero`, taille arbitraire `150 × 28`, positionnée au ras du bord supérieur, centrée.
- **DynamicNotchKit** : `notchFrameWithMenubarAsBackup` → largeur arbitraire 300, hauteur = hauteur de la barre de menus, style visuel différent (`NotchlessView` : fenêtre flottante arrondie avec `NSVisualEffectView`, glissant depuis le haut).
- **boring.notch** : hauteur configurable (`Defaults[.nonNotchHeight]`, ou `matchMenuBar`), largeur par défaut 185 pt.
- **AgentPeek** (« positionné au ras du bord supérieur sur écran externe (simule un notch) », cf. AGENTPEEK_FEATURES.md §2.2) : correspond au modèle NotchDrop/boring.notch — dessiner le même pill noir collé en haut. **[HYPOTHÈSE]** sur ses dimensions exactes ; recommandation : hauteur = hauteur barre de menus de l'écran, largeur ≈ 185–200 pt.

### 3.3 Multi-écrans, résolution, barre de menus masquée, fullscreen

- **Identification stable des écrans** : `CGDisplayCreateUUIDFromDisplayID` (extension `NSScreen.displayUUID` de boring.notch) — les `NSScreen` sont invalidés à chaque reconfiguration, l'UUID persiste. **[VÉRIFIÉ]**
- **Reconfiguration** : s'abonner à `NSApplication.didChangeScreenParametersNotification` ; boring.notch compare l'ensemble `{UUID}` + les `frame` de tous les écrans et, si changement, **détruit et recrée** les fenêtres puis les repositionne. NotchDrop recrée systématiquement sa fenêtre. Le changement de résolution (résolutions « à l'échelle ») **modifie la largeur du notch en points** → recalculer `notchSize` à chaque notification. **[VÉRIFIÉ]**
- **Choix de l'écran** : NotchDrop privilégie l'écran builtin s'il a un notch, sinon `.main`. boring.notch offre « écran préféré » (UUID mémorisé), « suivre l'écran actif » (`NSScreen.main` = écran de la fenêtre key), ou « tous les écrans » (une fenêtre + un view model par UUID). **[VÉRIFIÉ]**
- **Barre de menus auto-masquée** : `visibleFrame.maxY == frame.maxY` dans ce cas → `menubarHeight` calculé vaut 0. Ne jamais dériver la hauteur du pill *uniquement* de la barre de menus ; sur écran notché, `safeAreaInsets.top` reste correct même barre masquée (le notch est physique). Sur écran externe avec barre auto-masquée, la fausse encoche flotte au-dessus du contenu des apps — prévoir une hauteur minimale fixe. **[VÉRIFIÉ]** pour le calcul, **[HYPOTHÈSE]** sur le comportement produit souhaité.
- **Apps fullscreen** : `.fullScreenAuxiliary` rend la fenêtre visible par-dessus les Spaces fullscreen. Sur écran notché, le notch physique reste là en fullscreen, donc le pill reste pertinent. boring.notch propose en plus de **cacher le pill en fullscreen** (détection par écran via le package MacroVisionKit, `FullScreenMonitor.spaceChanges()` → dictionnaire `[screenUUID: Bool]`) avec réduction de la hauteur effective à 0. Pour AgentDash v1 : garder le pill affiché (comportement AgentPeek apparent), option de masquage plus tard. **[VÉRIFIÉ]** pour les techniques.

---

## 4. Interactions

### 4.1 Hover avec délai d'intention (anti-flicker)

Deux approches observées :

**A. SwiftUI `.onHover` + tâche annulable (boring.notch — `ContentView.swift`) [VÉRIFIÉ]** — c'est le modèle qui correspond au « délai d'intention court au survol » d'AgentPeek (v0.1.20) :

```swift
@State private var hoverTask: Task<Void, Never>?
@State private var isHovering = false

private func handleHover(_ hovering: Bool) {
    hoverTask?.cancel()
    if hovering {
        withAnimation(animationSpring) { isHovering = true }
        guard vm.notchState == .closed, Defaults[.openNotchOnHover] else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration])) // délai d'intention
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard vm.notchState == .closed, isHovering else { return }
                doOpen()
            }
        }
    } else {
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(100))   // hystérésis à la sortie
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(animationSpring) { isHovering = false }
                if vm.notchState == .open { vm.close() }
            }
        }
    }
}
```

Les trois ingrédients anti-flicker : (1) **délai d'ouverture** configurable (intention), (2) **délai de fermeture** court (100 ms) pour tolérer les sorties/rentrées rapides du curseur, (3) **annulation systématique** de la tâche précédente. Le `.onHover` est posé sur un `.contentShape(Rectangle())` couvrant la forme du notch, donc la zone réactive suit l'état (pill petit / panel grand) — hystérésis géométrique naturelle.

**B. Moniteur global `mouseMoved` (NotchDrop — `EventMonitors.swift`) [VÉRIFIÉ]** : un `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` + `addLocalMonitorForEvents` publie `NSEvent.mouseLocation` dans un `CurrentValueSubject` Combine ; le view model teste `deviceNotchRect.insetBy(dx: inset, dy: inset).contains(mouseLocation)`. Avantage : fonctionne même quand la fenêtre n'a aucun contenu hit-testable ; inconvénient : événements souris globaux en continu (coût CPU faible mais non nul) et coordonnées globales à convertir.

**Recommandation AgentDash** : approche A (SwiftUI `.onHover`), suffisante car la fenêtre couvre déjà la zone du notch, + moniteur global limité au `leftMouseDown` pour la fermeture extérieure (cf. 4.4). Les moniteurs globaux souris **ne requièrent pas** de permission Accessibilité (contrairement au `keyDown` global). **[VÉRIFIÉ]** pour mouseDown/mouseMoved sans permission ; **[VÉRIFIÉ]** que le keyDown global exige l'Accessibilité.

### 4.2 Clic pour étendre, animation pill → panel

**Technique centrale commune aux trois projets [VÉRIFIÉ]** : la **fenêtre ne change jamais de taille**. Elle est créée d'emblée à la taille maximale du panel ouvert (+ marge pour l'ombre), transparente ; seule la **forme SwiftUI interne** est animée entre les deux tailles. Cela évite totalement le redimensionnement de `NSWindow` (coûteux, saccadé, non synchronisé avec CoreAnimation).

```swift
// boring.notch — sizing/matters.swift  [VÉRIFIÉ]
let shadowPadding: CGFloat = 20
let openNotchSize: CGSize = .init(width: 640, height: 190)
let windowSize: CGSize = .init(width: openNotchSize.width,
                               height: openNotchSize.height + shadowPadding)
```

Ressorts utilisés **[VÉRIFIÉ]** :
- boring.notch : ouverture `.spring(response: 0.42, dampingFraction: 0.8)`, fermeture `.spring(response: 0.45, dampingFraction: 1.0)` (fermeture sans rebond !), déplacement/hover `.interactiveSpring(response: 0.38, dampingFraction: 0.8)`.
- NotchDrop : `.interactiveSpring(duration: 0.5, extraBounce: 0.25, blendDuration: 0.125)`.
- DynamicNotchKit : ouverture `.bouncy(duration: 0.4)`, fermeture `.smooth(duration: 0.4)`.
- Le contenu du panel entre avec une transition composée : `.scale(scale: 0.8, anchor: .top).combined(with: .opacity)` (boring.notch) ou `.blur + .scale + .opacity` (DynamicNotchKit).

**Anti-saccade au premier affichage (DynamicNotchKit) [VÉRIFIÉ]** : créer la fenêtre **sans** l'afficher, démarrer l'animation SwiftUI, puis `orderFrontRegardless()` avec fondu `alphaValue` 0→1 en 0,15 s (`NSAnimationContext.runAnimationGroup`). À la fermeture, symétrique : animation SwiftUI de repli, puis fondu 1→0, puis fermeture réelle de la fenêtre.

**Événement de clic** : `.onTapGesture { doOpen() }` sur le `contentShape` du pill (boring.notch), ou test de rect sur moniteur global `mouseDown` (NotchDrop). Le clic sur le pill ouvre ; re-clic sur la zone du notch ferme (NotchDrop). **[VÉRIFIÉ]**

### 4.3 Scroll dans le panel

Aucune technique spéciale nécessaire : un `ScrollView` SwiftUI dans le panel reçoit les événements de molette même si la fenêtre n'est pas key (comportement AppKit standard : les scroll events suivent la position du curseur). boring.notch utilise aussi un `panGesture` custom basé sur `NSEvent` scrollWheel pour ouvrir/fermer au geste (extension `PanGesture.swift`). Pour la liste de sessions AgentDash (hauteur « growable » jusqu'à l'écran puis scroll, cf. features §10 Appearance), c'est un `ScrollView` + `frame(maxHeight:)` calculé sur `screen.visibleFrame.height`. **[VÉRIFIÉ]** pour le scroll sans focus ; **[HYPOTHÈSE]** sur le sizing exact d'AgentPeek.

### 4.4 Fermeture au clic extérieur **[VÉRIFIÉ]**

Modèle NotchDrop (moniteur global + local `leftMouseDown`) :

```swift
events.mouseDown.receive(on: DispatchQueue.main).sink { [weak self] _ in
    guard let self else { return }
    let mouseLocation = NSEvent.mouseLocation
    if status == .opened, !notchOpenedRect.contains(mouseLocation) {
        notchClose()          // clic hors du panel → fermeture
    }
}
```

Alternative (panel activable) : surcharger `resignMain()`/`resignKey()` pour fermer à la perte de focus (recette Cindori). Moins fiable pour nous car le panel non-activant n'est key que transitoirement. **Recommandation : moniteur global.**

### 4.5 Focus clavier dans un panel non-activant (champ de réponse aux questions)

C'est le point le plus délicat pour AgentDash (réponse texte inline aux questions de l'agent, raccourcis ⌘A/⌘N/⌥A quand une permission s'affiche).

Recette vérifiée (article Cindori « Floating Panel », doc Apple `.nonactivatingPanel`) **[VÉRIFIÉ]** :

```swift
final class NotchPanel: NSPanel {
    // styleMask contient .nonactivatingPanel
    override var canBecomeKey: Bool { true }   // requis pour le focus des champs texte
    override var canBecomeMain: Bool { false } // main inutile pour un overlay
}
// À la création :
panel.becomesKeyOnlyIfNeeded = true  // ne devient key QUE si un contrôle le demande
```

- Avec `.nonactivatingPanel`, le panel peut devenir **key window sans activer l'app** : l'app frontale (IDE, terminal) garde son statut actif, mais les frappes clavier vont au panel tant qu'il est key. C'est exactement le besoin « répondre sans switcher de fenêtre ».
- `becomesKeyOnlyIfNeeded = true` : le clic dans le champ `TextField` rend le panel key ; un clic sur un bouton ne le fait pas.
- Pour donner le focus programmatiquement (ex. auto-focus du champ quand une question apparaît) : `panel.makeKey()` + `@FocusState` SwiftUI ou `panel.makeFirstResponder(...)`.
- Pour les **raccourcis ⌘A/⌘N pendant l'affichage d'une permission** : deux options — (a) rendre le panel key à l'expansion (les `keyDown` arrivent alors au panel, gérables par `.keyboardShortcut` SwiftUI) ; (b) raccourcis globaux via Carbon `RegisterEventHotKey` (package KeyboardShortcuts, utilisé par boring.notch — sans permission Accessibilité). **[HYPOTHÈSE]** : AgentPeek utilise probablement (a) quand le panel est ouvert ; la stratégie (b) est nécessaire pour des raccourcis actifs panel fermé.
- ⚠️ Piège : `canBecomeKey = true` + `makeKey()` retire le statut key à la fenêtre de l'app frontale (le curseur texte de l'IDE cesse de clignoter) même si l'app reste active. Rendre le panel key **seulement à la demande** (focus champ, permission affichée), et le rendre (`resignKey`) à la fermeture. **[HYPOTHÈSE]** comportementale à valider.

---

## 5. Rendu

### 5.1 Forme du notch et coins arrondis

Deux techniques observées pour les coins supérieurs « qui épousent » le notch (congés concaves vers l'extérieur, comme le vrai notch) :

**A. `Shape` custom avec courbes quadratiques (DynamicNotchKit `NotchShape.swift`, repris par boring.notch) [VÉRIFIÉ]** — la référence :

```swift
struct NotchShape: Shape {
    var topCornerRadius: CGFloat      // congé concave haut (vers l'extérieur)
    var bottomCornerRadius: CGFloat   // arrondi convexe bas

    var animatableData: AnimatablePair<CGFloat, CGFloat> { // rayons animables
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .init(x: rect.minX, y: rect.minY))
        // congé haut-gauche : courbe du bord supérieur VERS l'intérieur
        p.addQuadCurve(to: .init(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
                       control: .init(x: rect.minX + topCornerRadius, y: rect.minY))
        p.addLine(to: .init(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        p.addQuadCurve(to: .init(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
                       control: .init(x: rect.minX + topCornerRadius, y: rect.maxY))
        p.addLine(to: .init(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        p.addQuadCurve(to: .init(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
                       control: .init(x: rect.maxX - topCornerRadius, y: rect.maxY))
        p.addLine(to: .init(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        p.addQuadCurve(to: .init(x: rect.maxX, y: rect.minY),
                       control: .init(x: rect.maxX - topCornerRadius, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
```

Rayons de référence **[VÉRIFIÉ]** (boring.notch `cornerRadiusInsets`) : fermé `(top: 6, bottom: 14)`, ouvert `(top: 19, bottom: 24)`. DynamicNotchKit : fermé `(6, 14)`, ouvert `(15, 20)`. Règle d'or documentée dans DynamicNotchKit : `rayon externe = rayon interne + padding`.

**B. Masques avec `blendMode(.destinationOut)` (NotchDrop)** : rectangle noir aux coins inférieurs arrondis + deux overlays qui « creusent » les congés supérieurs. Plus complexe, aucune raison de la préférer. **[VÉRIFIÉ]**

Détails de finition **[VÉRIFIÉ]** :
- boring.notch superpose une ligne noire de 1 pt en haut (`overlay(alignment: .top) { Rectangle().fill(.black).frame(height: 1) }`) pour masquer la couture d'anticrénelage entre la forme et le bord d'écran.
- DynamicNotchKit place le fond noir avec `.padding(-50)` pour que le rebond du ressort (overshoot) ne découvre jamais un bord.
- L'ombre est appliquée seulement à l'état ouvert/hover : `.shadow(color: .black.opacity(0.5→0.8), radius: 10→20)`.
- `preferredColorScheme(.dark)` sur toute la hiérarchie (fond noir permanent).

### 5.2 « Liquid Glass » et stratégie de fallback

- **macOS 26 (Tahoe)** : API SwiftUI `glassEffect(_:in:)` et AppKit `NSGlassEffectView` — matériau Liquid Glass officiel. **Indisponible avant macOS 26.** **[VÉRIFIÉ]** (doc Apple).
- **Cible AgentDash = macOS 14+** → le rendu de base doit être fait **sans** `glassEffect`, avec :
  - `NSVisualEffectView` wrappé (le pattern exact de DynamicNotchKit) :

    ```swift
    struct VisualEffectView: NSViewRepresentable {
        let material: NSVisualEffectView.Material      // .hudWindow, .popover, .underWindowBackground…
        let blendingMode: NSVisualEffectView.BlendingMode // .behindWindow pour flouter ce qui est derrière
        func makeNSView(context: Context) -> NSVisualEffectView {
            let v = NSVisualEffectView()
            v.material = material
            v.blendingMode = blendingMode
            v.state = .active        // sinon le flou se désactive quand l'app est inactive
            v.isEmphasized = true
            return v
        }
        func updateNSView(_: NSVisualEffectView, context: Context) {}
    }
    ```

  - ou les matériaux SwiftUI (`.ultraThinMaterial`…) qui reposent dessus.
- **Slider d'opacité (feature AgentPeek, avec option « Opaque »)** : composer le fond en couches — `Color.black.opacity(sliderValue)` par-dessus le `VisualEffectView` ; à 1.0 (« Opaque »), remplacer par un noir plein (et poser `layerUsesCoreImageFilters` à rien : plus de flou → gain GPU). **[HYPOTHÈSE]** sur l'implémentation AgentPeek, technique standard.
- **« Frosted rim », profondeur, interface depth-lit** (cartes en relief, puits en creux) : réalisable en pur SwiftUI —
  - liseré : `RoundedRectangle(...).strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)` ;
  - relief (carte) : ombre externe portée bas + fine lumière interne haut ;
  - creux (puits) : « ombre interne » simulée par un `strokeBorder` sombre flouté clippé dans la forme (`.stroke(.black.opacity(0.6), lineWidth: 4).blur(radius: 4).clipShape(...)` en overlay) — pattern classique, macOS 14 n'ayant pas d'API d'ombre interne native.
  **[HYPOTHÈSE]** sur le style exact AgentPeek.
- **Adoption progressive** : `if #available(macOS 26.0, *) { view.glassEffect(.regular, in: shape) } else { fallback }` derrière un modificateur maison `agentGlass()`. Décision documentée : ne pas monter la cible de déploiement pour ça.
- ⚠️ Piège `behindWindow` : le flou échantillonne ce qui est **derrière la fenêtre**. Derrière le pill fermé se trouve… le notch physique (noir) et la barre de menus — le flou n'y apporte rien ; réserver le matériau au panel étendu, garder le pill en noir pur (il doit se fondre dans la découpe). **[VÉRIFIÉ]** pour le comportement de `behindWindow`, recommandation produit.

### 5.3 Avatars pixel-grid animés

Aucun des trois projets n'a d'équivalent exact (boring.notch a une « face » animée en SwiftUI pur). Le rendu AgentPeek (« vague diagonale quand actif, rotation calme en attente », features §3.2) se reproduit efficacement avec **`TimelineView(.animation)` + `Canvas`** — dessin immédiat sans invalidation de vue par cellule. **[HYPOTHÈSE]** (design AgentPeek non inspectable), technique SwiftUI standard :

```swift
struct PixelGridAvatar: View {
    enum Mode { case activeWave, idleRotation }
    let mode: Mode
    let tint: Color
    private let n = 8 // grille 8×8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let cell = size.width / CGFloat(n)
                for y in 0..<n {
                    for x in 0..<n {
                        let alpha: Double
                        switch mode {
                        case .activeWave:
                            // vague diagonale : phase proportionnelle à (x + y), défilement temporel
                            let phase = Double(x + y) * 0.5 - t * 6.0
                            alpha = 0.25 + 0.75 * max(0, sin(phase))
                        case .idleRotation:
                            // rotation calme : angle de la cellule vs angle animé lentement
                            let ang = atan2(Double(y) - 3.5, Double(x) - 3.5)
                            alpha = 0.3 + 0.5 * max(0, cos(ang - t * 0.8))
                        }
                        let r = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                       width: cell - 1, height: cell - 1)
                        ctx.fill(Path(r), with: .color(tint.opacity(alpha)))
                    }
                }
            }
        }
        .frame(width: 24, height: 24)
    }
}
```

Bonnes pratiques : limiter à ~30 fps (`minimumInterval`), **mettre en pause** (`paused:`) quand le notch est fermé ou la session idle-profonde, et mutualiser un seul `TimelineView` parent pour N avatars si la liste est longue (perfs : AgentPeek annonce des timelines à « des milliers d'entrées »).

---

## 6. Menu bar

### 6.1 `NSStatusItem` à longueur variable **[VÉRIFIÉ]**

```swift
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
if let button = statusItem.button {
    button.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "AgentDash")
    button.imagePosition = .imageLeading
    button.title = " 24.6k / 66"          // texte d'usage — la longueur s'adapte
    // Ou : button.attributedTitle pour styler (police monospacedDigit, couleur)
}
```

`variableLength` redimensionne l'item selon son contenu (doc Apple + usage boring.notch). Pour un rendu riche (jauges, point orange), héberger du SwiftUI dans le bouton :

```swift
let hosting = NSHostingView(rootView: MenuBarSummaryView(model: model))
hosting.frame = NSRect(x: 0, y: 0, width: 90, height: 22)
statusItem.button?.addSubview(hosting)
// puis ajuster statusItem.length (ou la frame) quand le contenu change
```

⚠️ `MenuBarExtra` SwiftUI (macOS 13+) est plus simple mais son label est rendu en **template** (monochrome) : impossible d'y afficher un **point orange** coloré de façon fiable, et le clic droit n'est pas différenciable. **AgentDash a besoin des deux → `NSStatusItem` AppKit.** **[VÉRIFIÉ]** pour les limitations, recommandation qui en découle.

### 6.2 Clic gauche → popover, clic droit → menu Quit **[VÉRIFIÉ]**

```swift
statusItem.button?.action = #selector(statusItemClicked(_:))
statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

@objc func statusItemClicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit AgentDash", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu                 // assignation temporaire :
        statusItem.button?.performClick(nil)   // ouvre le menu au bon endroit
        statusItem.menu = nil                  // sinon le menu détournerait le clic gauche
    } else {
        togglePopover()
    }
}
```

(Le pattern « assigner `menu` temporairement puis le retirer » est la solution standard car `statusItem.menu` non-nil capture *tous* les clics ; `popUpMenu` est déprécié.)

### 6.3 Popover : `NSPopover` vs fenêtre ancrée

- **`NSPopover`** avec `behavior = .transient` : se ferme automatiquement au clic ailleurs / sur une autre app — correspond exactement au comportement AgentPeek (« se ferme au clic sur une autre app », features §2.2). Contenu : `popover.contentViewController = NSHostingController(rootView: ...)`. Affichage : `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`. Inconvénient : chrome système (flèche, matériau) peu personnalisable.
- **Fenêtre ancrée détachée** (petit `NSPanel` non-activant positionné sous l'item via `button.window?.convertToScreen(...)`) : style 100 % custom (pour un look « Liquid Glass » cohérent avec le notch), mais fermeture extérieure et positionnement multi-écrans à refaire à la main (le même moniteur global `mouseDown` que le notch peut être réutilisé).
- **Positionnement multi-écrans/Spaces** : `NSPopover` suit l'item automatiquement (la barre de menus existe sur chaque écran, l'item apparaît sur celui où l'utilisateur clique). Une fenêtre ancrée doit calculer sa position à chaque affichage depuis `button.window?.frame`. **[VÉRIFIÉ]** pour les mécanismes.
- **Recommandation** : commencer avec `NSPopover` `.transient` (comportement AgentPeek reproduit gratuitement), migrer vers un panel custom seulement si le style l'exige. **[HYPOTHÈSE]** : AgentPeek semble utiliser un popover système ou imitation proche (« popover avec sections plates »).

### 6.4 Point d'attention orange

Dans le `NSHostingView` du bouton : un `Circle().fill(.orange).frame(width: 7, height: 7)` en overlay du label, animé (`.transition(.scale)`) quand `hasPendingAttention` passe à vrai. Si l'on reste en `NSImage` pur : composer l'image par `NSImage(size:flipped:drawingHandler:)` avec `isTemplate = false` pour préserver la couleur orange. **[HYPOTHÈSE]** sur le rendu AgentPeek exact, techniques standard.

---

## 7. Pièges connus (synthèse)

1. **Spaces / Mission Control** : sans `.stationary` + `.ignoresCycle`, la fenêtre glisse pendant les transitions de Space et apparaît dans le cycle de fenêtres. Avec `.canJoinAllSpaces`, elle est présente partout sans clignotement. **[VÉRIFIÉ]**
2. **Fullscreen** : sans `.fullScreenAuxiliary`, la fenêtre disparaît dans les Spaces plein écran. La barre de menus n'y est visible qu'au survol du bord : la fausse encoche externe flottera au-dessus du contenu. **[VÉRIFIÉ]** / comportement produit à trancher.
3. **Webcam active** : la LED verte de la caméra est **physique, dans le notch** — aucune fenêtre ne peut la recouvrir. Ne rien dessiner d'important à l'extrémité droite intérieure du pill (zone LED) ; le pill noir « autour » du notch reste correct. **[VÉRIFIÉ]** pour le caractère matériel de la LED.
4. **Vol de focus** : `NSApp.activate(ignoringOtherApps: true)` à l'ouverture (modèle NotchDrop) interrompt la frappe de l'utilisateur dans son IDE. À proscrire ; tout faire en `.nonactivatingPanel` + `orderFrontRegardless()`. **[VÉRIFIÉ]**
5. **`keyDown` global** : `addGlobalMonitorForEvents(matching: .keyDown)` exige la permission Accessibilité. Utiliser Carbon `RegisterEventHotKey` (package KeyboardShortcuts) pour les raccourcis globaux, et le statut key du panel pour les raccourcis contextuels. **[VÉRIFIÉ]**
6. **Reconfiguration d'écran** : les instances `NSScreen` deviennent obsolètes ; toujours re-résoudre par UUID (`CGDisplayCreateUUIDFromDisplayID`) et reconstruire fenêtres/positions sur `didChangeScreenParametersNotification` (déclenchée aussi par le changement de résolution, dock/undock, réordonnancement). **[VÉRIFIÉ]**
7. **Écrans notchés en résolution non standard** : certains modes d'échelle suppriment la zone réservée au notch → `safeAreaInsets.top == 0` sur la dalle intégrée ; toujours passer par le fallback « fausse encoche ». **[HYPOTHÈSE]** (rapporté par des utilisateurs, non testé ici).
8. **Ombre de fenêtre** : `hasShadow = true` sur fenêtre transparente → halos et artefacts lors des animations de forme ; dessiner l'ombre en SwiftUI et prévoir la marge (`shadowPadding = 20`) dans la taille de fenêtre. **[VÉRIFIÉ]**
9. **Hit-testing involontaire** : la fenêtre invisible de 640 pt de large au-dessus de la barre de menus peut gober les clics sur les items de menu du milieu si une vue transparente est hit-testable. Ne poser `contentShape` que sur la forme visible ; vérifier que les zones vides laissent passer les clics (SwiftUI ignore les vues d'alpha 0 par défaut). **[VÉRIFIÉ]** (cf. l'astuce inverse `opacity(0.001)` de NotchDrop).
10. **Écran verrouillé** : rester visible exige des API privées (CGSSpace/SkyLight, modèle boring.notch) — hors périmètre AgentDash. **[VÉRIFIÉ]**
11. **Enregistrement d'écran** : proposer `sharingType = .none` (option « hide from screen recording » de boring.notch) — les démos/screencasts des utilisateurs d'agents IA sont fréquents. **[VÉRIFIÉ]**
12. **Performance du flou** : `NSVisualEffectView.state = .active` en permanence + grandes surfaces floutées = coût GPU continu ; l'option « Opaque » (slider à 100 %) doit désactiver réellement le matériau. **[HYPOTHÈSE]** raisonnable, à mesurer.

---

## 8. Décisions d'implémentation recommandées pour AgentDash

1. **Fenêtre** : sous-classe `NSPanel` nommée `NotchPanel` — `styleMask [.borderless, .nonactivatingPanel]`, `isFloatingPanel = true`, `level = .statusBar + 3`, `collectionBehavior [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `isReleasedWhenClosed = false`, `appearance = .darkAqua`, `canBecomeKey = true` + `becomesKeyOnlyIfNeeded = true`, `canBecomeMain = false`. (Mix boring.notch/Cindori : non-activant **et** key-able pour le champ de réponse — c'est la différence clé avec boring.notch qui n'a pas de saisie texte.)
2. **Taille fixe** : fenêtre créée à `taille max du panel (largeur Ultra-wide) + 20 pt d'ombre`, jamais redimensionnée ; toute l'animation pill↔panel en SwiftUI (`NotchShape` animable + ressorts : ouverture `.spring(response: 0.42, dampingFraction: 0.8)`, fermeture amortie `dampingFraction: 1.0`).
3. **Géométrie** : extension `NSScreen.notchSize` (formule `safeAreaInsets` + `auxiliaryTop*Area`), débord +4 pt, identification par `displayUUID`, reconstruction sur `didChangeScreenParametersNotification`. Fausse encoche externe : hauteur = barre de menus (min 24 pt), largeur ≈ 190 pt, ras du bord supérieur.
4. **Hover** : SwiftUI `.onHover` + `Task` annulable ; délai d'intention configurable (défaut ≈ 200 ms, le réglage AgentPeek « minimum hover duration » existe aussi dans boring.notch), hystérésis de fermeture 100 ms. Auto-expand sur attention = appel programmatique du même chemin `open()`.
5. **Fermeture extérieure** : singleton `EventMonitors` (modèle NotchDrop, moniteurs global + local `leftMouseDown` uniquement) + exception « fenêtre Settings a le focus » (AgentPeek garde le notch ouvert dans ce cas).
6. **Clavier** : panel rendu key à l'apparition d'une permission/question (`makeKey()` sans activation) → `.keyboardShortcut("a", modifiers: .command)` etc. en SwiftUI ; `resignKey` + retour du focus à la fermeture ; package KeyboardShortcuts (Carbon) pour les raccourcis globaux du panneau Shortcuts.
7. **Rendu** : `NotchShape` (variante MIT de DynamicNotchKit), rayons fermé `(6, 14)` / ouvert `(19, 24)` ; pill noir pur ; panel = couches [VisualEffectView `.hudWindow`/`behindWindow` → noir à opacité réglable → contenu] + liseré « frosted rim » en `strokeBorder` dégradé ; ombres internes simulées pour le depth-lit ; modificateur `agentGlass()` avec branche `#available(macOS 26.0, *)` → `glassEffect`.
8. **Avatars** : `TimelineView(.animation)` + `Canvas` 8×8, 30 fps max, pause hors visibilité, vague diagonale (actif) / rotation lente (attente).
9. **Menu bar** : `NSStatusItem` `variableLength` + `NSHostingView` dans le bouton (texte usage + point orange animé), `sendAction(on: [.leftMouseUp, .rightMouseUp])`, menu Quit temporaire au clic droit, `NSPopover` `.transient` pour le résumé.
10. **À ne pas faire** : API privées (CGSSpace/SkyLight), `NSApp.activate` à l'ouverture du notch, redimensionnement animé de `NSWindow`, `MenuBarExtra` SwiftUI pour la surface menu bar, copie de code GPL depuis boring.notch.

---

## 9. Références

- Code source cloné et inspecté (scratchpad de session) : `boring.notch` (commit HEAD au 2026-07-03), `NotchDrop`, `DynamicNotchKit`.
- Fichiers pivots : `NotchDrop/NotchWindow.swift`, `NotchDrop/NotchViewModel+Events.swift`, `NotchDrop/Ext+NSScreen.swift`, `boringNotch/components/Notch/BoringNotchWindow.swift`, `boringNotch/boringNotchApp.swift`, `boringNotch/ContentView.swift`, `boringNotch/sizing/matters.swift`, `boringNotch/extensions/NSScreen+UUID.swift`, `boringNotch/private/CGSSpace.swift`, `DynamicNotchKit/Utility/DynamicNotchPanel.swift`, `DynamicNotchKit/Utility/NSScreen+Extensions.swift`, `DynamicNotchKit/Views/NotchShape.swift`, `DynamicNotchKit/DynamicNotch/DynamicNotch.swift`.
- Doc Apple : `NSScreen.safeAreaInsets`, `NSScreen.auxiliaryTopLeftArea`, `NSWindow.StyleMask.nonactivatingPanel`, `NSGlassEffectView`, `View.glassEffect(_:in:)`.
- Articles : Cindori « Make a floating panel in SwiftUI for macOS » (recette panel non-activant + focus), philz.blog « The Curious Case of NSPanel's Nonactivating Style Mask Flag », onmyway133 « How to support right click menu to NSStatusItem ».
- Référence produit : `/Users/bastien/Documents/macos-ai-dashboard/AGENTPEEK_FEATURES.md` (§2.2, §3.2, §10 Appearance).
