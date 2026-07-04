# 13. Fenêtre Settings (SettingsKit) et onglet Doctor

> Spécification du module **SettingsKit** (package SPM, dépend de `DashCore` et `DoctorKit` — cf. `plan/01-architecture.md` §3.1) et du module **DoctorKit** pour sa partie diagnostic. Rédigée le 3 juillet 2026, conforme à `plan/01-architecture.md` (décisions A2, A4, A5, A9, A10), `plan/02-data-model.md` (§6.1 `AppSettings` — la source de vérité de tous les défauts cités ici) et aux fichiers `03-integration-claude-code.md`, `05-notch-ui.md`, `06-menubar.md`, `09-token-usage.md`, `10-local-servers.md`.
> Convention : **[VÉRIFIÉ]** = adossé à `AGENTPEEK_FEATURES.md`, à la doc officielle Apple ou à une inspection locale ; **[HYPOTHÈSE — à valider]** = déduction (AgentPeek n'est pas installé sur cette machine, son rendu exact n'est pas inspectable) ; **[TRANCHÉ produit]** = valeur choisie par nous quand AgentPeek ne documente pas la sienne.

---

## 1. Objectif & périmètre

Reproduire la fenêtre Settings complète d'AgentPeek : fenêtre **redimensionnable** à **navigation sidebar** (elle-même redimensionnable, v0.2.9), **bouton power Quit rouge en haut à gauche**, et sept onglets — **General, Notifications, Appearance, Usage, Shortcuts, Doctor, About** — où chaque contrôle a une valeur par défaut définie et un **effet immédiat** (aucun bouton « Apply »). L'onglet **Doctor** est le centre névralgique du support : chaque diagnostic est spécifié avec son implémentation et son **remède guidé en un clic**.

Sections d'`AGENTPEEK_FEATURES.md` couvertes :

- **§10 (intégralité)** — structure de la fenêtre, General, Notifications (renvoi §9), Appearance, Usage, Shortcuts, Doctor, About, bouton power Quit.
- **§2.1** — statut des hooks « Ready » par outil, toggle unique qui installe **et** répare (v0.1.1), vérifiable dans Settings → General → Agent hooks.
- **§9** — tous les réglages de notifications (toggle maître, son, permission/budget/stuck/complete, seuils 50–100 %, Test notification).
- **§5** — réglages d'usage consolidés (toggles par agent, sélection de compte, mesure Cursor, barres optionnelles, countdown depuis 100 %) et « usage health notice » pointant vers Doctor.
- **§4.1** — réglage « prompt handling location ».
- **§13** — v0.1.12 (bouton power Quit), v0.2.6–0.2.7 (onglet Doctor), v0.2.9 (sidebar redimensionnable, onglets Usage et Shortcuts).

Hors périmètre de ce fichier : le contenu des surfaces pilotées par ces réglages (notch → `05`, menu bar → `06`, jauges → `09`), l'onboarding (`14-onboarding-distribution.md`), la logique d'installation des hooks elle-même (`03` pour Claude, fichier Cursor pour `~/.cursor/hooks.json`) — Settings ne fait qu'**invoquer** les `HooksInstaller` et **afficher** leurs statuts.

---

## 2. Exigences détaillées

Priorités : **P0** = MVP, **P1** = parité v0.2.11, **P2** = finition.

### 2.1 Structure de la fenêtre

