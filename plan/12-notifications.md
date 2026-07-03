# 12. Notifications système

> Spécification des notifications macOS natives d'AgentDash (nom provisoire), rédigée le 3 juillet 2026.
> Conforme à `plan/01-architecture.md` (décisions A1–A11, D11 de la recherche system-integration) et `plan/02-data-model.md` (`NotificationKind`, `NotificationEvent`, `AppSettings`, machine à états §3).
> Convention : **[VÉRIFIÉ]** = adossé aux recherches ou aux docs officielles ; **[HYPOTHÈSE]** = à valider en implémentation. Les libellés exacts d'AgentPeek n'étant pas publics, tous les textes d'interface de ce document sont des formulations propres **[HYPOTHÈSE — libellés à ajuster si des captures d'AgentPeek deviennent disponibles]**.

---

## 1. Objectif & périmètre

AgentDash émet des notifications macOS natives (`UNUserNotificationCenter`) pour ramener l'attention de l'utilisateur quand il ne regarde ni le notch ni la barre de menus : agent en attente d'une décision, budget d'usage proche de la limite, session apparemment bloquée, tour terminé. Les notifications sont le **troisième canal d'attention**, complémentaire de l'auto-expand du notch et du point orange de la barre de menus — jamais un canal de décision exclusif : tout prompt reste actionnable dans le notch et dans le terminal (fail-open).

**Sections d'AGENTPEEK_FEATURES.md couvertes** :

| Section | Contenu couvert ici |
|---|---|
| §9 Notifications | toggle maître + sons, demandes de permission, alertes de budget (seuils 50–100 % sur 5 h/7 j), alertes « stuck-session », alertes de tâche terminée, « Test notification » depuis Settings |
| §10 Settings → Notifications | onglet complet (structure, textes, comportements) |
| §2.2 / §14.3 (par renvoi) | articulation avec le point orange menu bar et l'auto-expand du notch |
| §13 changelog | v0.1.7 (introduction des 4 types), v0.1.8 (réglages étendus), v0.1.26–0.1.28 (test notification), v0.2.9 (notifications de fin de tâche) |

**Hors périmètre de ce fichier** : les « prompts de mise à jour avec l'icône de l'app » et la fenêtre « What's New » (§9 features, dernier point) relèvent de Sparkle et du fichier distribution/updates ; le contenu du prompt inline lui-même (boutons, hotkeys, `PromptStore`) relève de `plan/08-actions-inline.md` et des fichiers d'intégration agents ; le point orange relève de `plan/06-menubar.md` (REQ-MBR-04).

---

## 2. Exigences détaillées

### 2.1 Autorisation et cycle de vie

- **REQ-NOT-01 (P0)** — La demande d'autorisation (`requestAuthorization(options: [.alert, .sound])`) est déclenchée par une **étape dédiée de l'onboarding** (bouton « Enable Notifications », étape passable via « Skip ») — jamais à froid au premier lancement sans contexte. L'app ne demande pas `.badge` (app `LSUIElement`, aucune icône Dock à badger).
- **REQ-NOT-02 (P0)** — Si le statut est `notDetermined` (onboarding sauté) et que l'utilisateur active le toggle maître **ou** presse « Send Test Notification » dans Settings → Notifications, la demande d'autorisation système est déclenchée à ce moment-là, puis l'action initiale reprend si l'autorisation est accordée.
- **REQ-NOT-03 (P0)** — Le statut réel (`UNUserNotificationCenter.getNotificationSettings`) est relu au lancement et **à chaque affichage** de l'onglet Settings → Notifications (jamais mis en cache durablement — l'utilisateur peut le changer dans Réglages Système). Statut `denied` avec toggle maître actif ⇒ bannière d'avertissement dans l'onglet + bouton « Open System Settings… » ouvrant le panneau Notifications (`x-apple.systempreferences:com.apple.preference.notifications` **[HYPOTHÈSE — deep link à valider sur macOS 14+]**).
- **REQ-NOT-04 (P0)** — Les catégories de notifications (`UNNotificationCategory` : `PERMISSION_REQUEST` avec actions, `PLAN_REVIEW`, `BUDGET_ALERT`, `STUCK_SESSION`, `TASK_COMPLETE`, `TEST`) sont (ré)enregistrées à **chaque lancement**, avant le premier post possible (dans la séquence de démarrage 01-architecture §4.3, étape 6).
- **REQ-NOT-05 (P0)** — `userNotificationCenter(_:willPresent:)` retourne `[.banner, .list]` (+ `.sound` si le son est actif) : les notifications s'affichent même quand AgentDash est l'app « active » (cas rare : fenêtre Settings au premier plan).
- **REQ-NOT-06 (P1)** — Check Doctor « Notifications » : si `notificationsMasterEnabled == true` et statut système `denied`, Doctor affiche un avertissement avec le correctif guidé (ouvrir Réglages Système). Statut `notDetermined` ⇒ information (« Not requested yet »).

### 2.2 Catalogue des événements déclencheurs

