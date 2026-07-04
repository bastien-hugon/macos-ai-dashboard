# 14. Onboarding & distribution

> Rédigé le 3 juillet 2026, réécrit le même jour suite à la décision « one-shot » (encart ci-dessous). Remplace `14-onboarding-licensing-distribution.md`. Conforme à `plan/01-architecture.md` (séquence de démarrage §4.3, singleton par socket) et à `plan/03-integration-claude-code.md` / `plan/04-integration-cursor.md` (moteur `HooksInstaller`, fonction « réparer »). Convention : **[VÉRIFIÉ]** = adossé à une source primaire ; **[HYPOTHÈSE — à valider]** = à confirmer en implémentation (renvoi au numéro d'hypothèse de `plan/research/distribution-licensing.md`, recherche archivée dont les sections onboarding et signature/notarisation restent partiellement pertinentes).

> **Décision one-shot (3 juillet 2026).** AgentDash est un logiciel « one-shot » : **ni trial, ni licence, ni serveur d'activation** (Worker Cloudflare / Lemon Squeezy), **ni site web ou page de téléchargement, ni mise à jour automatique** (Sparkle, appcast, canal bêta, fenêtre What's New). Zéro infrastructure distante propre. La mise à jour est un **remplacement manuel** : l'utilisateur télécharge ou builde la nouvelle version et remplace `AgentDash.app` dans `/Applications` (ou désinstalle puis réinstalle) ; au premier lancement, la resynchronisation de `~/.agentdash/bin` (fonction « réparer », fichier 03) met à jour le binaire hook, et les réglages (UserDefaults), les configurations de hooks et les sauvegardes `.bak` survivent au remplacement. Les destinations réseau restantes sont exactement **deux**, opt-out : `api.anthropic.com` (usage Claude) et `cursor.com` (usage Cursor). Le préfixe **REQ-LIC** est historique (« licensing ») et conservé pour la traçabilité : les REQ ne sont jamais renumérotés, chaque REQ supprimé laisse une pierre tombale d'une ligne.

---

## 1. Objectif & périmètre