- **REQ-SET-01 (P0)** — La fenêtre Settings est un `NSWindow` unique (singleton), `styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, contenu SwiftUI via `NSHostingView`. Taille par défaut **780 × 560 pt**, minimum **640 × 440 pt**, redimensionnable librement **[VÉRIFIÉ features §10 « fenêtre redimensionnable »]** ; frame persistée (`setFrameAutosaveName("SettingsWindow")`).
- **REQ-SET-02 (P0)** — Navigation par **sidebar** (`NavigationSplitView`) listant, dans l'ordre : General, Notifications, Appearance, Usage, Shortcuts, Doctor, About. La sidebar est **redimensionnable** (min 150 pt, max 240 pt, défaut 185 pt — largeurs **[TRANCHÉ produit]**, la redimensionnabilité est **[VÉRIFIÉ v0.2.9]**). Le dernier onglet sélectionné est persisté et restauré.
- **REQ-SET-03 (P0)** — Un **bouton power rouge** (SF Symbol `power`, teinte `systemRed`, cercle 22 pt) est placé **en haut à gauche** de la fenêtre, dans l'en-tête de la sidebar sous les feux de fenêtre **[VÉRIFIÉ features §10/§13 v0.1.12 pour l'existence et la position « en haut à gauche » ; placement exact sous les feux = HYPOTHÈSE — à valider]**. Clic → `NSApp.terminate(nil)` immédiat, sans confirmation ; tooltip « Quit AgentDash ». Avant de quitter, tous les `PendingPrompt` sont auto-libérés (réponse vide) — fail-open garanti.
- **REQ-SET-04 (P0)** — **Positionnement anti-notch** : à la première ouverture (aucune frame persistée), la fenêtre est centrée horizontalement et son bord supérieur est placé à `min(centre vertical standard, screen.frame.maxY − hauteurMaxPanelNotch − 24 pt)` sur l'écran porteur du notch — la fenêtre ne chevauche jamais la zone d'expansion du panel (qui reste ouvert quand Settings a le focus, REQ-NUI-21). Si la frame restaurée chevauche cette zone, elle est décalée vers le bas au premier affichage. **[HYPOTHÈSE — comportement exact d'AgentPeek non inspectable ; décision produit]**
- **REQ-SET-05 (P0)** — Ouvrir Settings **active l'app** (`NSApp.activate(ignoringOtherApps: true)`) puis `makeKeyAndOrderFront` — c'est la seule fenêtre régulière de cette app `LSUIElement`. Points d'entrée : item « Settings… » du popover menu bar (REQ-MBR), action du panel notch, ⌘, quand une surface AgentDash est key, et réouverture de l'app (`applicationShouldHandleReopen` → Settings) quand aucune surface n'est visible.
- **REQ-SET-06 (P0)** — **Effet immédiat** : chaque contrôle applique sa valeur dès l'interaction (mutation de `SettingsStore` sur MainActor, observée par toutes les surfaces — cf. REQ-NUI-44) ; il n'existe ni bouton « Apply » ni « OK ». La persistance UserDefaults est débouncée à 500 ms (02 §8) — un slider manipulé en continu n'écrit pas 60 fois/s.
- **REQ-SET-07 (P0)** — **États réels relus à l'affichage** : à chaque apparition d'un onglet (et au retour au premier plan de la fenêtre), les états qui dépendent du système sont relus et non présumés : `SMAppService.mainApp.status` (launch at login — commentaire explicite de `AppSettings`), `UNUserNotificationCenter` `authorizationStatus`, `HooksInstaller.status()` par agent. Toute divergence réglage ↔ réalité est affichée (jamais masquée).
- **REQ-SET-08 (P0)** — Si l'utilisateur désactive la **dernière surface visible** (notch et menu bar tous deux off), une alerte modale prévient : « AgentDash will have no visible surface. Reopen it from Finder or Spotlight to show Settings again. » avec [Turn Off Anyway] / [Cancel] **[TRANCHÉ produit — reprend l'avertissement imposé par REQ-MBR-26]**.
- **REQ-SET-09 (P1)** — ⌘W ferme la fenêtre, Échap la ferme si aucun recorder de raccourci n'est actif ; ⌘, la rouvre. Comme l'app est `LSUIElement`, un menu principal minimal invisible porte ces key equivalents (technique standard AppKit) **[HYPOTHÈSE — à valider en implémentation : câblage exact des key equivalents sans barre de menus visible]**.

### 2.2 Onglet General

- **REQ-SET-10 (P0)** — **Launch at login** (toggle, défaut **off**) : on → `SMAppService.mainApp.register()`, off → `unregister()` **[VÉRIFIÉ doc Apple, macOS 13+]**. Statut `.requiresApproval` → sous-texte « Approval required in System Settings › Login Items » + bouton « Open Login Items » (`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`). L'état affiché provient de `status`, jamais du seul UserDefaults (REQ-SET-07).
- **REQ-SET-11 (P0)** — **Show notch** (toggle, défaut **on**, clé `notchEnabled`) : effet immédiat — repli animé puis `orderOut` / recréation par écran (délégué à NotchUI, REQ-NUI-10). **Show menu bar** (toggle, défaut **on**, clé `menuBarEnabled`) : création/destruction immédiate du `NSStatusItem` (REQ-MBR-01). Les deux toggles sont **indépendants** (4 combinaisons valides, garde-fou REQ-SET-08).
- **REQ-SET-12 (P0)** — **Auto-expand on attention** (toggle, défaut **on**, clé `autoExpandOnAttention`) : pilote l'ouverture automatique du panel quand une session passe `waiting(*)` (comportement dans `05`).
- **REQ-SET-13 (P0)** — **Handle prompts in** (picker : `Notch` / `Terminal only` / `Both`, défaut **Notch**, clé `promptHandling`) : `Notch` = prompt actionnable dans le notch jusqu'à auto-libération ; `Terminal only` = réponse vide immédiate à tout hook de décision (le dialogue natif s'affiche, le notch montre l'état `waiting` sans boutons) ; `Both` = actionnable dans le notch **et** relâché à `timeout − 10 s` comme `Notch`, mais la notification système de permission propose aussi Allow/Deny. Changement effectif dès le **prochain** prompt (jamais rétroactif sur un prompt affiché). **[Sémantique exacte des 3 valeurs = HYPOTHÈSE produit — AgentPeek documente seulement l'existence du réglage]**
- **REQ-SET-14 (P0)** — Section **Agent hooks** : une carte par agent (Claude Code, Cursor) affichant : nom + icône, **badge de statut** (`Ready` vert / `Needs repair` jaune / `Off` gris / `Not detected` gris barré), sous-texte contextuel, et le **toggle** (`claudeHooksEnabled` / `cursorHooksEnabled`, défauts **on**). Toggle on → `installOrRepair()` (fusion non destructive + resynchronisation du binaire — le toggle **installe et répare**, v0.1.1) ; toggle off → `uninstall()` (retrait de nos entrées uniquement). Mapping des statuts : `HooksStatus.ready` → « Ready » ; `.damaged(reason)` → « Needs repair » + bouton **Repair** ; `.notInstalled` (toggle off) → « Off » ; `.agentMissing` → « Not detected » + lien d'installation de l'agent, toggle désactivé.
- **REQ-SET-15 (P0)** — Le statut « Ready » de chaque carte est le résultat des checks du `HooksInstaller` de l'agent (pour Claude : les 4 conditions de REQ-CLA-04 — binaire + hash, jeu canonique, socket joignable, `disableAllHooks != true`). Re-check : à chaque apparition de l'onglet, après toute action install/repair/uninstall, et au plus toutes les 60 s tant que l'onglet est visible (re-check périodique, REQ-CLA-06).
- **REQ-SET-16 (P1)** — Pendant `installOrRepair()`/`uninstall()` (opérations asynchrones hors MainActor), la carte affiche un spinner et le toggle est désactivé ; un échec produit un badge « Needs repair » + sous-texte de la raison (`damaged(reason)`) + lien « See Doctor » qui ouvre l'onglet Doctor.

### 2.3 Onglet Notifications

- **REQ-SET-17 (P0)** — **Enable notifications** (toggle maître, défaut **on**, clé `notificationsMasterEnabled`). Première activation (ou activation avec statut `notDetermined`) → `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])` **[VÉRIFIÉ doc Apple]**. Off → plus **aucune** notification émise, quelles que soient les sous-options (assertion testable : compteur d'émissions nul).
- **REQ-SET-18 (P0)** — **Play sound** (toggle, défaut **on**, clé `notificationSoundEnabled`) : ajoute/retire `UNNotificationSound.default` des notifications émises.
- **REQ-SET-19 (P0)** — Section **Notify me about** — quatre toggles : **Permission requests** (défaut on, `notifyPermissionRequests`), **Budget alerts** (défaut on, `notifyBudgetAlerts`), **Stuck sessions** (défaut on, `notifyStuckSessions`), **Task complete** (défaut on, `notifyTaskComplete`). Chacun masque/démasque ses réglages enfants et prend effet au prochain événement.
- **REQ-SET-20 (P0)** — Sous **Budget alerts**, deux curseurs de seuil : « 5-hour window — Notify at **80 %** » et « 7-day window — Notify at **80 %** », plage **50–100 %** par pas de 5 (clés `budgetThreshold5h`/`budgetThreshold7d`, défauts 80) **[VÉRIFIÉ features §9 pour la plage 50–100 ; défaut 80 et pas de 5 = TRANCHÉ produit]**. Un changement de seuil réévalue immédiatement les jauges courantes (peut déclencher une alerte dans la seconde).
- **REQ-SET-21 (P0)** — Bouton **Send Test Notification** : poste immédiatement une notification `NotificationKind.test` (titre, sous-titre et corps canoniques définis par la table `12` §4.2 — source unique des contenus de notifications) en respectant le réglage de son ; si la permission système est refusée, le clic affiche à la place la bannière REQ-SET-22. **[VÉRIFIÉ features §9 « Test notification »]**
- **REQ-SET-22 (P0)** — Si `authorizationStatus == .denied` alors que le toggle maître est on : bannière jaune persistante en tête d'onglet — « Notifications are disabled in System Settings. » + bouton « Open System Settings » (`x-apple.systempreferences:com.apple.preference.notifications`). Si `.notDetermined` : bouton « Request Permission ».
- **REQ-SET-23 (P2)** — Le seuil `stuckThresholdSeconds` (défaut 120) n'est **pas** exposé dans cet onglet (fidélité AgentPeek) ; il est visible/modifiable dans la zone avancée de Doctor (REQ-SET-60).

### 2.4 Onglet Appearance

Tous les contrôles de cet onglet mutent `AppSettings` et sont reflétés par le notch/la menu bar en < 1 frame (REQ-NUI-44).

- **REQ-SET-24 (P0)** — **Panel width** : picker segmenté compact `Normal / Wide / Ultra-wide` (défaut **Normal**, clé `panelWidth`) **[VÉRIFIÉ features §10 « picker de largeur compact », « Ultra-wide »]**.
- **REQ-SET-25 (P1)** — **Pill width** : picker `Auto / Wide / Ultra-wide` (défaut **Auto**, clé `pillWidthMode`). Quand `pillUsageMode == true`, `Auto` est indisponible (grisé) et la valeur est forcée à `Wide` (REQ-NUI-26) ; sous-texte : « Locked while usage mode is on ».
- **REQ-SET-26 (P1)** — **Density** : picker `Compact / Regular / Colossal` (défaut **Regular**, clé `density`) **[VÉRIFIÉ « Colossal » v0.2.5]**.
- **REQ-SET-27 (P1)** — **Session list** : picker `Fixed / Growable` (défaut **Fixed**, clé `sessionListSizing`) ; sous-texte : « Growable expands to screen height before scrolling » **[VÉRIFIÉ features §10]**.
- **REQ-SET-28 (P2)** — **Title weight** : picker `Regular / Medium / Semibold / Bold` (défaut **Semibold**, clé `titleWeight`).
- **REQ-SET-29 (P1)** — **Clock** : picker `12-hour / 24-hour` (défaut **24-hour**, clé `clock24h`) ; s'applique à tous les horodatages affichés (heures de refill, timeline, uptime).
- **REQ-SET-30 (P1)** — Section **Pill** — quatre toggles : **Show session count** (défaut on, `pillShowsSessionCount`), **Usage mode** (défaut off, `pillUsageMode` ; sous-texte « Show live usage gauges in the collapsed pill »), **Hide when idle** (défaut off, `pillHideWhenIdle`), **Expanded only** (défaut off, `pillExpandedOnly`) **[VÉRIFIÉ features §10 « count / usage / hide when idle / expanded only »]**.
- **REQ-SET-31 (P1)** — **Glass opacity** : slider continu 0…1 (défaut **1,0** — noir profond opaque, calibrage utilisateur du 3 juillet 2026 : le panel doit se fondre dans la découpe ; clé `glassOpacity`), extrémité droite étiquetée **Opaque** ; à 1,0 le blur est réellement désactivé (`NSVisualEffectView` retirée — pas seulement recouverte) **[VÉRIFIÉ v0.2.8 « slider d'opacité + Opaque »]**.
- **REQ-SET-32 (P1)** — **Frosted rim** (toggle, défaut **off** — calibrage utilisateur du 3 juillet 2026 : pas de liseré dégradé sur la surface notch par défaut, `frostedRim`) et **Depth-lit interface** (toggle, défaut on, `depthLitEnabled` ; sous-texte « Raised cards, recessed wells ») **[VÉRIFIÉ features §10]**.
- **REQ-SET-33 (P1)** — **Metrics opacity** : slider 0,3…1 (défaut **0,85**, clé `metricsOpacity`) ; sous-texte « Legibility of numbers in the notch » **[VÉRIFIÉ v0.2.11 ; borne basse 0,3 = TRANCHÉ produit pour éviter du texte invisible]**.
- **REQ-SET-34 (P2)** — **Hide from screen recordings** (toggle, défaut off, `hideFromScreenRecording`) : applique `sharingType = .none` aux fenêtres notch (REQ-NUI-09).
- **REQ-SET-35 (P1)** — **Display** : picker `Built-in first / Active screen / <liste des écrans par nom>` (défaut **Built-in first**, clé `preferredScreen`) ; la liste est rafraîchie sur `didChangeScreenParametersNotification`. Un écran choisi puis débranché → retour automatique à `Built-in first` avec sous-texte informatif. **[TRANCHÉ produit — AgentPeek ne documente pas ce réglage ; requis par REQ-NUI-14]**

### 2.5 Onglet Usage

- **REQ-SET-36 (P0)** — **Track Claude Code usage** (toggle, défaut on, `claudeUsageEnabled`) et **Track Cursor usage** (toggle, défaut on, `cursorUsageEnabled`) : off → arrêt **complet** du poller concerné (zéro requête réseau, REQ-USG-06) et retrait des jauges de toutes les surfaces ; on → poll immédiat.
- **REQ-SET-37 (P0)** — Ligne d'état de connexion sous chaque toggle : Claude — « Connected via Claude Code sign-in » / « Keychain access needed » + bouton **Retry** (relecture Keychain + poll, REQ-CLA-66) ; Cursor — « Connected via Cursor sign-in » / « Sign in to Cursor to enable » (lecture du token dans `state.vscdb`, REQ-USG-04). Jamais de saisie de credentials dans AgentDash.
- **REQ-SET-38 (P1)** — **Account** : picker des comptes détectés (`UsageAccount` : label + plan), première entrée **Automatic** (défaut, `selectedUsageAccountID = nil`). Sélection → refresh immédiat des jauges + mise à jour du label de compte des cartes de session **[VÉRIFIÉ v0.2.11 « sélection de compte d'usage »]**.
- **REQ-SET-39 (P0)** — **Cursor measure** : picker `Spend / Weighted / Auto / API` (défaut **Weighted**, clé `cursorMeasure`) ; changement → recalcul et ré-affichage **immédiat** des jauges (« Mises à jour de jauge immédiates au changement de réglage » **[VÉRIFIÉ]**). Mapping des mesures vers `usage-summary` : [HYPOTHÈSE cursor n°8 — bancs `09`].
- **REQ-SET-40 (P1)** — **Show Auto/Composer bar** (défaut off, `cursorShowAutoBar`) et **Show API bar** (défaut off, `cursorShowAPIBar`) : ajoutent les sous-barres correspondantes dans la vue détail d'usage du notch **[VÉRIFIÉ features §5.2]**.
- **REQ-SET-41 (P1)** — **Count down from 100 %** (toggle, défaut off, `countdownFrom100`) : inverse l'affichage de toutes les jauges (restant au lieu de consommé) sans changer les couleurs de seuil ; effet immédiat sur notch, menu bar et pill.
- **REQ-SET-42 (P1)** — **Daily usage stats** (toggle, défaut on, `dailyStatsEnabled`) : active la collecte/l'affichage des statistiques jour par jour (REQ-USG-27) ; off → la section disparaît des surfaces, le cache `daily-usage.json` est conservé.

### 2.6 Onglet Shortcuts

- **REQ-SET-43 (P0)** — L'onglet liste **tous** les raccourcis dans un tableau à trois colonnes (action, description, recorder) : **Allow** ⌘A, **Deny** ⌘N, **Always Allow** ⌥A (« Claude Code only »), **Open Terminal** ⌥T, **Toggle notch** (défaut : none, global). Chaque ligne utilise un recorder de la bibliothèque **KeyboardShortcuts** (architecture §2) permettant réassignation et effacement.
- **REQ-SET-44 (P0)** — **Détection de conflits internes** : deux actions AgentDash assignées à la même combinaison → les deux lignes affichent un badge rouge « Conflict » et la dernière assignation est refusée (revert visuel + `NSSound.beep()`).
- **REQ-SET-45 (P0)** — **Avertissement d'échec d'enregistrement** : si `RegisterEventHotKey` échoue à l'armement (combinaison réservée par macOS ou prise par une autre app), une bannière jaune apparaît en tête d'onglet — « “⌥A” could not be registered. It may be reserved by macOS or another app. » — et la ligne concernée porte un badge ⚠ **[VÉRIFIÉ features §10 « avertissement en cas d'échec d'enregistrement »]**. L'échec étant possible seulement à l'armement (enregistrement éphémère), la bannière est aussi déclenchée depuis le flux prompt et persiste jusqu'à réassignation.
- **REQ-SET-46 (P0)** — Note de portée affichée sous le tableau : « Prompt shortcuts are only active while a prompt is visible. » — les hotkeys ⌘A/⌘N/⌥A/⌥T sont **éphémères** (architecture §8.7) ; `Toggle notch` est le seul raccourci global permanent (optionnel).
- **REQ-SET-47 (P1)** — Bouton **Restore Defaults** : réassigne les cinq raccourcis à leurs valeurs par défaut (⌘A/⌘N/⌥A/⌥T/none) après confirmation inline.
- **REQ-SET-48 (P1)** — **⌘,** ouvre Settings uniquement quand une surface AgentDash est key (panel notch key, popover menu bar, fenêtre Settings) ; il n'est **jamais** enregistré comme hotkey global — dans les autres apps, ⌘, garde son sens natif (« ⌘, ne rentre pas en conflit avec la fenêtre Settings système » **[VÉRIFIÉ features §10]**).

### 2.7 Onglet Doctor

- **REQ-SET-49 (P0)** — L'onglet Doctor exécute la **suite complète de checks** à chaque ouverture, affiche un en-tête de synthèse (« All checks passed » vert / « N issues found » rouge, spinner pendant l'exécution) et un bouton **Run Checks** pour relancer. Les checks tournent hors MainActor (chaque check est `async`, I/O dans les actors concernés) ; la suite complète s'exécute en < 2 s **[TRANCHÉ produit]**.
- **REQ-SET-50 (P0)** — Chaque check produit un `DoctorFinding` : statut (`passed` ✓ vert / `warning` ⚠ jaune / `failed` ✕ rouge / `info` ○ gris), titre, détail en langage clair (une phrase, avec valeurs mesurées), et **remède en un clic** quand il existe (bouton à droite de la ligne). Après tout remède, le check concerné est ré-exécuté automatiquement et la ligne se met à jour.
- **REQ-SET-51 (P0)** — L'item « Doctor » de la sidebar porte un **badge numérique rouge** = nombre de checks `failed` (les `warning` ne comptent pas) ; le badge est mis à jour par les re-checks périodiques en arrière-plan (60 s, alignés sur le re-check REQ-CLA-06) même quand Settings est fermée — c'est ce badge qu'alimentent le « usage health notice » (REQ-USG-33) et les statuts de flux (`DoctorStore.health`).
- **REQ-SET-52 (P0)** — **Check « Claude Code hooks »** : ré-exécute `HooksInstaller.status()` d'AgentClaude — settings.json parseable, jeu canonique complet (§4.2 architecture), entrées marquées par le chemin du binaire, `disableAllHooks != true`. Échec → `failed`, détail (ex. « 3 of 12 hook entries are missing »), remède **Repair** (= `installOrRepair()`). Agent absent → `info` « Claude Code not detected » + lien d'installation.
- **REQ-SET-53 (P0)** — **Check « Cursor hooks »** : idem sur `~/.cursor/hooks.json` (fichier présent, `"version": 1`, nos entrées complètes, JSON valide). Remède **Repair**. Cursor absent → `info`.
- **REQ-SET-54 (P0)** — **Check « Helper binary »** : `~/.agentdash/bin/agentdash-hook` existe, bit exécutable, **SHA-256 identique** au binaire embarqué (`Contents/Helpers/agentdash-hook`), et absence d'attribut `com.apple.quarantine` (`getxattr`) **[HYPOTHÈSE system-integration n°4 — l'effet réel de la quarantaine sur un binaire copié est au banc d'essai]**. Échec → remède **Reinstall Helper** (recopie + `chmod 755`, REQ-CLA-10).
- **REQ-SET-55 (P0)** — **Check « Hook relay round-trip »** (le plus important) : l'app **spawne réellement** `agentdash-hook` avec un événement synthétique `{"hook_event_name":"__agentdash_selftest"}` sur stdin ; `HookServer` le reconnaît, répond une ligne vide ; succès = exit 0 + réponse reçue en **< 500 ms**. Le détail affiche la latence mesurée (« Round-trip OK — 4 ms »). Ce test prouve d'un coup : binaire exécutable, socket présent et joignable, serveur vivant, protocole compatible. Échec → remède **Restart IPC Server** (suppression du socket périmé + relance `NWListener` + recopie du binaire), puis re-test automatique.
- **REQ-SET-56 (P0)** — **Check « IPC socket »** : socket présent à `~/Library/Application Support/AgentDash/agentdash.sock`, permissions **0600**, dossier **0700**, `connect()` in-process réussi. Remède **Recreate Socket**.
- **REQ-SET-57 (P0)** — **Check « Claude transcripts »** : `~/.claude/projects` existe et est lisible (`access(R_OK)`), le stream FSEvents est actif (dernier callback ou création < session courante), et le compteur de lignes illisibles (REQ-CLA-21) est < 1 % des lignes ingérées. Dégradé → `warning` avec détail (« 3 unreadable lines in 2 files ») ; dossier illisible → `failed`, remède **Reveal in Finder** + **Restart Ingestion**.
- **REQ-SET-58 (P0)** — **Check « Cursor database »** : ouverture lecture seule de `state.vscdb`, requête sentinelle sur `ItemTable`, tolérance `SQLITE_BUSY` (3 tentatives espacées de 100 ms). Échec → `warning` (« Cursor database is locked or unreadable — sessions fall back to hooks only »), remède **Retry** ; schéma inconnu (`_v` inattendu) → `warning` versionnée.
- **REQ-SET-59 (P0)** — **Checks « Claude usage » / « Cursor usage »** : reflètent `UsageStore.health` (REQ-USG-34) — credentials lisibles + dernier poll réussi (< 15 min). Détails typés : refus Keychain (« Keychain access was denied » → remède **Retry Keychain**), 401 persistant (« Sign in to Claude Code again » → lien doc), 429 (« Rate limited — retrying automatically »), réseau (« Offline — last success at 14:02 »), toggle off → `info` « Disabled in Usage settings » + remède **Open Usage Settings** (bascule d'onglet).
- **REQ-SET-60 (P0)** — **Check « Notification permission »** : si `notificationsMasterEnabled`, exige `authorizationStatus == .authorized` (`.provisional` accepté avec `warning`). `.denied` → `failed`, remède **Open System Settings** ; `.notDetermined` → `warning`, remède **Request Permission**. Master off → `info` « Notifications disabled in settings ».
- **REQ-SET-61** — supprimé (décision one-shot du 3 juillet 2026 : l'app ne vérifie jamais si une version plus récente existe — aucun check « version à jour », aucun check licence ; le Doctor conserve hooks/IPC/transcripts/usage/notifications).
- **REQ-SET-62 (P1)** — **Check « Performance »** : consomme l'auto-mesure `task_info` (30 s, architecture §6) — `warning` si 3 échantillons consécutifs dépassent un budget (RAM ≥ 150 Mo ou CPU idle ≥ 0,5 %), avec valeurs affichées (« Memory 182 MB — budget 150 MB »). Remède : **Restart AgentDash** (relance propre). C'est le pendant produit des « réductions RAM/CPU » v0.2.6–0.2.7.
- **REQ-SET-63 (P1)** — **Check « Hook coexistence »** : détecte des entrées de hooks **tierces** sur les mêmes événements de décision (ex. AgentPeek) → `info` « Another tool also handles permission prompts (…) — both will receive events » ; **aucun remède automatique** (interdiction de toucher aux entrées tierces, REQ-VIS-17), lien documentation. Couvre le risque R5.
- **REQ-SET-64 (P1)** — **Checks annexes** : « Login item » (cohérence `SMAppService.status` ↔ réglage, remède **Open Login Items**) ; « Config backups » (`info`, liste des `.bak` de `~/.agentdash/backups`, remède **Reveal in Finder**) ; « Agent versions » (P2, plancher de version Claude — `03` §5 cas 5, hypothèse claude-code n°8).
- **REQ-SET-65 (P0)** — Pied d'onglet **Tools** : boutons **Rebuild Daily Stats** (recalcul complet du cache `daily-usage.json`, REQ-USG-27), **Export Logs…** (zip : logs tournants + `OSLogStore` 24 h + rapport Doctor JSON — architecture §7.3, via `NSSavePanel`), **Open Logs Folder**. Zone avancée repliée « Advanced » : `stuckThresholdSeconds` (120), `sessionRetentionHours` (24), `serverScanEnabled` (on) + éditeur d'exclusions de scan (REQ-SRV-08).

### 2.8 Onglet About

- **REQ-SET-66 (P0)** — En-tête : icône de l'app (64 pt), nom « AgentDash » (via `ProductIdentity` — nom provisoire), « Version {CFBundleShortVersionString} ({CFBundleVersion}) », copyright. Un clic sur la version la copie dans le presse-papiers (P2).
- **REQ-SET-67** — supprimé (décision one-shot du 3 juillet 2026 : ni bouton « Check for Updates… », ni toggle d'auto-update, ni canal bêta — aucun mécanisme de mise à jour automatique ; remplacé par REQ-SET-72).
- **REQ-SET-68 (P1)** — Section **Resources** : lien **Documentation** ouvrant la documentation locale (le dossier `plan/` livré avec le produit) via `NSWorkspace.shared.open` ; aucun lien web, aucune fenêtre What's New.
- **REQ-SET-69 (P0)** — Section **Logs** : **Open Logs Folder** (révèle `~/Library/Logs/AgentDash/`) et **Export Logs…** (même action que Doctor, REQ-SET-65) **[VÉRIFIÉ features §10 « accès aux fichiers de log »]**.
- **REQ-SET-70 (P1)** — Section **Acknowledgements** : liste déroulante des dépendances OSS avec licences (KeyboardShortcuts) — contenu généré au build depuis les packages **[VÉRIFIÉ features §10 « remerciements »]**.
- **REQ-SET-71** — supprimé (décision one-shot du 3 juillet 2026 : ni licence, ni trial, ni fenêtre d'activation).
- **REQ-SET-72 (P0)** — Section **Update** : ligne statique — texte principal `To update: replace AgentDash.app with a newer build.`, sous-texte `Settings, hooks and backups are preserved.` — sans aucun bouton ni requête réseau. L'onglet About se compose ainsi exclusivement de : en-tête version + build (REQ-SET-66), section Update (cette REQ), Resources (REQ-SET-68), Logs — Open Logs Folder / Export Logs… (REQ-SET-69), Acknowledgements (REQ-SET-70).

---

## 3. Conception technique

### 3.1 Types et stores (SettingsKit / DashCore)

```swift
// DashCore — déjà acté (02 §6.1) : struct AppSettings + SettingsStore.
@MainActor @Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings
    private let defaults: UserDefaults
    private var persistTask: Task<Void, Never>?          // debounce 500 ms

    public func update<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>, to value: T) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value               // effet immédiat (observation SwiftUI)
        schedulePersist()                                 // écriture UserDefaults débouncée
        sideEffects(for: keyPath)                         // ex. start/stop poller, register SMAppService
    }
}