- **REQ-NOT-07 (P0)** — Le catalogue est **fermé** : exactement cinq `NotificationKind` (`permissionRequest`, `budgetAlert`, `stuckSession`, `taskComplete`, `test` — `02-data-model.md` §5). Aucun autre post système n'existe dans l'app.
- **REQ-NOT-08 (P0)** — **Permission demandée** : déclenchée quand une session live et non dismissée **entre en `waiting(*)`** (T5–T7 Claude, C5/C7 Cursor). Deux variantes : (a) un `PendingPrompt` actionnable existe (hook « décision » connecté) ⇒ notification **avec actions** selon le payload ; (b) `waiting` détecté sans prompt actionnable (réconciliation Cursor `hasBlockingPendingActions`, hooks non installés) ⇒ notification **sans actions** (le clic ouvre la surface). Gating : `notifyPermissionRequests == true`.
- **REQ-NOT-09 (P0)** — **Alerte de budget** : à chaque mise à jour d'une `UsageWindow` de kind `fiveHour` ou `sevenDay`, si `utilization ≥ seuil` (`budgetThreshold5h` / `budgetThreshold7d`, plage 50–100) et qu'aucune alerte n'a été émise pour la clé `(fenêtre, seuil, cycle)`, une notification part. Le « cycle » est identifié par `resetsAt` (les fenêtres Claude sont des blocs à reset : l'utilisation est monotone croissante dans un cycle — pas d'hystérésis nécessaire). Gating : `notifyBudgetAlerts == true`.
- **REQ-NOT-10 (P0)** — **Session bloquée (« stuck »)** — définition exacte, unique dans tout le produit (`02-data-model.md` §3.4 et REQ-CLA-33) : une session en `executing` ou `thinking` **sans aucun événement** (hook, ligne de transcript, mise à jour DB Cursor) depuis `stuckThresholdSeconds` (défaut **120 s**, réglable dans Doctor/avancé) passe `isStale = true` **sans changer d'état**. La notification part sur la transition `isStale : false → true` (début d'épisode), **une seule fois par épisode** ; l'épisode se termine au prochain événement (`isStale = false`). Une session `waiting` ou `idle` n'est **jamais** stuck (attendre l'utilisateur n'est pas être bloqué) ; un `Bash` de 10 minutes silencieux, lui, l'est — c'est voulu : l'utilisateur juge. Gating : `notifyStuckSessions == true`.
- **REQ-NOT-11 (P0)** — **Tâche terminée (fin de tour)** : déclenchée par le hook `Stop` (Claude, transition T13 → `idle`) et par `stop` avec `status == "completed"` (Cursor, C8). **Non déclenchée** par : `StopFailure` (T14 — le tour a échoué, pas fini), `stop` Cursor `aborted`/`error`, `SessionEnd` seul (fermeture sans fin de tour), fin de subagent (`SubagentStop` — le tour parent continue). Gating : `notifyTaskComplete == true`.
- **REQ-NOT-12 (P1)** — `StopFailure(rate_limit)` (REQ-CLA-34) ne crée **pas** de type de notification propre : le présent fichier **exige** qu'il déclenche un refresh d'usage immédiat (exigence imposée aux fichiers 03/usage, cf. §7 « Éléments que ce fichier IMPOSE aux autres ») ; si la jauge rafraîchie franchit le seuil, l'alerte de budget part par le chemin normal (dédup REQ-NOT-28 incluse).
- **REQ-NOT-13 (P2)** — Alerte de budget pour la fenêtre **mensuelle Cursor** (`monthly`), avec seuil dédié `budgetThresholdMonthly: Int = 90` à ajouter dans `AppSettings` **[HYPOTHÈSE produit — AgentPeek ne documente que 5 h/7 j ; extension naturelle]**. Cycle = cycle de facturation (`billingCycleEnd`).

### 2.3 Contenu des notifications

- **REQ-NOT-14 (P0)** — Chaque notification respecte exactement les contenus de la table §4.2 (titre, sous-titre, corps, en anglais). Les corps sont tronqués à **160 caractères** (ellipse « … »), une seule ligne logique (les sauts de ligne du Markdown sont aplatis). Le corps d'une notification de permission utilise `PermissionRequest.displayTitle` (reformulation « honnête ») — jamais le `tool_input` intégral. Conformément à la politique de logs (01-architecture §7.3), le **contenu** des notifications n'est jamais écrit dans les logs (seuls kind, dedupKey et horodatage le sont).
- **REQ-NOT-15 (P0)** — Son : `content.sound = .default` si et seulement si `notificationSoundEnabled == true` (toggle unique, tous types) ; sinon `nil` (notification silencieuse). Aucun son custom en v1 (sons par type = piste P2).
- **REQ-NOT-16 (P0)** — Groupement : `threadIdentifier = "\(agent)|\(sessionID.rawID)"` pour `permissionRequest`/`stuckSession`/`taskComplete` (le Centre de notifications empile par session) ; `threadIdentifier = "usage"` pour `budgetAlert` ; `interruptionLevel = .active` (`.timeSensitive` exigerait un entitlement dédié — écarté, **[VÉRIFIÉ]** research §7.2).

### 2.4 Actions sur les notifications