Ce document spécifie la **première expérience** (fenêtre welcome guidée : welcome → détection des agents → installation des hooks avec vérification « Ready » → permission notifications → terminé), la **chaîne de build et de packaging** (build Xcode Release, signature Developer ID si disponible sinon ad hoc, notarisation et DMG optionnels, scripts locaux, CI optionnelle) et le **modèle de mise à jour manuelle** propre au one-shot (remplacement de l'app, resynchronisation des hooks, affichage de version, désinstallation propre).

Sections d'`AGENTPEEK_FEATURES.md` couvertes :
- **§11 Onboarding & Licensing** (partiel) : seul l'onboarding est repris (welcome guidé, installation des hooks avec statut « Ready », permission notifications). Tout le volet trial / licence / `download/latest` / Sparkle est hors périmètre (décision one-shot).
- **§2.1** (partiel) : installation des hooks au premier lancement avec statut « Ready » — l'onboarding réutilise le moteur spécifié dans `plan/03-integration-claude-code.md` et `plan/04-integration-cursor.md` ; ici, seule l'orchestration UX est spécifiée.
- **§10 Settings → About** (partiel) : affichage de la version installée. Le réglage Update disparaît avec l'auto-update.
- **§12 Privacy** (partiel) : réseau limité à deux destinations opt-out ; aucune activation, aucune télémétrie, aucun appcast.

Non repris (décision one-shot) : §11 trial/licence, §9 prompts de mise à jour et fenêtre What's New, page de téléchargement et documentation en ligne.

Hors périmètre ici : le contenu des hooks installés (fichiers 03/04), l'onglet Doctor (fichier 13), les surfaces notch/menu bar (05/06), la gestion des notifications au-delà de la demande d'autorisation (fichier 12).

---

## 2. Exigences détaillées

### A. Onboarding (fenêtre welcome)

- **REQ-LIC-01 (P0)** — Au premier lancement (marqueur `onboardingCompleted` absent des UserDefaults), AgentDash affiche la fenêtre Welcome **avant** toute autre interaction : `NSWindow` régulière, centrée, activée via `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront(_:)` malgré `LSUIElement` [HYPOTHÈSE D-L n°9 — comportement à confirmer sur macOS 26]. Le notch et le status item peuvent déjà être visibles, mais aucun prompt actionnable n'est présenté tant que l'onboarding n'est pas terminé ou fermé.
- **REQ-LIC-02 (P0)** — Étape 1 « Welcome » : nom de l'app, tagline, visuel du notch, bouton `Continue` déclenchable avec Entrée (`.keyboardShortcut(.defaultAction)`). Aucune donnée demandée.
- **REQ-LIC-03 (P0)** — Étape 2 « Connect your agents » : une carte par agent (Claude Code, Cursor) avec détection à l'affichage **et re-vérifiée à chaque retour sur l'étape** : Claude Code = existence de `~/.claude/` ; Cursor = existence de `~/.cursor/` ou de l'app (`~/Applications`/`/Applications` via `NSWorkspace.urlForApplication(withBundleIdentifier:)`). États de carte : `Not detected` (avec lien d'installation web), `Detected` (bouton `Install hooks`), `Ready`.
- **REQ-LIC-04 (P0)** — Le bouton `Install hooks` appelle **le même moteur** `HooksInstaller` (protocole `DashCore`, implémentations `AgentClaude`/`AgentCursor`) que Settings → General → Agent hooks et que Doctor. Le statut ne passe à `Ready` qu'après vérification effective : ① entrées AgentDash présentes et intactes dans `~/.claude/settings.json` / `~/.cursor/hooks.json` ; ② binaire `~/.agentdash/bin/agentdash-hook` présent et de hash conforme ; ③ socket joignable (auto-ping local aller-retour). Échec → état `error` avec message court + bouton `Retry` ; jamais de blocage de la progression.
- **REQ-LIC-05 (P0)** — Étape 3 « Notifications » : écran d'explication (valeur : être prévenu des demandes d'approbation, des seuils d'usage atteints et des fins de tâche — texte canonique fixé par `12-notifications.md` §4.3) **avant** l'appel `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` [VÉRIFIÉ — bonne pratique et API]. Boutons `Enable Notifications` et `Skip`. Refus ou Skip → progression normale ; la demande reste re-proposable depuis Settings → Notifications (avec deep-link vers Réglages Système si le statut est `denied`).
- **REQ-LIC-06 (P1)** — Étape 4 « Launch at login » (dernière étape) : toggle **désactivé par défaut** (consentement explicite requis par les guidelines Apple [VÉRIFIÉ]) ; activation via `SMAppService.mainApp.register()` ; tout affichage ultérieur de ce réglage relit l'état réel `SMAppService.mainApp.status` (jamais de cache — `AppSettings.launchAtLogin` n'est qu'une intention). Bouton `Done` (défaut, Entrée) qui termine l'onboarding.
- **REQ-LIC-07 — supprimé (étape Unlock/trial ; décision one-shot du 3 juillet 2026).**
- **REQ-LIC-08 (P0)** — Parcours minimal ≤ 3 interactions jusqu'à la première session visible (REQ-VIS-23) : `Continue` → `Install hooks` (Claude) → dès le badge `Ready`, une session lancée apparaît dans le notch ; la fin de l'onboarding (`Done` ou fermeture) compte au plus pour la troisième interaction. Chaque étape est passable (`Skip`/`Continue`), l'onboarding est fermable (⌘W / bouton de fermeture → équivaut à tout passer) et **n'est jamais le seul chemin** : chaque action est rejouable depuis Settings [VÉRIFIÉ — HIG Onboarding].
- **REQ-LIC-09 — supprimé (consentement de mise à jour automatique Sparkle ; décision one-shot du 3 juillet 2026).**
- **REQ-LIC-10 (P0)** — Le marqueur `onboardingCompleted` est posé en UserDefaults à la fin de l'étape 4 ou à la fermeture de la fenêtre ; l'onboarding ne se représente jamais automatiquement ensuite, toutes ses actions restant accessibles depuis Settings.