// SettingsKit — navigation
enum SettingsTab: String, CaseIterable, Identifiable, Codable {
    case general, notifications, appearance, usage, shortcuts, doctor, about
    var title: String { /* "General", "Notifications", "Appearance", "Usage",
                           "Shortcuts", "Doctor", "About" */ }
    var symbol: String { /* gearshape, bell.badge, paintbrush, gauge.with.needle,
                            keyboard, stethoscope, info.circle */ }
}

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()
    public func show(tab: SettingsTab? = nil)             // activation + sélection d'onglet
    public func showDoctor()                              // deep-link (usage health notice, bannières)
}
```

Effets de bord centralisés dans `sideEffects(for:)` (table keyPath → action) : `notchEnabled` → NotchUI show/hide ; `menuBarEnabled` → status item ; `launchAtLogin` → `SMAppService` ; `claudeUsageEnabled`/`cursorUsageEnabled` → start/stop poller ; `claudeHooksEnabled`/`cursorHooksEnabled` → install/uninstall (asynchrones, avec état `busy` par agent) ; `preferredScreen` → repositionnement des panels. Aucune surface ne lit UserDefaults directement : **une seule source de vérité**, `SettingsStore`.

### 3.2 DoctorKit — modèle et exécution

```swift
public enum DoctorStatus: Sendable { case passed, info, warning, failed }