- **REQ-NOT-17 (P0)** — **Oui, on peut répondre à une permission depuis la notification.** Catégorie `PERMISSION_REQUEST` : actions `ALLOW` (« Allow ») et `DENY` (« Deny », `options: [.destructive]`), toutes deux **sans** `.foreground` (la décision s'applique en arrière-plan, sans activer d'app). La décision emprunte **le même chemin de code** que les hotkeys et les boutons du notch (`PromptStore.resolve(promptID:decision:source:)`) avec `DecisionSource.notification` (enum déjà prévue, `02-data-model.md` §4.1).
- **REQ-NOT-18 (P0)** — Clic sur le **corps** de la notification (`UNNotificationDefaultActionIdentifier`) : ouvre la surface d'attention — notch activé ⇒ `NotchController.open(reason: .attention)` + scroll vers la session concernée ; notch désactivé ⇒ ouverture du popover menu bar via `statusItem.button?.performClick(nil)` **[HYPOTHÈSE — geste programmatique à valider]** ; les deux désactivés ⇒ ouverture de la fenêtre Settings.
- **REQ-NOT-19 (P0)** — Action reçue pour un prompt **déjà résolu, relâché (auto-libération T12/C6) ou expiré** : no-op silencieux (log `.info`, catégorie `ui`). Jamais d'erreur visible, jamais de « re-réponse » sur une connexion IPC fermée (invariant 02-data-model §8.1-3).
- **REQ-NOT-20 (P0)** — **Retrait actif** : dès qu'un prompt est résolu (quelle que soit la source : notch, hotkey, notification, terminal, timeout), que l'épisode stale se termine, ou que la session passe `.ended`, la notification livrée correspondante est retirée (`removeDeliveredNotifications(withIdentifiers:)`). Une notification obsolète ne doit jamais rester actionnable dans le Centre de notifications.
- **REQ-NOT-21 (P1)** — Catégorie `PLAN_REVIEW` pour les payloads `plan` : actions `APPROVE` (« Approve ») / `REJECT` (« Reject », destructive), mêmes règles que REQ-NOT-17 (le kind reste `permissionRequest` — la catégorie UN ne sert qu'aux actions affichées). Les payloads `question` n'ont pas d'action inline en v1 (le clic ouvre le notch).
- **REQ-NOT-22 (P2)** — « Deny with feedback » et réponse texte aux questions via `UNTextInputNotificationAction` **[HYPOTHÈSE — non documenté chez AgentPeek ; ergonomie à prototyper]**.
- **REQ-NOT-23 (P0)** — **Pas d'action « Always Allow » dans la notification** : elle exige le choix d'une `PermissionSuggestion` (portée session/projet/user) — décision trop riche pour un bouton de notification ; réservée au notch (⌥A).

### 2.5 Réglages (Settings → Notifications)

- **REQ-NOT-24 (P0)** — Le **toggle maître** (`notificationsMasterEnabled`) coupe tout post côté app (on ne poste pas — jamais de désinscription système, D11 **[VÉRIFIÉ]** research §7.2). Les **toggles par type** (`notifyPermissionRequests`, `notifyBudgetAlerts`, `notifyStuckSessions`, `notifyTaskComplete`) gèrent chacun leur kind et sont désactivés visuellement (grisés) quand le maître est off. « Send Test Notification » ignore les toggles par type **et** le toggle maître (c'est un test), mais pas l'autorisation système.
- **REQ-NOT-25 (P0)** — Seuils de budget : deux contrôles (fenêtre 5 h, fenêtre 7 j), plage **50–100 %**, pas de 5 **[HYPOTHÈSE — granularité AgentPeek inconnue]**, défaut **80**. Prise d'effet immédiate : le changement de seuil change les clés de dédup (REQ-NOT-28) ⇒ si l'utilisation courante dépasse déjà le **nouveau** seuil, une alerte part à la prochaine évaluation — comportement assumé et documenté (l'utilisateur vient de demander à être prévenu à ce niveau). Le réglage d'affichage `countdownFrom100` ne change **rien** aux seuils (toujours exprimés en % consommé).
- **REQ-NOT-26 (P0)** — Bouton **« Send Test Notification »** : poste immédiatement une notification kind `.test` (contenu §4.2), son selon le toggle courant. Statut `notDetermined` ⇒ demande d'autorisation d'abord (REQ-NOT-02) ; `denied` ⇒ pas de post, mise en évidence de la bannière d'avertissement (léger shake **[HYPOTHÈSE animation]**).

### 2.6 Déduplication et throttling (anti-spam)

- **REQ-NOT-27 (P0)** — Identifiants de requête **stables** (le re-post avec le même identifiant **remplace** la notification livrée au lieu d'empiler — comportement documenté d'`UNUserNotificationCenter` **[VÉRIFIÉ doc Apple]**) : `"prompt|<agent>|<rawID>"` (permission), `"stuck|<agent>|<rawID>"`, `"complete|<agent>|<rawID>"`, `"budget|<fenêtre>|<seuil>|<cycle>"` ; `.test` = UUID à chaque fois. Ces identifiants sont aussi les `dedupKey` de `NotificationEvent`.
- **REQ-NOT-28 (P0)** — Budget : **au plus une** notification par `(fenêtre, seuil, cycle)` — registre en mémoire `firedBudgetKeys: Set<String>`, purgé pour une fenêtre quand son `resetsAt` change (rollover, reset des jauges). Une valeur retenue après échec de refresh (`isStale == true` sur la jauge) ne déclenche jamais de nouvelle évaluation (même valeur ⇒ même résultat, et pas d'alerte sur données douteuses).
- **REQ-NOT-29 (P0)** — Permission : au plus **1 post / session / 10 s** ; si plusieurs prompts se succèdent plus vite (rafale allow-deny-allow), les posts intermédiaires sont coalescés — le dernier contenu remplace (identifiant stable REQ-NOT-27). Le retrait (REQ-NOT-20) reste immédiat à chaque résolution.
- **REQ-NOT-30 (P1)** — Tâche terminée : les tours d'une durée < **5 s** (entre `UserPromptSubmit` et `Stop`) ne notifient pas **[HYPOTHÈSE produit — anti-spam pour les échanges courts, AgentPeek non documenté]** ; au plus 1 post / session / 15 s (remplacement par identifiant stable).
- **REQ-NOT-31 (P0)** — Au lancement de l'app : retrait de toutes les notifications livrées de kinds `permission` et `stuck` (périmées par définition après un redémarrage — les prompts sont morts avec les connexions IPC) ; `budget` et `complete` restent (informatives). Implémentation : `getDeliveredNotifications()` puis filtrage par préfixe d'identifiant.

### 2.7 Interaction avec le point orange et l'auto-expand — qui prime

- **REQ-NOT-32 (P0)** — Hiérarchie des trois canaux d'attention, à l'arrivée d'un `waiting(*)` :
  1. **Point orange menu bar** (REQ-MBR-04) : état **permanent dérivé** (`SessionStore.hasPendingAttention`) — toujours affiché, jamais throttlé ni supprimé. C'est l'indicateur de vérité.
  2. **Auto-expand du notch** (REQ-NUI-20) : la **réponse primaire**, immédiate (si `autoExpandOnAttention == true` et `promptHandling ≠ .terminalOnly`).
  3. **Notification système** : le **canal de rattrapage** (utilisateur sur un autre écran, autre Space, écran verrouillé). Elle est postée dans le même tick que 1 et 2, **sauf** dans un cas : si le panel du notch est **déjà ouvert par interaction utilisateur** (`NotchOpenReason ∈ {.hover, .click}`) sur l'écran où le prompt s'affiche au moment de l'arrivée — l'utilisateur regarde déjà la surface, la bannière serait du bruit **[HYPOTHÈSE produit — comportement AgentPeek inconnu ; réglage retiré si contre-intuitif en beta]**. Une ouverture par auto-expand (`.attention`) ou `settingsMirror` ne supprime **pas** la notification.
  Aucun canal ne « prime » pour la décision : les trois mènent au même `PendingPrompt` ; les décisions concurrentes sont sérialisées sur MainActor, la première gagne (08 · REQ-ACT-05), et la résolution retire la notification (REQ-NOT-20) et éteint le point orange (par observation du store).
- **REQ-NOT-33 (P0)** — `promptHandling == .terminalOnly` ⇒ **aucune** notification de permission (les prompts sont volontairement laissés au terminal ; ni auto-expand ni bannière) ; `stuckSession`, `taskComplete` et `budgetAlert` ne sont pas affectés par ce réglage.
- **REQ-NOT-34 (P0)** — Les sessions `isDismissed == true` ou `liveness == .ended` ne génèrent plus **aucune** notification (permission, stuck, complete) ; un prompt encore pendant lors du dismiss est retiré du Centre de notifications.

### 2.8 Performance et divers

- **REQ-NOT-35 (P0)** — Latence : le post est déclenché dans le **même tick MainActor** que la mutation de store qui le cause (chaîne hook → UI < 150 ms, budget A9) ; l'appel `add(_:)` est asynchrone et n'est jamais attendu de façon bloquante par l'UI.
- **REQ-NOT-36 (P0)** — Aucune notification pendant l'onboarding tant que l'étape notifications n'est pas atteinte, et aucune quand `LicenseState == .trialExpired` avec notch verrouillé **sauf** `budgetAlert` **[HYPOTHÈSE produit — comportement fin de trial à trancher avec LicensingKit]**.
- **REQ-NOT-37 (P1)** — Tous les posts passent par une unique façade (`NotificationCoordinator.post`) — vérifiable par revue : aucun autre appel à `UNUserNotificationCenter.add` dans le code (règle lint).

---

## 3. Conception technique

### 3.1 Répartition des responsabilités

| Composant | Module | Rôle |
|---|---|---|
| `NotificationPlanner` | **DashCore** (pur, testable) | transforme les signaux typés des stores en `NotificationEvent` (ou `nil`) : toute la logique de gating, dédup, throttling, seuils — **zéro dépendance UserNotifications** |
| `NotificationCoordinator` | **AgentDashApp** (composition root, 01-architecture §3.1) | autorisation, catégories, mapping `NotificationEvent` → `UNNotificationRequest`, delegate (actions), retraits |
| `SettingsKit` | onglet Notifications | toggles, seuils, bouton test, bannière d'autorisation |
| `DoctorKit` | check « Notifications » | REQ-NOT-06 |

### 3.2 API Swift

```swift
// DashCore — planification pure (aucun import UserNotifications)
@MainActor
public final class NotificationPlanner {
    public init(settings: SettingsStore, clock: any ClockProvider)

    // Signaux d'entrée (appelés par EventRouter / les stores, sur MainActor)
    public func sessionEnteredWaiting(_ s: Session, prompt: PendingPrompt?,
                                      notchOpenReason: NotchOpenReason?) -> NotificationEvent?
    public func promptResolved(_ sessionID: SessionID) -> Withdrawal?      // → retrait "prompt|…"
    public func sessionBecameStale(_ s: Session) -> NotificationEvent?
    public func sessionRecovered(_ sessionID: SessionID) -> Withdrawal?    // fin d'épisode stale
    public func turnCompleted(_ s: Session, excerpt: String?,
                              turnDuration: TimeInterval) -> NotificationEvent?
    public func usageWindowUpdated(_ w: UsageWindow) -> NotificationEvent?
    public func sessionClosed(_ sessionID: SessionID) -> [Withdrawal]      // ended/dismissed

    public func makeTestEvent() -> NotificationEvent

    // État interne : firedBudgetKeys: Set<String>, lastPermissionPost/lastCompletePost: [SessionID: Date],
    // staleEpisodes: Set<SessionID> — tout en mémoire, reconstruit au lancement (persistance inutile :
    // REQ-NOT-31 purge les kinds transitoires, la dédup budget se reconstruit au 1er refresh du cycle).
}
public struct Withdrawal: Sendable { public let dedupKey: String }

// AgentDashApp — façade système
@MainActor
public final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    public init(planner: NotificationPlanner, promptStore: PromptStore,
                sessionStore: SessionStore, settings: SettingsStore, notch: NotchControlling?)

    public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    public func bootstrap() async                 // catégories + purge REQ-NOT-31 + refresh statut
    public func requestAuthorization() async -> Bool
    public func refreshAuthorizationStatus() async
    public func post(_ event: NotificationEvent)  // mapping + add(_:) ; fire-and-forget
    public func withdraw(_ w: Withdrawal)
    public func postTest()

    // UNUserNotificationCenterDelegate (callbacks sur queue arbitraire → hop MainActor)
    public func userNotificationCenter(_ c: UNUserNotificationCenter,
        willPresent n: UNNotification) async -> UNNotificationPresentationOptions
    public func userNotificationCenter(_ c: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
}
```

Enregistrement des catégories (`bootstrap()`), aligné sur la recherche (D11 **[VÉRIFIÉ]**) :

```swift
let allow   = UNNotificationAction(identifier: "ALLOW",   title: "Allow")
let deny    = UNNotificationAction(identifier: "DENY",    title: "Deny",    options: [.destructive])
let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve")
let reject  = UNNotificationAction(identifier: "REJECT",  title: "Reject",  options: [.destructive])
center.setNotificationCategories([
    UNNotificationCategory(identifier: "PERMISSION_REQUEST", actions: [allow, deny], intentIdentifiers: []),
    UNNotificationCategory(identifier: "PLAN_REVIEW",        actions: [approve, reject], intentIdentifiers: []),
    UNNotificationCategory(identifier: "BUDGET_ALERT",  actions: [], intentIdentifiers: []),
    UNNotificationCategory(identifier: "STUCK_SESSION", actions: [], intentIdentifiers: []),
    UNNotificationCategory(identifier: "TASK_COMPLETE", actions: [], intentIdentifiers: []),
    UNNotificationCategory(identifier: "TEST",           actions: [], intentIdentifiers: []),
])
```

`userInfo` de chaque requête : `{"kind": String, "agent": String, "rawID": String, "promptID": String?}` — suffisant pour router `didReceive` sans état supplémentaire.

### 3.3 Algorithme d'alerte de budget

```
usageWindowUpdated(w):                                # appelé par UsageStore à chaque nouvelle valeur
    si w.kind ∉ {fiveHour, sevenDay}          → nil   # (monthly = P2, REQ-NOT-13)
    si !settings.notificationsMasterEnabled
       ou !settings.notifyBudgetAlerts        → nil
    si w.isStale                              → nil   # valeur retenue après échec : pas d'alerte (REQ-NOT-28)
    seuil  = (w.kind == fiveHour) ? budgetThreshold5h : budgetThreshold7d
    cycle  = w.resetsAt?.ISO8601 ?? "unknown"
    clé    = "budget|\(w.kind)|\(seuil)|\(cycle)"
    purge  : si resetsAt a changé pour ce kind → retirer de firedBudgetKeys toutes les clés du kind
    si w.utilization < Double(seuil)          → nil
    si clé ∈ firedBudgetKeys                  → nil
    firedBudgetKeys.insert(clé)
    → NotificationEvent(kind: .budgetAlert, dedupKey: clé,
                        title/body: table §4.2 avec % arrondi et resetsAt formaté)
```

Propriété clé : l'utilisation étant monotone croissante à l'intérieur d'un cycle (blocs à reset — pas de fenêtre glissante), la clé `(fenêtre, seuil, cycle)` garantit exactement une alerte par cycle sans hystérésis. Changer le seuil crée une nouvelle clé (comportement REQ-NOT-25). L'évaluation au premier refresh après lancement peut légitimement tirer (l'utilisateur découvre qu'il est à 90 %).

### 3.4 Séquence — permission relayée avec décision depuis la notification

```
Claude Code                agentdash-hook        HookServer/EventRouter      PromptStore        NotificationPlanner/Coordinator     macOS
    │ PermissionRequest         │                        │                       │                      │                             │
    ├── spawn ──────────────────►                        │                       │                      │                             │
    │                           ├── socket NDJSON ──────►│                       │                      │                             │
    │                           │   (connexion GARDÉE)   ├── DashEvent ─────────►│ add(PendingPrompt)   │                             │
    │                           │                        │                       ├── waiting(.permission) → SessionStore              │
    │                           │                        │                       ├──────────────────────► sessionEnteredWaiting(…)    │
    │                           │                        │                       │                      │  gating + throttle 10 s     │
    │                           │                        │                       │                      ├── post("prompt|claude|<id>")►  bannière
    │                           │                        │                       │   (en parallèle : auto-expand notch + point orange) │
    │                           │                        │                       │                      │        utilisateur clique « Allow »
    │                           │                        │                       │                      ◄── didReceive(ALLOW) ────────┤
    │                           │                        │                       ◄── resolve(promptID, .allow, source: .notification) │
    │                           │                        ◄── reply(decision) ────┤                      │                             │
    │                           ◄── réponse sur la MÊME connexion                ├── promptResolved ───► withdraw("prompt|…")         │
    ◄── stdout JSON ────────────┤                        │                       │   waiting → executing (T8)                         │
```

Points de robustesse : si `didReceive` arrive **après** la résolution (course clic notch / clic notification), `PromptStore.resolve` détecte le prompt absent et retourne `.alreadyResolved` ⇒ no-op (REQ-NOT-19). Si l'app a été relancée entre-temps, `promptID` est inconnu ⇒ même chemin. Le retrait REQ-NOT-20 minimise la fenêtre de course.

### 3.5 Détection « stuck » — implémentation

Un unique timer mutualisé 1 s (01-architecture §5.2) évalue les sessions `executing`/`thinking` : `now − lastEventAt ≥ stuckThresholdSeconds` ⇒ `SessionStore` pose `isStale = true` et notifie le planner (`sessionBecameStale`). Le planner enregistre l'épisode (`staleEpisodes.insert(sessionID)`) et n'émettra plus rien pour cette session tant que `sessionRecovered` (prochain événement quelconque : hook, ligne de transcript, poll DB) n'a pas retiré l'épisode. `didWakeNotification` réévalue immédiatement **sans** notifier si le dépassement provient du sommeil de la machine : si `now − lastEventAt` a « sauté » pendant la veille (délai mesuré au réveil > 2 × threshold sans tick intermédiaire), l'épisode est marqué silencieusement et seule l'absence d'événement **post-réveil** pendant un nouveau `stuckThresholdSeconds` notifie **[HYPOTHÈSE — heuristique anti-faux-positif au réveil, à calibrer]**.

---

## 4. Spécification UX/UI

### 4.1 Onglet Settings → Notifications (fenêtre Settings, sidebar)

```
┌──────────────────────────────────────────────────────────────┐
│  Notifications                                               │
│                                                              │
│  ⚠ Notifications are disabled in System Settings.            │   ← bannière seulement si denied
│     AgentDash can’t alert you until you allow them.          │
│                                    [Open System Settings…]   │
│                                                              │
│  Enable notifications                              [●  ON ]  │   ← toggle maître
│  Play sound                                        [●  ON ]  │
│  ────────────────────────────────────────────────────────────│
│  ALERTS                                                      │   ← section grisée si maître OFF
│  Permission requests                               [●  ON ]  │
│     Notify when an agent is waiting for your approval.       │
│  Budget alerts                                     [●  ON ]  │
│     5-hour window threshold          [ 80 % ▾ ]  (50–100 %)  │
│     7-day window threshold           [ 80 % ▾ ]  (50–100 %)  │
│  Stuck sessions                                    [●  ON ]  │
│     Notify when a running session has been silent for 2 min. │
│  Task completed                                    [●  ON ]  │
│     Notify when an agent finishes its turn.                  │
│  ────────────────────────────────────────────────────────────│
│                 [ Send Test Notification ]                   │
└──────────────────────────────────────────────────────────────┘
```

- Les steppers de seuil affichent « 80 % » et bornent 50–100 (pas de 5). Le sous-texte « stuck » reflète la valeur réelle de `stuckThresholdSeconds` (« 2 min » par défaut).
- Densité/typo héritées de la fenêtre Settings (fichier SettingsKit) ; aucun style propre à cet onglet.

### 4.2 Contenu exact des notifications (textes en anglais)

| Kind / cas | `title` | `subtitle` | `body` (≤ 160 car.) | Son | Actions |
|---|---|---|---|---|---|
| `permissionRequest` — permission | `Permission required` | `Claude Code · <projectName>` (ou `Cursor · …`) | `<displayTitle>` — ex. ``Run `npm install` in agentdash`` ; fallback `<toolName> requested` | ● | Allow / Deny |
| `permissionRequest` — plan | `Plan ready for review` | `<Agent> · <projectName>` | `<PlanProposal.title>` — ex. `Migrate storage to SQLite` | ● | Approve / Reject (P1) |
| `permissionRequest` — question | `Claude has a question` | `Claude Code · <projectName>` | texte de la 1re question (+ ` (+2 more)` si multi-questions) | ● | — (clic → notch) |
| `permissionRequest` — waiting sans prompt (Cursor réconcilié) | `Agent waiting for you` | `Cursor · <projectName>` | `Cursor is waiting for your input.` | ● | — (clic → notch) |
| `budgetAlert` — 5 h | `Usage alert: 5-hour window` | `Claude Code` | `Usage reached <82>% (threshold <80>%). Resets in <1 h 24 m>.` | ● | — |
| `budgetAlert` — 7 j | `Usage alert: 7-day window` | `Claude Code` | `Usage reached <85>% (threshold <80>%). Refills <Sun at 3:47 PM>.` | ● | — |
| `stuckSession` | `Session may be stuck` | `<Agent> · <projectName>` | `<title ?? projectName> has been silent for <2> minutes while running.` | ● | — (clic → notch) |
| `taskComplete` | `Task complete` | `<Agent> · <projectName>` | 1re ligne plain-text de `last_assistant_message`, tronquée ; fallback `The agent finished its turn.` | ● | — (clic → notch) |
| `test` | `Test notification` | `AgentDash` | `Notifications are set up correctly — alerts will look like this.` | selon toggle | — |

(● = `.default` si `notificationSoundEnabled`, sinon silencieux. Formats d'heure : horloge 12/24 h selon `clock24h`.)

### 4.3 Onboarding — étape notifications

Étape « **Stay in the loop** » du welcome guidé (SettingsKit) : icône cloche, texte `Get notified when an agent needs your approval, hits a usage threshold, or finishes a task.`, boutons **[Enable Notifications]** (déclenche `requestAuthorization`) et **Skip** (lien discret). Après réponse système (accordée ou refusée), l'étape avance automatiquement ; aucun blocage si refus.

---

## 5. Cas limites & gestion d'erreurs

1. **Autorisation refusée puis réactivée dans Réglages Système** : `refreshAuthorizationStatus()` à chaque affichage de l'onglet et au `didBecomeActiveNotification` de la fenêtre Settings ⇒ la bannière disparaît sans redémarrage.
2. **Action sur prompt mort** (résolu ailleurs, auto-libéré, session tuée, app relancée) : no-op silencieux (REQ-NOT-19) ; la course est bornée par le retrait actif (REQ-NOT-20).
3. **Notification cliquée alors que l'app était quittée** : macOS relance/active l'app cible ; comme AgentDash tourne en permanence (login item), le cas nominal est « app déjà lancée » ; si elle a été quittée, le `didReceive` livré au lancement tombe sur un `promptID` inconnu ⇒ no-op + ouverture de la surface (REQ-NOT-18). **[HYPOTHÈSE — livraison du response au relancement à vérifier pour une app LSUIElement]**
4. **Rafale de prompts** (agent qui redemande immédiatement après un deny) : throttle 10 s + remplacement par identifiant stable ⇒ jamais plus d'une bannière visible par session.
5. **Rollover de fenêtre d'usage pendant le sommeil** : au réveil, le poller resynchronise ; la purge par changement de `resetsAt` ré-arme la dédup avant la première évaluation du nouveau cycle.
6. **`resetsAt` absent** (`nil`, endpoint dégradé) : cycle = `"unknown"` ⇒ une seule alerte par (fenêtre, seuil) jusqu'au retour d'un `resetsAt` réel — dégradation sûre (sous-notification plutôt que spam).
7. **Deux comptes / changement de compte d'usage sélectionné** : les jauges changent de source ⇒ `resetsAt` change ⇒ purge naturelle ; pas de clé par compte en v1 (une seule sélection active, `selectedUsageAccountID`).
8. **Session stuck qui devient waiting** (le signal explicite arrive enfin) : l'événement met fin à l'épisode stale ⇒ retrait de la notification stuck, post éventuel de la notification permission (kinds distincts, pas de conflit).
9. **Réveil de veille** : anti-faux-positif stuck (§3.5) ; aucun post pendant le traitement de `didWakeNotification` tant que les stores ne sont pas resynchronisés.
10. **Focus / Do Not Disturb actif** : macOS retient les bannières ; aucun contournement (`.timeSensitive` écarté — entitlement). Documenté dans la FAQ ; le point orange et l'auto-expand restent opérationnels — c'est précisément la redondance voulue des trois canaux.
11. **`UNUserNotificationCenter` en build de dev non bundlée** : crash connu `bundleProxyForCurrentProcess is nil` **[VÉRIFIÉ en principe, research §7.2]** ⇒ le coordinator n'est instancié que si `Bundle.main.bundleIdentifier != nil` ; tests sur app bundlée uniquement.
12. **Échec de `add(_:)`** (erreur système rare) : log `.error` catégorie `ui`, aucune retry (la prochaine occurrence re-postera) ; jamais d'alerte UI pour un échec de notification.
13. **Suppression manuelle par l'utilisateur dans le Centre de notifications** : indétectable et sans conséquence — l'état de vérité reste `PromptStore`/`SessionStore`.
14. **`stuckThresholdSeconds` modifié à chaud** : appliqué au prochain tick du timer ; les épisodes en cours ne re-notifient pas (dédup par épisode).
15. **Trial expiré** : comportement REQ-NOT-36 ; à trancher définitivement avec LicensingKit (le notch verrouillé ne doit pas générer des notifications de permission inactionnables).
16. **Plusieurs sessions waiting simultanées** : une notification par session (identifiants distincts), empilées par `threadIdentifier` ; le point orange est global, le notch liste tous les prompts.

---

## 6. Critères d'acceptation

1. **Given** l'onboarding à l'étape « Stay in the loop », **When** l'utilisateur clique « Enable Notifications », **Then** la boîte de dialogue système d'autorisation apparaît, et le choix est reflété dans Settings → Notifications sans redémarrage.
2. **Given** les notifications autorisées et `notifyPermissionRequests` actif, **When** une session Claude Code demande une permission (ex. `git push` sans règle), **Then** une bannière « Permission required » apparaît en < 1 s avec les boutons Allow/Deny, **And** cliquer « Allow » fait partir l'outil dans le terminal sans activer aucune app, **And** la bannière disparaît du Centre de notifications.
3. **Given** la même permission résolue via ⌘A dans le notch, **When** on ouvre le Centre de notifications, **Then** la notification de permission n'y figure plus (retrait actif).
4. **Given** `budgetThreshold5h = 80` et une jauge 5 h à 78 %, **When** un refresh la porte à 81 %, **Then** exactement une notification « Usage alert: 5-hour window » part ; **When** les refreshs suivants donnent 85 % puis 92 %, **Then** aucune nouvelle notification ; **When** la fenêtre 5 h bascule (reset) puis atteint de nouveau 80 %, **Then** une nouvelle notification part.
5. **Given** une session `executing` sur un `sleep 300` sans hooks de progression, **When** 120 s s'écoulent sans aucun événement, **Then** une notification « Session may be stuck » part (une seule), l'état de la carte reste `executing`, **And** à la fin de la commande la notification est retirée et `isStale` repasse à false.
6. **Given** `notifyTaskComplete` actif, **When** un tour Claude de plus de 5 s se termine (`Stop`), **Then** une notification « Task complete » part avec un extrait de la dernière réponse ; **When** le tour suivant dure 2 s, **Then** aucune notification (REQ-NOT-30).
7. **Given** le toggle maître OFF, **When** permissions, seuils et fins de tour se produisent, **Then** aucune notification n'est postée ; **When** on presse « Send Test Notification », **Then** la notification de test part quand même (autorisation système accordée).
8. **Given** l'autorisation système refusée, **When** on ouvre Settings → Notifications, **Then** la bannière « Notifications are disabled in System Settings. » est visible et « Open System Settings… » ouvre le panneau Notifications ; **And** Doctor affiche l'avertissement correspondant.
9. **Given** le panel du notch ouvert par survol et affichant la session, **When** une permission arrive pour cette session, **Then** le prompt s'affiche dans le panel et le point orange apparaît, mais aucune bannière système n'est postée ; **Given** le panel fermé et `autoExpandOnAttention = true`, **When** la même permission arrive, **Then** panel auto-ouvert + point orange + bannière, et une décision par n'importe quel canal résout les trois.
10. **Given** dix prompts consécutifs en 30 s sur une même session, **When** on observe le Centre de notifications, **Then** au plus une bannière par tranche de 10 s, toujours à jour du dernier prompt (remplacement), jamais d'empilement.
11. **Given** AgentDash relancé avec une notification de permission encore visible dans le Centre de notifications, **When** l'app termine son démarrage, **Then** cette notification a été retirée (REQ-NOT-31).
12. **Given** `promptHandling = .terminalOnly`, **When** une permission arrive, **Then** ni bannière ni auto-expand (le point orange, état de vérité, reste affiché).

---

## 7. Dépendances (autres fichiers du plan) et risques

**Dépendances amont** :

| Fichier | Ce qu'on en consomme |
|---|---|
| `01-architecture.md` | placement du coordinator dans AgentDashApp, budgets A9, timers mutualisés §5.2, politique de logs §7.3, D11 research |
| `02-data-model.md` | `NotificationKind`/`NotificationEvent`/`dedupKey` (§5), `isStale`/`stuckThresholdSeconds` (§3.4), `DecisionSource.notification` (§4.1), toggles et seuils d'`AppSettings` (§6.1) |
| `03-integration-claude-code.md` | déclencheurs : `Stop` (T13, `last_assistant_message`), `PermissionRequest`, `Notification(permission_prompt)`, REQ-CLA-33 (`isStale`), REQ-CLA-34 (`StopFailure`), REQ-CLA-44 (`AskUserQuestion`) |
| `04-integration-cursor.md` (présumé) | déclencheurs Cursor : hooks bloquants, `stop(status)`, `hasBlockingPendingActions` |
| `05-notch-ui.md` | `NotchOpenReason` (règle de suppression REQ-NOT-32), `open(reason: .attention)` (REQ-NOT-18), REQ-NUI-20 |
| `08-actions-inline.md` | `PromptStore.resolve(promptID:decision:source:)`, sérialisation « une seule décision par prompt » (REQ-ACT-05), routage des actions de notification (REQ-ACT-39), contenu du prompt inline |
| `06-menubar.md` | `hasPendingAttention` (point orange, hiérarchie §2.7), action `openNotch` |
| Fichiers usage / settings / doctor / distribution | jauges `UsageWindow` (+ `resetsAt`), onglet Settings hôte, check Doctor, prompts de mise à jour Sparkle (exclus d'ici) |

**Éléments que ce fichier IMPOSE aux autres** : ① `NotificationPlanner` et `Withdrawal` dans `DashCore` ; ② rappel des transitions de `isStale` et de la résolution de prompt vers le planner (SessionStore/PromptStore) ; ③ exposition de `NotchOpenReason` courant par `NotchUI` ; ④ si REQ-NOT-13 est retenue : `budgetThresholdMonthly` dans `AppSettings` (`02-data-model.md` §6.1) ; ⑤ étape « Stay in the loop » dans l'onboarding (SettingsKit) ; ⑥ déclenchement d'un **refresh d'usage immédiat** sur `StopFailure(rate_limit)` (REQ-NOT-12) — à intégrer côté `03-integration-claude-code.md` (extension de REQ-CLA-34) et fichier usage.

**Risques** :

| Risque | Impact | Mitigation |
|---|---|---|
| `UNUserNotificationCenter` inutilisable en dev non bundlé **[VÉRIFIÉ en principe]** | tests retardés | squelette d'app bundlée dès le jalon 1 ; garde `bundleIdentifier != nil` |
| Action de notification livrée à une app quittée (LSUIElement) au relancement | UX dégradée (clic sans effet) | no-op sûr + ouverture de surface ; banc de test dédié (hypothèse §5.3) |
| Règle de suppression REQ-NOT-32 contre-intuitive (l'utilisateur attend une bannière systématique) | confusion | hypothèse produit isolée derrière un booléen interne ; A/B manuel en beta, retrait facile |
| Faux positifs stuck au réveil de veille ou sur outils légitimement longs | spam / méfiance | heuristique §3.5 + seuil réglable + une seule notif par épisode + retrait actif |
| Deep link Réglages Système changeant selon la version de macOS | bouton mort | fallback : ouvrir `Réglages Système` sans ancre si l'URL échoue |
| Spam de `taskComplete` chez les utilisateurs à tours courts | désactivation du type par l'utilisateur | filtre 5 s (REQ-NOT-30) + throttle + remplacement |

---

## 8. Découpage en tâches

| # | Tâche | Taille | Dépendances |
|---|---|---|---|
| T1 | `NotificationPlanner` (DashCore) : gating, dédup budget/stuck/permission, throttles, `NotificationEvent` — avec tests unitaires exhaustifs (chaque REQ de §2.6 = un cas) | **L** | 02-data-model |
| T2 | `NotificationCoordinator` (AgentDashApp) : autorisation, catégories, mapping requêtes, `willPresent`, purge au lancement | **M** | T1, squelette d'app bundlée |
| T3 | Delegate `didReceive` : routage ALLOW/DENY/APPROVE/REJECT → `PromptStore.resolve(source: .notification)`, default action → ouverture de surface, no-op sur prompt mort | **M** | T2, PromptStore (03/04) |
| T4 | Câblage des déclencheurs : SessionStore (waiting, stale, ended), EventRouter (`Stop`), UsageStore (`usageWindowUpdated`) → planner → coordinator ; retraits croisés | **M** | T1–T3, stores |
| T5 | Onglet Settings → Notifications : toggles, steppers de seuil, bannière denied + deep link, bouton test | **M** | T2, SettingsKit |
| T6 | Étape onboarding « Stay in the loop » | **S** | T2, onboarding SettingsKit |
| T7 | Check Doctor « Notifications » (statut vs toggle) | **S** | T2, DoctorKit |
| T8 | Détection stuck : timer 1 s mutualisé, épisodes, anti-faux-positif réveil | **M** | SessionStore, T1 |
| T9 | Bancs de validation des hypothèses : deep link Réglages, `performClick` popover, action sur app quittée, `UNUserNotificationCenter` en build dev | **S** | T2 |
| T10 | P1/P2 : catégorie `PLAN_REVIEW`, filtre 5 s taskComplete, budget mensuel Cursor, text input deny-with-feedback | **M** | T1–T4 stables |