### B. Essai gratuit 48 h — supprimé

- **REQ-LIC-11..17 — supprimés (essai gratuit 48 h ; décision one-shot du 3 juillet 2026).**

### C. Licence one-time 15 $ — supprimé

- **REQ-LIC-18..30 — supprimés (licence one-time, activation Lemon Squeezy / Worker Cloudflare ; décision one-shot du 3 juillet 2026).**

### D. Mises à jour Sparkle — supprimé

- **REQ-LIC-31..38 — supprimés (Sparkle, appcast, canal bêta, fenêtre What's New ; décision one-shot du 3 juillet 2026).** Le modèle de remplacement manuel est spécifié en §G (REQ-LIC-51+).

### E. Pipeline de build & packaging

- **REQ-LIC-39 (P1)** — Build & signature : `xcodebuild archive` + `-exportArchive` avec `ExportOptions.plist` (`method: developer-id`) quand un certificat **Developer ID** est disponible — signe l'app **et** `agentdash-hook` embarqué dans `Contents/Helpers/` [VÉRIFIÉ — voie recommandée] ; hardened runtime + `--timestamp` actifs, `com.apple.security.get-task-allow` absent en Release, aucune exception d'entitlement attendue [HYPOTHÈSE D-L §2.1] ; vérification `codesign --verify --deep --strict --verbose=2`. **Sans certificat** (build personnelle) : signature **ad hoc** (`codesign -s -`) acceptée ; le `README` documente l'ouverture par **clic droit → Open** au premier lancement (et `xattr -d com.apple.quarantine` en dernier recours) ainsi que la copie de l'app dans `/Applications` avant lancement (évite l'App Translocation).
- **REQ-LIC-40 (P2)** — Notarisation **optionnelle** (recommandée dès qu'un certificat Developer ID existe), séquence stricte : ① export + signature app → ② `ditto` zip + `notarytool submit --wait` de l'**app** → ③ `stapler staple` app → puis, si un DMG est produit : ④ `create-dmg` avec l'app staplée → ⑤ `codesign` du DMG → ⑥ notarisation du DMG → ⑦ `stapler staple` DMG. Sur échec, `notarytool log` est systématiquement récupéré.
- **REQ-LIC-41 (P2)** — DMG **optionnel** via `create-dmg` (Homebrew) : `--volname "AgentDash"`, fenêtre 540 × 380, icône app à (140, 180), `--app-drop-link` à (400, 180) (glisser vers Applications), fond `assets/dmg-background.png` ; nommage `AgentDash-<version>.dmg`. Le zip signé/staplé reste un artefact de distribution suffisant.
- **REQ-LIC-42 — supprimé (appcast Sparkle ; décision one-shot du 3 juillet 2026).**
- **REQ-LIC-43 (P2)** — CI GitHub Actions **optionnelle** — la release locale par scripts est la voie par défaut. Si activée : workflow `release.yml` déclenché par tag `v*`, `runs-on: macos-26` (épinglé, GA février 2026 [VÉRIFIÉ]) ; secrets : `MACOS_CERTIFICATE` (p12 base64), `MACOS_CERTIFICATE_PWD`, `MACOS_CERTIFICATE_NAME`, `KEYCHAIN_PWD`, plus `ASC_KEY`/`ASC_KEY_ID`/`ASC_ISSUER_ID` si la notarisation est activée ; keychain temporaire + `security set-key-partition-list` (indispensable en headless [VÉRIFIÉ]) ; publication des artefacts via `gh release create`. Aucun déploiement de site ni d'appcast.
- **REQ-LIC-44 (P1)** — Gestion des clés : ne concerne plus que le **certificat Developer ID** — export p12 protégé par mot de passe, sauvegarde froide (gestionnaire de mots de passe), copie en secret CI seulement si la CI est activée ; le certificat est ré-émissible depuis le compte Apple Developer (perte gênante mais non critique — les builds déjà distribuées restent valides). Aucune clé privée dans le repo.
- **REQ-LIC-45 — supprimé (test de chaîne de mise à jour N−1 → N ; décision one-shot du 3 juillet 2026).**
- **REQ-LIC-46 (P1)** — Versionnage : `CFBundleShortVersionString` SemVer `0.x.y` (roadmap `00-vision-scope.md`), `CFBundleVersion` compteur entier incrémenté à chaque build de release ; script `scripts/bump-version.sh` mettant à jour les deux + la section `CHANGELOG.md` (le changelog du repo reste la source unique des notes de version, consultable sur GitHub).

### F. Page de téléchargement — supprimé

- **REQ-LIC-47..50 — supprimés (site, `/download/latest`, hébergement d'appcast, documentation en ligne ; décision one-shot du 3 juillet 2026).** Conséquence à répercuter dans les fichiers concernés : les renvois « documentation »/« FAQ » de `04`/`06`/`10`/`13` doivent pointer vers le `README`/`CHANGELOG` du repo, plus aucun lien vers un site.

### G. Mise à jour manuelle (modèle one-shot)

Le remplacement manuel de l'app est le **seul** canal de mise à jour ; il doit être sans friction et sans perte.

- **REQ-LIC-51 (P0)** — Remplacement sans perte de données : toutes les données persistantes vivent **hors du bundle** — réglages en UserDefaults (domaine du bundle id), sauvegardes `.bak` sous `~/.agentdash/backups/`, binaire hook sous `~/.agentdash/bin/`, configurations dans `~/.claude/settings.json` / `~/.cursor/hooks.json`, offsets de lecture des transcripts (recalculables au lancement — 03 · REQ-CLA-28). Remplacer `AgentDash.app` dans `/Applications` (écrasement, ou désinstallation de la seule app puis réinstallation) ne perd **aucun** réglage ni aucune sauvegarde ; l'app n'écrit jamais dans son propre bundle.
- **REQ-LIC-52 (P0)** — Resynchronisation automatique au premier lancement de la nouvelle version : le mécanisme « installer/réparer » exécuté à **chaque** démarrage (03 · REQ-CLA-01 et REQ-CLA-10 ; symétrique Cursor dans le fichier 04) compare le hash de `~/.agentdash/bin/agentdash-hook` à celui du binaire embarqué (`Contents/Helpers/`) et le recopie s'il diffère — le binaire hook est donc mis à jour **sans aucune action utilisateur** ni modification des configs (le chemin `~/.agentdash/bin/agentdash-hook` inscrit dans les configs est stable entre versions). Une installation intacte n'est pas réécrite (idempotence).
- **REQ-LIC-53 (P1)** — Settings → About affiche la version installée : ligne « Version 0.1.0 (42) » (`CFBundleShortVersionString` + `CFBundleVersion`), accompagnée d'un texte d'aide court : « Updates are manual — download or build a newer version and replace AgentDash.app in /Applications. » Aucun bouton `Check for Updates…`, aucune requête réseau liée à la version.
- **REQ-LIC-54 (P1)** — Désinstallation propre, documentée dans le `README` et outillée par Settings pour l'étape ① : ① désactivation des hooks par agent (retrait des **seules** entrées AgentDash des configs — 03 · REQ-CLA-05, symétrique Cursor) ; ② suppression de `~/.agentdash/` (binaire, backups — l'utilisateur est prévenu que les `.bak` partent avec) ; ③ suppression de `AgentDash.app` ; optionnel : `defaults delete <bundle id>`. L'ordre garantit qu'aucune config d'agent ne référence un binaire disparu.
- **REQ-LIC-55 (P1)** — Remplacement pendant qu'une session est active : l'utilisateur quitte AgentDash puis remplace l'app ; pendant l'absence de l'app, les hooks sont **fail-open** (le relais rend `exit 0` sans réponse quand le socket est absent — 03 · REQ-CLA-12) : la session Claude/Cursor continue avec les dialogues natifs de l'agent, rien ne bloque. Au lancement de la version N+1 : resynchronisation (REQ-LIC-52) puis re-scan des transcripts récents (03 · REQ-CLA-28) → la session active réapparaît dans le notch avec son état courant. Critère d'acceptation dédié en §6.4.

---

## 3. Conception technique

### 3.1 Onboarding — coordination

```swift
public enum OnboardingStep: Int, CaseIterable { case welcome, agents, notifications, launchAtLogin }

@MainActor @Observable
public final class OnboardingCoordinator {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var cards: [AgentSetupCard]      // Claude Code, Cursor

    public func advance() ; public func skip()
    public func refreshDetection()                       // ré-évaluée à chaque affichage de .agents
    public func installHooks(for agent: AgentKind) async // HooksInstaller + vérification Ready (REQ-LIC-04)
    public func requestNotifications() async -> Bool     // UNUserNotificationCenter
    public func setLaunchAtLogin(_ on: Bool)             // SMAppService.mainApp.register()/unregister()
    public func finish()                                 // pose onboardingCompleted (REQ-LIC-10)
}

public struct AgentSetupCard: Identifiable, Sendable {
    public var id: AgentKind
    public var detection: AgentDetection                 // .installed(path:) / .notDetected
    public var hookStatus: HookSetupStatus               // .notInstalled / .installing / .ready / .error(String)
}
```

La vérification « Ready » enchaîne trois checks asynchrones (fichier de config relu et parsé, hash du binaire copié, auto-ping du socket) — les mêmes primitives que le Doctor, exposées par `DoctorKit`/`DashCore`, jamais dupliquées.

### 3.2 Mise à jour manuelle — mécanique de resynchronisation

Aucun composant dédié : le modèle one-shot s'appuie entièrement sur des mécanismes déjà spécifiés ailleurs. Au démarrage (séquence `01-architecture.md` §4.3), `HooksInstaller.installOrRepair()` de chaque agent ① compare le hash du binaire embarqué (`Contents/Helpers/agentdash-hook`) à celui de `~/.agentdash/bin/agentdash-hook` et recopie **atomiquement** (fichier temporaire + `rename`, pour qu'un hook déclenché à mi-copie n'exécute jamais un binaire tronqué) s'il diffère ; ② vérifie/répare les entrées de config par fusion idempotente (03 §2.1). La version affichée dans About est lue du bundle (`CFBundleShortVersionString`/`CFBundleVersion`) — aucun état de version persistant, aucun réseau.

### 3.3 Pipeline — scripts

`scripts/release.sh` (exécutable localement et par la CI : archive → export → vérification codesign → zip `ditto`) ; `scripts/notarize.sh` (P2 : `notarytool` + `stapler` + `notarytool log` sur échec) ; `scripts/make-dmg.sh` (P2 : `create-dmg` + codesign) ; `scripts/bump-version.sh` (versions + section `CHANGELOG.md`) ; `ci/ExportOptions.plist` (`method: developer-id`, `teamID`). Le workflow optionnel `ci/release.yml` (P2) orchestre : checkout → import certificat (keychain temporaire) → `release.sh` (+ `notarize.sh`/`make-dmg.sh` si activés) → `gh release create v<version> <artefacts> --notes-file relnotes.md`. Aucun déploiement distant (pas de site, pas d'appcast).

---

## 4. Spécification UX/UI

Tous les textes d'interface en anglais (fidèles à AgentPeek quand connus — textes canoniques `00-vision-scope.md` §4 ; le reste est notre rédaction, cohérente avec le ton du produit).

### 4.1 Fenêtre Welcome (onboarding)

Fenêtre 640 × 480 pt, non redimensionnable, centrée, fond `agentGlass()`. Indicateur de progression discret (points) en bas ; navigation `Continue` (défaut, Entrée) / `Skip` (texte, discret) ; bouton retour chevron dès l'étape 2.

| Étape | Contenu | Textes exacts |
|---|---|---|
| 1. Welcome | icône app, visuel du pill animé | « **Welcome to AgentDash** » · « Your coding agents, in the Mac notch. » · `Continue` |
| 2. Agents | 2 cartes verticales (icône agent, nom, statut, action) | « **Connect your agents** » · carte : « Claude Code » / « Cursor » ; statuts : « Not detected » (+ lien « How to install ») · « Detected » + bouton `Install hooks` · badge vert « **Ready** » ; erreur : « Couldn't update ~/.claude/settings.json » + `Retry` |
| 3. Notifications | illustration notification permission | « **Stay in the loop** » · « Get notified when an agent needs your approval, hits a usage threshold, or finishes a task. » (texte canonique — `12-notifications.md` §4.3) · `Enable Notifications` (défaut) · `Skip` |
| 4. Launch at login | toggle unique | « **Start AgentDash automatically?** » · toggle « Launch at login » (off) · `Done` (défaut, Entrée — termine l'onboarding) |

États du bouton `Install hooks` : normal → `Installing…` (spinner) → remplacé par le badge `Ready` (vert, animation de fondu 200 ms). La carte `Not detected` est grisée, sans bouton.

### 4.2 Settings → About — version & mise à jour manuelle

- Ligne de version : « Version 0.1.0 (42) ».
- Texte d'aide (secondaire) : « Updates are manual — download or build a newer version and replace AgentDash.app in /Applications. Your settings and hooks are preserved. »
- Lien discret « Uninstall instructions » ouvrant la section correspondante du `README` (local ou repo GitHub) — aucun site propre.

---

## 5. Cas limites & gestion d'erreurs

| # | Cas | Comportement spécifié |
|---|---|---|
| 1 | Double lancement de l'app pendant l'onboarding | second process quitte immédiatement (singleton par socket déjà lié — mécanisme 01-architecture) ; l'onboarding n'est jamais dupliqué |
| 2 | Onboarding fermé prématurément | équivaut à tout passer : `onboardingCompleted` est posé (REQ-LIC-10), l'onboarding ne se représente pas ; chaque action reste rejouable depuis Settings |
| 3 | `requestAuthorization` sans fenêtre au premier plan (LSUIElement) | l'onboarding active l'app avant l'appel ; à valider sur macOS 26 [HYPOTHÈSE D-L n°9] ; si le prompt n'apparaît pas, bouton Settings → Notifications avec deep-link |
| 4 | Hooks : fichier de config en lecture seule / JSON invalide | erreur inline sur la carte + renvoi Doctor ; jamais d'écrasement destructif (fusion + `.bak`, 01-architecture §8.5) |
| 5 | Remplacement de l'app pendant qu'une session est active | hooks fail-open (`exit 0` sans réponse, 03 · REQ-CLA-12) : la session continue avec les dialogues natifs ; au relancement, resynchronisation + re-scan des transcripts (REQ-LIC-55) |
| 6 | Remplacement alors que l'ancienne instance tourne encore | consigne documentée : quitter AgentDash d'abord (le Finder peut refuser un remplacement « in use ») ; si une nouvelle copie est lancée pendant que l'ancienne tourne, le singleton par socket fait quitter la seconde |
| 7 | Downgrade N+1 → N | lecture tolérante des UserDefaults (clés inconnues ignorées, jamais de crash) ; la resynchronisation recopie le binaire hook de la version relancée (comparaison de hash, sans notion d'ordre de version) |
| 8 | `~/.agentdash/bin` supprimé à la main | recréé au prochain lancement (fonction « réparer ») ; entre-temps, hooks fail-open — aucune session bloquée |
| 9 | Build ad hoc bloquée par Gatekeeper | ouverture par clic droit → Open documentée (README) ; `xattr -d com.apple.quarantine` en dernier recours ; App Translocation si l'app est lancée depuis le DMG/Downloads → consigne « copier dans /Applications d'abord » |
| 10 | Compte Apple Developer indisponible | la voie ad hoc (REQ-LIC-39) reste pleinement fonctionnelle — aucune dépendance dure à la signature Developer ID ni à la notarisation |

---

## 6. Critères d'acceptation

1. **Onboarding minimal** — Given un Mac vierge avec Claude Code installé, When l'utilisateur installe l'app (DMG ou copie directe dans `/Applications`), la lance et suit `Continue` → `Install hooks`, Then les hooks Claude affichent `Ready`, une session Claude lancée ensuite apparaît dans le notch, et le tout a nécessité ≤ 3 interactions (REQ-VIS-23).
2. **Ready véridique** — Given l'étape Agents, When l'utilisateur clique `Install hooks` alors que `~/.claude/settings.json` est en lecture seule, Then la carte affiche une erreur avec `Retry` (jamais `Ready`), et le fichier n'a pas été modifié.
3. **Notifications en contexte** — Given l'étape 3, When l'utilisateur clique `Enable Notifications`, Then le prompt système apparaît ; When il choisit « Don't Allow » puis `Continue`, Then l'onboarding se termine normalement et Settings → Notifications propose le deep-link Réglages Système.
4. **Remplacement N → N+1 pendant une session active** — Given la version N installée, ses hooks `Ready` et une session Claude active visible dans le notch, When l'utilisateur quitte AgentDash, remplace `AgentDash.app` dans `/Applications` par la version N+1 puis la lance, Then pendant l'absence de l'app la session a continué sans blocage (prompts rendus aux dialogues natifs de l'agent), au relancement le binaire `~/.agentdash/bin/agentdash-hook` a été resynchronisé (hash égal au binaire embarqué de N+1), la session active réapparaît dans le notch avec son état courant, les réglages UserDefaults et les `.bak` sont intacts, et Settings → About affiche la version N+1.
5. **Désinstallation propre** — Given des hooks installés pour Claude Code et Cursor, When la procédure REQ-LIC-54 est suivie, Then `~/.claude/settings.json` et `~/.cursor/hooks.json` ne contiennent plus aucune entrée AgentDash (les hooks tiers et autres clés sont intacts), `~/.agentdash/` n'existe plus, et une session d'agent lancée ensuite fonctionne normalement (dialogues natifs).
6. **Zéro réseau propre** — Given un proxy d'inspection, When l'app tourne une journée complète (onboarding, sessions, usage), Then les seules destinations contactées sont `api.anthropic.com` et `cursor.com`, et plus aucune si les opt-out d'usage sont activés — aucune requête d'activation, de mise à jour ou de télémétrie.
7. **Gatekeeper (P2, si notarisation activée)** — Given le DMG signé Developer ID, notarié et staplé, When il est ouvert sur un Mac vierge (macOS 14, hors ligne après téléchargement), Then l'app s'ouvre sans avertissement ni clic droit (`spctl --assess` accepté, tickets staplés app + DMG).
8. **Build ad hoc** — Given une build signée ad hoc copiée dans `/Applications`, When l'utilisateur suit la consigne clic droit → Open du README, Then l'app se lance et l'onboarding complet (critère 1) fonctionne à l'identique.

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances amont** : `plan/01-architecture.md` (§4.3 séquence de démarrage, singleton par socket, §8.5 écritures avec `.bak`) ; `plan/00-vision-scope.md` (REQ-VIS-23 ≤ 3 interactions, textes canoniques §4) ; `plan/research/distribution-licensing.md` (**archivée** — restent pertinentes : hypothèse n°9 sur le prompt en LSUIElement, §2.1 signature/notarisation).

**Dépendances croisées** : `plan/03-integration-claude-code.md` / `plan/04-integration-cursor.md` (moteur `HooksInstaller`, fonction « réparer » REQ-CLA-01/10, désinstallation REQ-CLA-05, fail-open REQ-CLA-12 — fondations du modèle de mise à jour manuelle) ; `plan/12-notifications.md` (re-demande de permission, texte canonique de l'étape « Stay in the loop ») ; `plan/13-settings.md` (onglet About : ligne de version et texte d'aide ; toggles Agent hooks utilisés par la désinstallation).

| Risque | Prob. | Impact | Mitigation |
|---|---|---|---|
| Prompt notifications absent en LSUIElement sur macOS 26 (D-L n°9) | Faible | Moyen | activation explicite de l'app avant l'appel + fallback deep-link Réglages Système |
| Friction Gatekeeper des builds ad hoc (sans Developer ID) | Moyenne | Moyen | consigne clic droit → Open + copie dans /Applications documentées (REQ-LIC-39) ; notarisation P2 dès qu'un certificat existe |
| Perte du certificat Developer ID | Faible | Faible | sauvegarde froide du p12 (REQ-LIC-44) ; ré-émission possible depuis le compte Apple Developer, les builds distribuées restent valides |
| Utilisateurs restant sur d'anciennes versions (aucun canal d'update) | Élevée | Faible-Moyen | assumé (décision one-shot) ; version visible dans About + `CHANGELOG.md` public sur le repo |
| Remplacement de l'app pendant qu'elle tourne | Faible | Faible | consigne « quitter d'abord » documentée ; singleton par socket + hooks fail-open rendent le pire cas bénin (cas limites 5–6) |

---

## 8. Découpage en tâches

| # | Tâche | Taille | Priorité |
|---|---|---|---|
| T1 | `OnboardingCoordinator` + fenêtre Welcome (étapes 1–4, navigation, détection agents) | **M** | P0 |
| T2 | Branchement `Install hooks` → `HooksInstaller` + vérification `Ready` (3 checks) + états d'erreur | **M** | P0 |
| T3 | Étape Notifications (`requestAuthorization` en contexte) + relais Settings/deep-link | **S** | P0 |
| T4 | — supprimée (flag `LICENSING_ENABLED` ; décision one-shot du 3 juillet 2026) | — | — |
| T5–T10 | — supprimées (trial, `MachineIdentity`, Worker Cloudflare/Lemon Squeezy, activation, UI licence ; décision one-shot du 3 juillet 2026) | — | — |
| T11 | — supprimée (intégration Sparkle ; décision one-shot du 3 juillet 2026) | — | — |
| T12 | — supprimée (fenêtre What's New ; décision one-shot du 3 juillet 2026) | — | — |
| T13 | Scripts de release locaux (`release.sh`, `bump-version.sh` ; `notarize.sh` et `make-dmg.sh` en P2) + consignes ad hoc du README | **M** | P1 |
| T14 | Workflow GitHub Actions optionnel (secrets, keychain temporaire, `gh release create`) | **M** | P2 |
| T15 | — supprimée (test E2E de la chaîne d'update N−1 → N ; décision one-shot du 3 juillet 2026) | — | — |
| T16–T18 | — supprimées (site, page de download, canal bêta/anti-abus, documentation en ligne ; décision one-shot du 3 juillet 2026) | — | — |
| T19 | Mise à jour manuelle : ligne de version + texte d'aide dans About, procédure de désinstallation (README + outillage Settings) | **S** | P1 |
| T20 | Banc de test du remplacement manuel : N → N+1 avec session active, resynchronisation par hash, downgrade N+1 → N | **S** | P1 |

Ordre conseillé : T1–T3 (onboarding fonctionnel) → T13 (première release locale distribuable) → T19–T20 (modèle one-shot complet et testé) → T14 (CI, seulement si souhaitée). Prérequis externe avant la signature Developer ID et la notarisation : compte Apple Developer actif — sinon, la voie ad hoc de REQ-LIC-39 suffit.