public enum DoctorCheckID: String, CaseIterable, Sendable {
    case claudeHooks, cursorHooks, relayBinary, relayRoundTrip, ipcSocket, hookCoexistence
    case claudeTranscripts, cursorDatabase
    case claudeUsage, cursorUsage
    case notificationPermission, loginItem, performance
    case configBackups, agentVersions
}

public struct DoctorFinding: Identifiable, Sendable {
    public var id: DoctorCheckID
    public var status: DoctorStatus
    public var title: String            // ex. "Hook relay round-trip"
    public var detail: String           // ex. "Round-trip OK — 4 ms"
    public var remedy: DoctorRemedy?    // nil si rien à réparer
    public var ranAt: Date
}
public struct DoctorRemedy: Sendable {
    public var label: String            // "Repair", "Reinstall Helper", "Open System Settings"…
    public var action: DoctorAction
}
public enum DoctorAction: Sendable {
    case repairHooks(AgentKind), reinstallRelayBinary, restartIPCServer, recreateSocket
    case restartIngestion(AgentKind), retryKeychain, requestNotificationPermission
    case openSystemSettings(pane: String), openLoginItems
    case rebuildDailyStats, revealPath(String), openURL(URL), openTab(SettingsTab), restartApp
}

public protocol DoctorCheck: Sendable {
    var id: DoctorCheckID { get }
    func run(_ ctx: DoctorContext) async -> DoctorFinding   // I/O hors MainActor
}

@MainActor @Observable
public final class DoctorStore {
    public private(set) var findings: [DoctorFinding] = []
    public private(set) var isRunning = false
    public var failedCount: Int { findings.count { $0.status == .failed } }   // badge sidebar
    public func runAll() async            // TaskGroup, ordre d'affichage stable, timeout 5 s/check
    public func run(_ id: DoctorCheckID) async
    public func perform(_ remedy: DoctorRemedy) async   // exécute puis re-run le check concerné
    public func ingest(health: [FlowHealthUpdate])       // poussé par UsageStore/ingestion (REQ-USG-34)
}
```

`DoctorContext` injecte les dépendances (les deux `HooksInstaller`, `HookServer`, `UsageStore.health`, `TranscriptIngestor.stats`, `CursorStateReader`, `UNUserNotificationCenter`). Chaque check individuel est plafonné à **5 s** (au-delà : `warning` « Check timed out ») pour que `runAll()` ne gèle jamais l'onglet.

### 3.3 Self-test round-trip (REQ-SET-55) — séquence

```
DoctorStore.run(.relayRoundTrip)                    (MainActor → Task détachée)
   │
   ├─ 1. Process(~/.agentdash/bin/agentdash-hook, args: ["--source","claude","--role","telemetry"])
   │      stdin ← {"hook_event_name":"__agentdash_selftest","ts":<now>}\n  ; t0 = now
   │
   ├─ 2. agentdash-hook → connect(agentdash.sock) → envoie l'enveloppe NDJSON
   │
   ├─ 3. HookServer reçoit, EventRouter reconnaît "__agentdash_selftest"
   │      → NE crée AUCUNE session, répond immédiatement une ligne vide
   │
   ├─ 4. agentdash-hook écrit la réponse sur stdout, exit 0 ; t1 = now
   │
   └─ 5. Verdict : exit == 0 && (t1 − t0) < 500 ms
          ✓ → passed  "Round-trip OK — {ms} ms"
          ✕ → failed  "Helper could not reach AgentDash ({raison})"
              remedy = .restartIPCServer   (rm socket périmé → relance NWListener
                                            → resync binaire → re-run automatique)
```

L'événement `__agentdash_selftest` est filtré par `EventRouter` **avant** toute normalisation (préfixe réservé `__agentdash_`) : il ne peut jamais polluer `SessionStore` ni la timeline.

### 3.4 Algorithmes notables

**Positionnement anti-notch (REQ-SET-04)** :

```
placeOnFirstOpen(window):
  screen = écran porteur du notch (preferredScreen) ?? NSScreen.main
  frame.origin.x = screen.visibleFrame.midX − frame.width / 2
  topLimit = screen.frame.maxY − maxPanelHeight(settings) − 24   // zone réservée au panel
  frame.origin.y = min(centreVerticalStandard, topLimit − frame.height)
  // frame restaurée : si frame.maxY > topLimit → décaler vers le bas de (frame.maxY − topLimit)
```

**Launch at login (REQ-SET-10)** — l'état UI est dérivé, jamais stocké seul :

```swift
func refreshLoginItemState() {
    switch SMAppService.mainApp.status {                 // [VÉRIFIÉ doc Apple]
    case .enabled:          view = .on
    case .requiresApproval: view = .onPendingApproval    // sous-texte + bouton Login Items
    case .notRegistered, .notFound: view = .off
    @unknown default:       view = .off
    }
}
```

**Conflits de raccourcis (REQ-SET-44/45)** : à chaque fin d'enregistrement d'un recorder, (1) comparaison de la combinaison aux quatre autres → conflit interne = revert + badge ; (2) armement d'essai immédiat (`RegisterEventHotKey` puis `UnregisterEventHotKey`) → échec = bannière d'avertissement. Le résultat d'armement pendant un prompt réel alimente la même bannière (l'échec y est aussi journalisé `.notice`).

### 3.5 Cadences et threading

| Travail | Contexte | Cadence |
|---|---|---|
| Mutations `AppSettings` + effets de bord | MainActor | immédiat ; persistance débouncée 500 ms |
| `HooksInstaller.status()` (les 2 agents) | Task détachée | ouverture d'onglet General/Doctor, post-action, 60 s si visible |
| Suite Doctor complète | TaskGroup hors MainActor | ouverture de l'onglet, bouton Run Checks |
| Re-checks de fond (badge) | Task de fond | 60 s (mutualisé avec le re-check REQ-CLA-06), résultats → `DoctorStore` |
| Relecture `SMAppService`/`UNNotificationSettings` | Task courte | apparition d'onglet + `didBecomeKey` |

---

## 4. Spécification UX/UI

### 4.1 Structure générale

```
┌──────────────────────────────────────────────────────────────────┐
│ ●●●                                                              │  ← feux standard
│ ┌─────────────┬──────────────────────────────────────────────┐   │
│ │ (⏻)         │  General                                     │   │  ← (⏻) power rouge, tooltip
│ │             │  ────────────────────────────────────────    │   │     "Quit AgentDash"
│ │ ⚙ General   │  Launch at login                    [  off]  │   │
│ │ 🔔 Notifi…  │                                              │   │
│ │ 🖌 Appear…  │  SURFACES                                    │   │
│ │ ◔ Usage     │  Show notch                         [on  ]   │   │
│ │ ⌨ Shortcuts │  Show menu bar                      [on  ]   │   │
│ │ ⚕ Doctor ❸  │  Auto-expand on attention           [on  ]   │   │  ← badge rouge = checks failed
│ │ ⓘ About     │  Handle prompts in      [ Notch ▾ ]          │   │
│ │             │                                              │   │
│ │◄─ 150–240 ─►│  AGENT HOOKS                                 │   │
│ └─────────────┴──────────────────────────────────────────────┘   │
│        780 × 560 pt par défaut, min 640 × 440, redimensionnable  │
└──────────────────────────────────────────────────────────────────┘
```

- Sidebar : matériau `.sidebar`, sélection standard ; libellés exactement `General`, `Notifications`, `Appearance`, `Usage`, `Shortcuts`, `Doctor`, `About`.
- Contenu : `Form` style `.grouped`, titres de section en petites capitales (`SURFACES`, `AGENT HOOKS`, `NOTIFY ME ABOUT`, `PILL`, `LIQUID GLASS`, `TOOLS`…), sous-textes `secondary` 11 pt.
- Fenêtre en apparence système (clair/sombre) — seule la surface notch force `darkAqua`.

### 4.2 Carte Agent hooks (General) — états visuels

```
┌────────────────────────────────────────────────────────────┐
│ ✳ Claude Code                        ● Ready        [on ]  │   ● vert 8 pt
│   Hooks installed — new sessions pick them up automatically│
├────────────────────────────────────────────────────────────┤
│ ▢ Cursor                             ● Needs repair [on ]  │   ● jaune + bouton
│   2 hook entries are missing                    (Repair)   │
└────────────────────────────────────────────────────────────┘
```

États : `Ready` (vert) / `Needs repair` (jaune, bouton **Repair**) / `Off` (gris, toggle off) / `Not detected` (gris, toggle désactivé, lien « Get Claude Code » / « Get Cursor »). Pendant une action : spinner 14 pt à la place du badge, toggle désactivé. Transition de badge animée (fade 150 ms).

### 4.3 Onglet Doctor — layout

```
Doctor
──────────────────────────────────────────────────────────────
● 2 issues found                              (Run Checks ⟳)
   Last run: just now

HOOKS & IPC
 ✓ Claude Code hooks      All 12 entries installed
 ✕ Cursor hooks           hooks.json is missing        (Repair)
 ✓ Helper binary          Hash matches — v0.1.0
 ✓ Hook relay round-trip  Round-trip OK — 4 ms
 ✓ IPC socket             Permissions 0600
 ○ Hook coexistence       No other tools detected

DATA SOURCES
 ✓ Claude transcripts     Watching 14 projects
 ⚠ Cursor database        Locked — retrying             (Retry)

USAGE
 ✓ Claude usage           Last refresh 38 s ago
 ✕ Cursor usage           Sign in to Cursor to enable   (Open Usage Settings)

SYSTEM
 ✓ Notification permission  Authorized
 ✓ Login item               Not enabled (matches setting)
 ✓ Performance              Memory 96 MB · CPU 0.2 %

APP
 ○ Config backups         3 backups                     (Reveal in Finder)
──────────────────────────────────────────────────────────────
TOOLS   (Rebuild Daily Stats) (Export Logs…) (Open Logs Folder)
▸ Advanced
```

Icônes : ✓ `checkmark.circle.fill` vert, ⚠ `exclamationmark.triangle.fill` jaune, ✕ `xmark.circle.fill` rouge, ○ `circle` gris. Pendant `runAll()`, chaque ligne non encore résolue affiche un point pulsant ; les résultats apparaissent dans l'ordre stable de la liste (pas de réordonnancement).

### 4.4 Textes exacts notables (anglais, canoniques)

| Contexte | Texte |
|---|---|
| Power button tooltip | `Quit AgentDash` |
| Hooks prêt | `Ready` |
| Hooks à réparer | `Needs repair` |
| Agent absent | `Not detected` |
| Bouton réparation | `Repair` |
| Prompt handling | `Handle prompts in` — options `Notch` / `Terminal only` / `Both` |
| Test notification | `Send Test Notification` |
| Bannière notifications | `Notifications are disabled in System Settings.` |
| Échec de raccourci | `“⌥A” could not be registered. It may be reserved by macOS or another app.` |
| Note raccourcis | `Prompt shortcuts are only active while a prompt is visible.` |
| Synthèse Doctor OK | `All checks passed` |
| Synthèse Doctor KO | `N issues found` |
| Mise à jour manuelle (About) | `To update: replace AgentDash.app with a newer build.` |
| Health notice (cf. 09) | `Usage may be inaccurate — check Doctor` |
| Dernière surface off | `AgentDash will have no visible surface. Reopen it from Finder or Spotlight to show Settings again.` |

### 4.5 Animations

- Changement d'onglet : cross-fade 150 ms, sans slide (sobriété §4 de `00`).
- Badge Doctor sidebar : apparition `.scale + .opacity` (ressort léger), identique au point orange menu bar (REQ-MBR-04).
- Sliders (glass/metrics opacity) : aperçu **temps réel** sur le notch pendant le drag (mutation continue, persistance débouncée).
- Bouton Run Checks : icône ⟳ en rotation pendant l'exécution ; lignes résolues avec fondu 120 ms.

---

## 5. Cas limites & gestion d'erreurs

1. **UserDefaults corrompus / valeur d'enum inconnue** (downgrade d'app) : décodage clé par clé, toute clé illisible retombe sur son défaut `AppSettings` — jamais de crash ni de reset global des autres clés.
2. **`SMAppService` en `.requiresApproval`** : toggle affiché « on » avec sous-texte et bouton Login Items ; l'app ne boucle jamais sur `register()`.
3. **Permission notifications refusée après coup** (retrait dans System Settings) : détecté à la prochaine apparition d'onglet/re-check Doctor → bannière + check `failed` ; aucune tentative d'émission silencieusement perdue sans trace Doctor.
4. **Les deux surfaces désactivées** : alerte REQ-SET-08 ; si l'utilisateur confirme, la réouverture de l'app (Finder/Spotlight) ouvre Settings (`applicationShouldHandleReopen`).
5. **`settings.json` invalide (JSON cassé par un tiers)** : `installOrRepair()` refuse d'écrire (`03` §5 cas limite 1) → carte « Needs repair », Doctor `failed` avec détail « settings.json could not be parsed » et remède **Reveal in Finder** (jamais d'écrasement automatique d'un fichier utilisateur illisible).
6. **Répertoire `~/.claude` ou `~/.cursor` supprimé pendant que Settings est ouverte** : le re-check 60 s fait passer la carte à « Not detected » ; aucune écriture n'est tentée.
7. **Deux instances d'AgentDash** (rare : copie dans deux emplacements) : le second `HookServer` échoue à binder le socket → Doctor `failed` « Another AgentDash instance owns the IPC socket » ; remède : quitter l'autre instance (pas de vol de socket automatique).
8. **Raccourci enregistré = combinaison système réservée** (ex. ⌘Espace) : l'armement d'essai échoue → bannière REQ-SET-45, l'ancienne combinaison reste active.
9. **Slider manipulé pendant 10 s en continu** : une seule écriture UserDefaults (debounce), rendu temps réel sans à-coup ; CPU de la fenêtre < 5 % pendant le drag.
10. **Frame restaurée hors écran** (écran débranché) : re-centrage automatique sur l'écran principal au premier affichage (`constrainFrameRect`).
11. **Écran sélectionné dans Display débranché** : retour à `Built-in first` + sous-texte « Previous display is disconnected » ; re-sélection possible quand il revient.
12. **Doctor pendant une réparation de hooks en cours** : les actions install/repair/uninstall sont sérialisées par agent (un seul `installOrRepair()` en vol) ; le check attend la fin (dans son plafond de 5 s) ou affiche « Repair in progress ».
13. **Check Doctor qui dépasse 5 s** (disque lent, SQLite verrouillée) : `warning` « Check timed out » — `runAll()` n'est jamais bloquée par un check.
14. *Supprimé (décision one-shot du 3 juillet 2026)* — plus aucun mécanisme de mise à jour, donc plus de cas « Sparkle hors ligne ».
15. **Keychain refusé au moment du Retry** (REQ-SET-37) : l'invite peut réapparaître ; refus → l'état reste « Keychain access needed », jauges `--`, aucun re-prompt en boucle (au plus 1 par action utilisateur).
16. **Quit via power button avec prompts en attente** : auto-libération de tous les `PendingPrompt` (réponse vide) avant `terminate` — les agents reprennent leurs dialogues natifs, aucune session bloquée (fail-open, invariant architecture §7.1).
17. **`~/.agentdash/bin` non inscriptible** (permissions cassées) : « Reinstall Helper » échoue proprement → détail avec le chemin et l'erreur POSIX, remède **Reveal in Finder** ; jamais de crash.
18. **Locale 12 h système vs réglage 24 h de l'app** : le picker Clock de l'app est la seule source pour nos surfaces ; la fenêtre Settings elle-même suit le système (dates relatives via `RelativeDateTimeFormatter`).

---

## 6. Critères d'acceptation

1. **Structure** — Given l'app lancée, When j'ouvre Settings via la menu bar, Then une fenêtre redimensionnable s'ouvre avec la sidebar (7 items dans l'ordre spécifié), le bouton power rouge en haut à gauche, sans chevaucher la zone du panel notch ; When je redimensionne la sidebar puis rouvre Settings, Then largeur, frame et onglet sélectionné sont restaurés.
2. **Power Quit** — Given Settings ouverte et une permission en attente dans le notch, When je clique le bouton power, Then AgentDash quitte immédiatement et le terminal affiche le dialogue natif de permission (fail-open vérifié).
3. **Effet immédiat** — Given le panel notch ouvert à côté de Settings, When je bascule Density sur Colossal puis Glass opacity au maximum, Then le panel reflète chaque changement en moins d'une frame perceptible et sans réouverture ; When je relance l'app, Then les valeurs sont conservées.
4. **Hooks Ready** — Given `~/.cursor/hooks.json` absent (état réel de cette machine), When j'active le toggle Cursor de la carte Agent hooks, Then le fichier est créé, le badge passe « Ready » en moins de 2 s ; When je supprime manuellement 2 entrées du fichier, Then au plus 60 s plus tard le badge passe « Needs repair » et un clic sur Repair le ramène à « Ready ».
5. **Prompt handling** — Given `Handle prompts in = Terminal only`, When Claude Code demande une permission, Then aucun prompt actionnable n'apparaît dans le notch (état `waiting` visible sans boutons) et le dialogue du terminal s'affiche immédiatement.
6. **Notifications** — Given le toggle maître on et la permission accordée, When je clique Send Test Notification, Then une notification s'affiche (avec son si Play sound est on) ; When je passe le seuil 5 h de 80 % à 50 % avec une jauge à 63 %, Then l'alerte de budget 5 h est émise dans la seconde ; When je coupe le toggle maître, Then plus aucune notification n'est émise.
7. **Shortcuts** — Given l'onglet Shortcuts, When j'assigne ⌘N à l'action Allow, Then les lignes Allow et Deny affichent « Conflict » et l'assignation est refusée ; When j'assigne une combinaison réservée par macOS, Then la bannière « could not be registered » apparaît ; When aucun prompt n'est visible, Then ⌘A dans Safari conserve son sens natif.
8. **Doctor round-trip** — Given l'app saine, When j'ouvre Doctor, Then tous les checks passent en moins de 2 s et « Hook relay round-trip » affiche une latence chiffrée ; When je supprime `~/.agentdash/bin/agentdash-hook` et relance Run Checks, Then « Helper binary » passe rouge, un clic sur Reinstall Helper le répare et le round-trip repasse vert automatiquement.
9. **Doctor badge & health notice** — Given le Wi-Fi coupé et 3 polls d'usage échoués, When je regarde la sidebar, Then Doctor porte un badge, le notch affiche « Usage may be inaccurate — check Doctor », et un clic sur ce badge ouvre l'onglet Doctor sur le check « Claude usage » en warning avec l'horodatage du dernier succès.
10. **Permission notifications refusée** — Given la permission retirée dans System Settings, When j'ouvre l'onglet Notifications, Then la bannière s'affiche et « Open System Settings » ouvre le volet Notifications ; le check Doctor correspondant est rouge avec le même remède.
11. **About one-shot** — Given l'onglet About, Then il affiche la version + build, la ligne statique « To update: replace AgentDash.app with a newer build. », le lien Documentation locale, les boutons Logs et la liste Acknowledgements ; et aucune requête réseau n'est émise depuis cet onglet (vérifiable au proxy pendant toute la session).
12. **États réels** — Given launch at login activé puis l'app retirée des Login Items dans System Settings, When je rouvre l'onglet General, Then le toggle reflète l'état système réel (off ou approval requis), pas la valeur mémorisée.

---

## 7. Dépendances (autres fichiers du plan) et risques

### 7.1 Dépendances

| Fichier | Ce que 13 en consomme / lui impose |
|---|---|
| `01-architecture.md` | modules SettingsKit/DoctorKit, budgets auto-mesure (check Performance), logging/export (§7.3) |
| `02-data-model.md` | `AppSettings` (toutes les clés et défauts cités), `HooksStatus`, `NotificationKind.test`, `UsageAccount`, `CursorUsageMeasure` — **impose** l'ajout de `menuBarShowsUsage: Bool = true` (déjà demandé par `06`) et la suppression des clés `betaChannel`/`automaticUpdateChecks` (décision one-shot) |
| `03-integration-claude-code.md` | REQ-CLA-04 (définition de « Ready »), REQ-CLA-03 (backups listés), REQ-CLA-06 (re-check périodique), REQ-CLA-10 (resync binaire), REQ-CLA-66 (retry Keychain) |
| Fichier intégration Cursor (`04`, en cours) | `HooksInstaller` Cursor (statuts, création de `hooks.json`), check « Cursor database » (détails SQLite), état de connexion usage Cursor |
| `05-notch-ui.md` | REQ-NUI-10/14/21/26/44 (effets des toggles, panel ouvert pendant Settings, verrou pill usage) ; ce fichier lui fournit la zone anti-chevauchement (REQ-SET-04) |
| `06-menubar.md` | REQ-MBR-01 (toggle), REQ-MBR-26 (avertissement aucune surface), item « Settings… » du popover |
| `09-token-usage.md` | REQ-USG-06/27/33/34 (toggles, Rebuild stats, health notice → Doctor, états de santé) |
| `10-local-servers.md` | REQ-SRV-08 (exclusions de scan dans la zone Advanced de Doctor) |
| Fichiers notifications, prompts, `14-onboarding-distribution.md` | émission effective des notifications (ce fichier ne fait que les régler), portée exacte de `promptHandling`, onboarding et modèle de mise à jour manuelle (repris par REQ-SET-72) |

### 7.2 Risques

| # | Risque | Impact | Atténuation |
|---|---|---|---|
| S1 | Sémantique exacte de « prompt handling location » d'AgentPeek inconnue (3 valeurs = interprétation) | Moyen (UX divergente) | REQ-SET-13 marquée hypothèse ; sémantique testée au banc prompts ; ajustable sans migration (enum `PromptHandling` déjà à 3 cas) |
| S2 | Détection de conflits de raccourcis limitée : l'échec `RegisterEventHotKey` n'est observable qu'à l'armement (prompt visible) | Faible | armement d'essai immédiat à l'assignation (REQ-SET-45) + bannière persistante alimentée par les échecs réels |
| S3 | Attribut quarantaine sur le binaire copié (check REQ-SET-54) : comportement Gatekeeper en build signée réelle non encore mesuré | Élevé (risque R4 de `00`) | le round-trip (REQ-SET-55) détecte le blocage quel qu'en soit le mécanisme ; banc system-integration n°4 avant release |
| S4 | — supprimé (décision one-shot du 3 juillet 2026 : plus de Sparkle) | — | — |
| S5 | Un remède Doctor qui échoue en boucle (ex. disque plein) pourrait inciter au clic répété | Faible | après 2 échecs consécutifs du même remède, le bouton devient « See details » (log + chemin), plus de re-run auto |
| S6 | Divergence défauts AgentPeek/AgentDash (défauts non documentés : seuils 80 %, largeurs sidebar) | Faible | valeurs marquées [TRANCHÉ produit], centralisées dans `AppSettings` — ajustement en une ligne |

---

## 8. Découpage en tâches

| ID | Tâche | Taille | Dépendances |
|---|---|---|---|
| S1 | Fenêtre : `SettingsWindowController` singleton, `NavigationSplitView`, sidebar redimensionnable, power button, positionnement anti-notch, persistance frame/onglet, points d'entrée (⌘,, popover, reopen) | **M** | DashCore |
| S2 | `SettingsStore` : mutations typées, debounce 500 ms, table d'effets de bord, décodage tolérant des defaults | **M** | 02 §6.1 |
| S3 | Onglet General : toggles surfaces + launch at login (`SMAppService`, états réels) + picker prompt handling | **M** | S1, S2 |
| S4 | Cartes Agent hooks : statuts, toggles install/repair/uninstall, spinner, re-check 60 s | **M** | S3, `HooksInstaller` (03/04) |
| S5 | Onglet Notifications : toggles, seuils 50–100 %, Test notification, bannière permission + demande d'autorisation | **M** | S2, fichier notifications |
| S6 | Onglet Appearance : 12 contrôles, aperçu temps réel, verrou pill usage mode, picker Display | **M** | S2, 05 |
| S7 | Onglet Usage : toggles agents, états de connexion (Keychain/Cursor), picker compte, mesure Cursor, barres, countdown, daily stats | **M** | S2, 09 |
| S8 | Onglet Shortcuts : recorders KeyboardShortcuts, conflits internes, armement d'essai, bannière d'échec, Restore Defaults | **M** | S2, fichier prompts (hotkeys) |
| S9 | DoctorKit noyau : `DoctorCheck`/`DoctorFinding`/`DoctorStore`, `runAll()` TaskGroup + timeouts, dispatch des remèdes, re-checks de fond + badge | **L** | DashCore |
| S10 | Checks Hooks & IPC : claudeHooks, cursorHooks, relayBinary (hash + quarantaine), **relayRoundTrip** (self-test spawné), ipcSocket, hookCoexistence | **L** | S9, 03/04, HookServer |
| S11 | Checks Data/Usage/System/App : transcripts, DB Cursor, usage ×2 (ingestion `UsageStore.health`), notifications, login item, performance (task_info), backups | **L** | S9, 03/04/09 |
| S12 | Onglet Doctor UI : liste groupée, états visuels, Tools (Rebuild stats, Export logs, Open folder), zone Advanced | **M** | S9–S11 |
| S13 | Onglet About : identité (version + build), ligne statique de mise à jour manuelle, lien documentation locale, logs, acknowledgements générés | **S** | S1 |
| S14 | Export de logs : zip (rotation + `OSLogStore` 24 h + rapport Doctor JSON), `NSSavePanel` | **S** | S12 |
| S15 | Tests : décodage tolérant des defaults, sérialisation des actions hooks, simulation des 16 checks (contexte mocké), conflits de raccourcis | **M** | S2, S9 |
| S16 | Banc manuel : checklist des 12 critères d'acceptation §6, rejouée à chaque release | **S** | tout |

Ordre conseillé : S2 → S1 → S3/S4 (le statut « Ready » est le premier livrable visible) → S9/S10 (Doctor et self-test sécurisent tout le reste du développement) → S5–S8 → S11–S14 → S15/S16.
