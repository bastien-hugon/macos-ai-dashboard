# 9. Suivi de l'usage de tokens

> Spécification du module **UsageKit** (+ pollers `ClaudeUsagePoller`/`CursorUsagePoller` dans `AgentClaude`/`AgentCursor`), rédigée le 3 juillet 2026, conforme à `plan/01-architecture.md` (§1.2, §3.1, §5.1, §6, §7) et `plan/02-data-model.md` (§5, §6.1). Convention identique aux autres documents : **[VÉRIFIÉ]** = adossé aux recherches (`plan/research/claude-code.md` §4, `plan/research/cursor.md` §3) ou à l'inspection locale ; **[HYPOTHÈSE — à valider]** sinon ; **[TRANCHÉ produit]** = valeur choisie par nous quand AgentPeek ne documente pas la sienne.

---

## 1. Objectif & périmètre

Reproduire l'intégralité du suivi d'usage d'AgentPeek pour Claude Code et Cursor : jauges style batterie des fenêtres **5 h / 7 j** de Claude et du **cycle mensuel** de Cursor, countdowns de reset, rétention des valeurs en cas d'échec, statistiques jour par jour, alertes de budget, mode usage du pill, et compteur de tokens par session mis à jour **pendant** le tour.

Sections d'`AGENTPEEK_FEATURES.md` couvertes :

| Section features | Contenu repris ici |
|---|---|
| **§5.1 – §5.2** (intégralité) | fenêtres 5 h/7 j/mensuel, sources, mesures Cursor, `--`, rétention, reset au rollover, stats journalières, jauges batterie, countdown depuis 100 %, refresh + shimmer, mises à jour immédiates, usage health notice, mode usage du pill, sélection de compte |
| **§3.2** (partiel) | « Usage tokens par session : compteurs séparés input/output (ex. “24.6k / 66”), mis à jour en direct pendant le tour » — le **chip de tokens mid-turn** (v0.2.11) ; « Label de compte » (source des données, l'affichage sur la carte relève du document sessions) |
| **§3.3** (partiel) | action « refresh usage » sur la row de session |
| **§9** (partiel) | « Alertes de budget : seuils configurables 50–100 % pour les fenêtres 5h et 7j » (la plomberie `UNUserNotificationCenter` relève du document notifications) |
| **§10 → Usage** | sémantique de tous les réglages de l'onglet Usage (l'UI de la fenêtre Settings relève du document Settings) |
| **§13** | v0.1.7 (teinte de seuil), v0.1.13 (heures de refill exactes), v0.1.17–0.1.19 (reset au rollover), v0.1.20 (mode usage du pill, Auto width), v0.1.24–0.1.25 (usage via `/usage`, rétention), v0.2.6 (stats journalières), v0.2.8 (countdown depuis 100 %), v0.2.10 (dashboard live Cursor, Spend/Weighted/Auto/API, « $X of $Y », health notice), v0.2.11 (sélection de compte, jauges batterie, token chip mid-turn) |

Hors périmètre de ce fichier : usage Codex (hors scope du clone), rendu de la fenêtre Settings, canal de notification système, section usage du popover menu bar (layout dans le document menu bar — les `GaugeModel` fournis ici y sont réutilisés tels quels).

---

## 2. Exigences détaillées

Priorités : **P0** = MVP, P1 = confort, P2 = différé.

### Sources et polling

- **REQ-USG-01 (P0)** — L'usage Claude est obtenu par `GET https://api.anthropic.com/api/oauth/usage` avec les headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20` et `User-Agent: claude-code/<version détectée du CLI>` ; l'`accessToken` est lu à la demande dans le Keychain (item generic password, service `Claude Code-credentials`) et n'est **jamais** persisté par AgentDash. **[VÉRIFIÉ sources — endpoint non documenté officiellement, stabilité = hypothèse claude-code n°5]**
- **REQ-USG-02 (P0)** — La réponse Claude est décodée en quatre fenêtres : `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` (chacune `{utilization: 0–100, resets_at: ISO 8601}` ou `null`), plus `extra_usage` (ignoré en v1, aucun équivalent AgentPeek). Les fenêtres `null` ne produisent pas de jauge. **[VÉRIFIÉ sources]**
- **REQ-USG-03 (P0)** — Le poll Claude est périodique à **180 s** (rate limit par token **[VÉRIFIÉ sources]**), exécuté dans `actor ClaudeUsagePoller`, jamais sur MainActor. Sur 401 : relecture du Keychain (Claude Code rafraîchit lui-même son token — **[VÉRIFIÉ]** `mdat` observé) puis une seule nouvelle tentative ; jamais de refresh OAuth actif par AgentDash **[HYPOTHÈSE claude-code n°5 sur le risque de désynchronisation]**.
- **REQ-USG-04 (P0)** — L'usage Cursor est obtenu via la session locale existante : `cursorAuth/accessToken` lu dans `ItemTable` de `state.vscdb` (lecture seule, via `CursorStateReader`), `userId = sub.split("|")[1]` du JWT, cookie `WorkosCursorSessionToken=<userId>%3A%3A<jwt>`, puis `GET https://cursor.com/api/usage-summary`. Aucun login séparé, token jamais envoyé ailleurs que `cursor.com`. **[VÉRIFIÉ OSS — cursor-stats, cursor-costs]**
- **REQ-USG-05 (P0)** — Le poll Cursor est périodique à **300 s** dans `actor CursorUsagePoller`. Les en-têtes anti-bot (`Origin`, `Referer`, `Sec-Fetch-*`, `User-Agent` Safari) sont envoyés dès la v1 **[VÉRIFIÉ OSS pour leur usage ; nécessité réelle = HYPOTHÈSE cursor n°7]**.
- **REQ-USG-06 (P0)** — Chaque toggle `claudeUsageEnabled` / `cursorUsageEnabled` sur off arrête **complètement** le poller concerné (zéro requête réseau) et retire ses jauges de toutes les surfaces. Conforme au contrat « réseau limité à 4 destinations désactivables » (architecture §8).
- **REQ-USG-07 (P1)** — `POST https://cursor.com/api/dashboard/get-aggregated-usage-events` (`{teamId: -1, startDate, endDate}`) est appelé au plus une fois par heure pour alimenter le détail par modèle et les dollars/jour des stats journalières Cursor. **[VÉRIFIÉ OSS]**

### Fenêtres, countdowns, mesures

- **REQ-USG-08 (P0)** — La jauge Claude 5 h affiche un countdown « **Resets in 2h 14m** » (formats : `≥ 1 h` → `Xh Ym` ; `< 1 h` → `Xm` ; `< 1 min` → `<1m`), recalculé sur le tick partagé de 1 s mais ré-affiché uniquement quand la chaîne change (granularité minute).
- **REQ-USG-09 (P0)** — La jauge Claude 7 j affiche « **Refills Sun at 3:47 PM** » (jour abrégé anglais + heure locale de `resets_at`), au format 12 h ou 24 h selon `AppSettings.clock24h` (« Refills Sun at 15:47 »). **[VÉRIFIÉ features §5.1 pour le texte]**
- **REQ-USG-10 (P0)** — La jauge Cursor affiche le cycle de facturation en cours avec sa date de reset « **Resets Jul 31** » (dérivée de `billingCycleEnd`, dates ISO ou epoch ms en string — les deux formats sont acceptés **[VÉRIFIÉ OSS]**).
- **REQ-USG-11 (P0)** — La mesure mensuelle Cursor est sélectionnable parmi **Spend / Weighted / Auto / API** (`AppSettings.cursorMeasure`, défaut `.weighted`). Mapping : Spend → `individualUsage.plan.used/limit` (cents) ; Weighted → `totalPercentUsed` ; Auto → `autoPercentUsed` ; API → `apiPercentUsed`. **[HYPOTHÈSE cursor n°8 — à valider sur vraies réponses avant gel de l'UI]**
- **REQ-USG-12 (P0)** — En mesure Spend, la jauge affiche « **$X of $Y** » (cents → dollars, 2 décimales, ex. « $12.07 of $60.00 ») ; si `isUnlimited` ou `limit` null : texte « **$12.07 spent · Unlimited** », barre remplacée par le texte seul. **[VÉRIFIÉ OSS pour les champs ; rendu TRANCHÉ produit]**
- **REQ-USG-13 (P1)** — Les barres secondaires **Auto/Composer** et **API** sont affichables dans la vue détail du notch via `cursorShowAutoBar` / `cursorShowAPIBar` (`UsageSubBar`, cf. 02 §5), indépendamment de la mesure principale choisie.
- **REQ-USG-14 (P2)** — Les fenêtres Claude `seven_day_opus` / `seven_day_sonnet`, quand non nulles, sont montrées comme sous-lignes de la vue détail (pas dans le résumé).

### Jauges batterie

- **REQ-USG-15 (P0)** — Chaque jauge est rendue « style batterie » : rectangle arrondi + ergot, remplissage proportionnel, couleur par seuils **exacts** sur le pourcentage **consommé** : `< 70 %` → vert, `70–89,9 %` → jaune, `≥ 90 %` → rouge **[TRANCHÉ produit — AgentPeek ne documente pas ses seuils]**, avec **hystérésis de 2 points** à la redescente (évite le clignotement autour d'un seuil) et interpolation de teinte sur ±3 points autour de chaque seuil (« teinte de seuil près de la limite », v0.1.7).
- **REQ-USG-16 (P0)** — Option `countdownFrom100` (défaut off) : la jauge affiche le **restant** (`100 − utilization`) et se vide comme une batterie ; le texte devient « 67% left » ; la **couleur reste calculée sur le consommé** (batterie pleine = verte). Le basculement du réglage met à jour toutes les jauges immédiatement (cf. REQ-USG-37).
- **REQ-USG-17 (P0)** — Le pourcentage affiché est arrondi à l'entier ; les valeurs de remplissage sont clampées à [0, 100] même si l'API renvoie hors bornes.

### Indisponibilité, rétention, récupération

- **REQ-USG-18 (P0)** — Une jauge affiche « **--** » (texte et barre vide neutre) **uniquement** si aucune valeur n'a jamais été obtenue depuis le lancement pour cette fenêtre (invariant n°5 de 02 §8.1).
- **REQ-USG-19 (P0)** — En cas d'échec de refresh (réseau, 401 persistant, 429, 5xx, parsing), la jauge **retient la dernière valeur** datée (`fetchedAt` conservé, `isStale = true`) — jamais de valeur effacée, jamais de stale silencieux : au survol, un tooltip indique « Last updated 12m ago ».
- **REQ-USG-20 (P0)** — Récupération automatique : le premier poll réussi après une série d'échecs remet `isStale = false`, met à jour la valeur et réévalue les alertes de budget. Sur 429 : back-off exponentiel (période × 2 à chaque échec, plafond 15 min, retour à la période nominale au premier succès).
- **REQ-USG-21 (P0)** — Refus d'accès Keychain (invite déclinée) : jauges Claude à `--`, bouton « Retry Keychain access » dans Settings → Usage ; le reste de l'app fonctionne (dégradation par flux, architecture §7.2).

### Reset au rollover de fenêtre

- **REQ-USG-22 (P0)** — Un timer est armé à la date **exacte** `min(resetsAt)` des fenêtres connues (`DispatchSourceTimer` mutualisé, architecture §5.2). À l'échéance : la jauge échue passe localement à 0 % consommé (ou 100 % restant en mode countdown), `isStale = true` (valeur locale non confirmée), les `dedupKey` d'alertes de budget du cycle échu sont purgées, et un poll immédiat est déclenché pour confirmer la nouvelle fenêtre.
- **REQ-USG-23 (P0)** — `NSWorkspace.didWakeNotification` déclenche `rolloverIfNeeded(now:)` + un poll immédiat (les timers ne tirent pas pendant le sommeil — **[VÉRIFIÉ]** architecture §5.2).

### Statistiques jour par jour

- **REQ-USG-24 (P0)** — Les stats journalières Claude sont **agrégées localement depuis les transcripts** `~/.claude/projects/**/*.jsonl` : somme des `message.usage` des entrées `assistant`, **dédupliquées par `requestId` (dernière entrée gagne)**, incluant `cache_read_input_tokens` + `cache_creation_input_tokens` dans le total consommé (piège du sous-comptage ×100 **[VÉRIFIÉ sources — ccusage]**), regroupées par jour calendaire **local**.
- **REQ-USG-25 (P1)** — Un coût estimé par jour (`costUSD`) est calculé via une table de prix statique par modèle embarquée (style LiteLLM), affiché préfixé « ~ » (estimation) **[TRANCHÉ produit]**.
- **REQ-USG-26 (P0)** — Les stats journalières Cursor proviennent des clés locales `aiCodeTracking.dailyStats.v1.5.<YYYY-MM-DD>` (lignes suggérées/acceptées Tab + Composer) **[VÉRIFIÉ local]** ; les dollars/jour via REQ-USG-07 sont un enrichissement P1.
- **REQ-USG-27 (P0)** — Le calcul initial est fait en tâche de fond (jamais sur MainActor), mis en cache dans `~/Library/Application Support/AgentDash/state/daily-usage.json` (02 §8) puis maintenu **incrémentalement** par les deltas du `TranscriptIngestor` ; un bouton « Rebuild stats » dans Doctor recalcule tout.
- **REQ-USG-28 (P1)** — UI : une vue « Daily usage » (14 derniers jours) accessible depuis la section usage du panel : mini-histogramme + liste de lignes par jour et par agent (cf. §4.4). Toggle `dailyStatsEnabled`.

### Sélection du compte d'usage

- **REQ-USG-29 (P0)** — `UsageStore` publie la liste des `UsageAccount` détectés : Claude = item Keychain (label = email/organisation du JSON OAuth **[HYPOTHÈSE claude-code n°5]**, sinon « Claude account ») ; Cursor = `cursorAuth/cachedEmail` + `stripeMembershipType` **[VÉRIFIÉ local]**. Ces labels alimentent aussi le « label de compte » de la carte de session.
- **REQ-USG-30 (P1)** — Settings → Usage propose un picker « Usage account » listant les comptes détectés (`selectedUsageAccountID`, `nil` = auto). V1 : au plus un compte par agent est détectable ; le picker sélectionne le compte **prioritaire** dont les jauges occupent les surfaces contraintes (pill en mode usage, résumé menu bar) — le panel affiche toujours tous les agents actifs. **[TRANCHÉ produit — multi-comptes réels = hypothèse]**

### Refresh manuel

- **REQ-USG-31 (P0)** — Un bouton refresh (`arrow.clockwise`) est présent dans le header du panel notch et dans le popover menu bar ; l'action « refresh usage » de la row de session (features §3.3) déclenche le même chemin. Anti-rafale : 10 s entre deux refresh manuels (architecture §5.1) — pendant la fenêtre d'interdiction le bouton est inactif.
- **REQ-USG-32 (P0)** — Pendant un refresh manuel, toutes les jauges concernées affichent un **shimmer** (balayage lumineux, cf. §4.5) maintenu jusqu'à la réponse, avec un minimum perceptible de 600 ms ; le refresh périodique silencieux ne shimmer **pas**.

### Usage health notice → Doctor

- **REQ-USG-33 (P0)** — Un badge « usage health notice » apparaît près des jauges quand la précision est douteuse : ≥ 3 échecs consécutifs d'un poller, 401 persistant après relecture Keychain, `resets_at` dans le passé sur deux polls consécutifs (horloge/serveur incohérents), champs `usage-summary` attendus absents (mapping des mesures non résolu), ou compte introuvable. Texte : « **Usage may be inaccurate — check Doctor** », clic → onglet Doctor.
- **REQ-USG-34 (P0)** — L'état de santé (`healthy / degraded(reason) / unavailable`) de chaque flux d'usage est poussé dans `DoctorStore` avec le détail (code d'erreur, horodatage du dernier succès, compte concerné) — jamais de token ni de contenu dans les logs.

### Mode usage du pill réduit

- **REQ-USG-35 (P0)** — Quand `pillUsageMode` est actif, le pill réduit affiche des **mini-jauges live** (Claude 5 h + 7 j, Cursor mensuel selon les toggles et le compte prioritaire) à la place du seul statut. Les mini-jauges reprennent couleurs, rétention et `--` des grandes jauges.
- **REQ-USG-36 (P0)** — En mode usage, la largeur du pill est **verrouillée** sur Wide ou Ultra-wide : si `pillWidthMode == .auto`, la largeur effective devient Wide et le picker Appearance affiche « Auto width » désactivé avec la mention « Unavailable in usage mode » (v0.1.20–0.1.21). Aucune variation de largeur au fil des valeurs (pas de jitter).

### Mise à jour immédiate au changement de réglage

- **REQ-USG-37 (P0)** — Tout changement de réglage d'usage (`cursorMeasure`, `countdownFrom100`, `cursorShowAutoBar/APIBar`, `selectedUsageAccountID`, `clock24h`, toggles par agent) recalcule les `GaugeModel` **synchronement** depuis les derniers instantanés bruts retenus en mémoire (`ClaudeUsageResponse`, `CursorUsageSummary`) — **sans requête réseau ni attente du prochain poll**.

### Notifications de budget

- **REQ-USG-38 (P0)** — Des seuils d'alerte configurables **50–100 %** (pas de 5) existent **par fenêtre** : `budgetThreshold5h` et `budgetThreshold7d` (défaut 80). Une notification `BUDGET_ALERT` est émise quand `utilization` **franchit** le seuil à la hausse (valeur précédente < seuil ≤ nouvelle valeur).
- **REQ-USG-39 (P0)** — Anti-spam : une seule notification par `(fenêtre, seuil, cycle)` — `dedupKey = "<kind>|<seuil>|<resetsAt ISO>"` (02 §5) ; la purge au rollover (REQ-USG-22) réarme l'alerte pour le cycle suivant. L'abaissement d'un seuil dans Settings réévalue immédiatement le franchissement (même dedup).
- **REQ-USG-40 (P2)** — Alerte budget sur le cycle mensuel Cursor : différée (AgentPeek ne la documente que pour 5 h/7 j) ; à instruire seulement si le modèle de réglages évolue.

### Chip de tokens par session (mid-turn)

- **REQ-USG-41 (P0)** — Chaque carte de session Claude affiche un chip « **24.6k / 66** » (input / output, format abrégé §4.6) alimenté par le `TokenTally` de la session : somme des `message.usage` dédupliquée par `requestId` (la dernière entrée d'un même `requestId` **remplace** la précédente — streaming cumulatif **[VÉRIFIÉ sources]**), **mise à jour pendant le tour** au fil des entrées partielles, coalescée à ≤ 300 ms par session (architecture §5.2).
- **REQ-USG-42 (P0)** — Pendant le tour (`TokenTally.isLive == true`), le chip porte un indicateur d'activité discret (point pulsant) ; au hook `Stop`, la valeur se fige et l'indicateur s'éteint. Une session relancée mid-turn conserve son tally (clé `SessionID` stable).
- **REQ-USG-43 (P0)** — Sessions Cursor : pas de tokens par tour fiables (`tokenCount` ≈ 0 **[VÉRIFIÉ local]**) → le chip affiche le **contexte** à la place : « ctx 72% » depuis `contextTokensUsed/contextTokenLimit` ; jamais de fausse valeur de tokens. **[HYPOTHÈSE cursor n°3 : réévaluer si une source apparaît]**
- **REQ-USG-44 (P1)** — L'input affiché du chip Claude est `input_tokens` seul ; le total incluant caches (`+ cache_read + cache_creation`) est visible au survol (tooltip « 24.6k in (1.2M with cache) / 66 out ») — cohérent avec l'affichage AgentPeek compact et l'exactitude ccusage.

### Transverse

- **REQ-USG-45 (P0)** — Aucune donnée d'usage ne quitte la machine ; requêtes uniquement vers `api.anthropic.com` et `cursor.com` ; tokens gardés en mémoire le temps de la requête (02 §8) ; les logs ne contiennent que codes d'erreur, tailles et horodatages.
- **REQ-USG-46 (P0)** — Budgets perfs : les pollers ne réveillent pas l'UI sans changement (comparaison des snapshots avant publication) ; le tick de countdown n'invalide que le texte concerné ; l'agrégation initiale des stats journalières respecte « < 1 s pour 100 Mo de transcripts » (architecture §6) en réutilisant les offsets du `TranscriptIngestor`.

---

## 3. Conception technique

### 3.1 Types et API (UsageKit, protocoles dans DashCore)

```swift
// DashCore — implémenté par AgentClaude.ClaudeUsagePoller et AgentCursor.CursorUsagePoller
public protocol UsageProvider: Sendable {
    var agent: AgentKind { get }
    func discoverAccounts() async throws -> [UsageAccount]
    func fetchUsage(account: UsageAccount.ID) async throws -> UsageSnapshot
}

public struct UsageSnapshot: Sendable {
    public var agent: AgentKind
    public var account: UsageAccount.ID
    public var windows: [UsageWindow]          // cf. 02-data-model.md §5
    public var raw: RawUsagePayload            // instantané brut retenu pour REQ-USG-37
    public var fetchedAt: Date
}

public enum RawUsagePayload: Sendable {
    case claude(ClaudeUsageResponse)           // five_hour / seven_day / seven_day_opus / seven_day_sonnet / extra_usage
    case cursor(CursorUsageSummary)            // usage-summary complet typé (plan, onDemand, cycle, percents)
}

public enum UsageError: Error, Sendable {
    case network(underlying: String)
    case unauthorized                          // 401 après relecture Keychain / cookie invalide
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(field: String?)
    case accountUnavailable                    // Keychain refusé, ItemTable vide…
}
```

```swift
// UsageKit — store MainActor (02 §6.1 : réglages injectés via SettingsStore)
@MainActor @Observable
public final class UsageStore {
    public private(set) var windows: [UsageWindowKind: UsageWindow] = [:]
    public private(set) var accounts: [UsageAccount] = []
    public private(set) var health: [AgentKind: FlowHealth] = [:]       // → DoctorStore
    public private(set) var refresh: RefreshState = .idle               // .idle / .refreshing(manual: Bool)
    public private(set) var daily: [DailyUsage] = []

    public func apply(_ snapshot: UsageSnapshot)          // maj fenêtres, isStale=false, alertes, rollover réarmé
    public func markFailure(_ agent: AgentKind, _ error: UsageError)
    public func requestManualRefresh(source: RefreshSource)  // .notchHeader / .menuBarPopover / .sessionRow
    public func rolloverIfNeeded(now: Date)
    public func gauge(for kind: UsageWindowKind) -> GaugeModel?   // dérivation pure, testable
}

public struct GaugeModel: Equatable, Sendable {
    public var kind: UsageWindowKind
    public var fillFraction: Double?        // nil ⇒ « -- » ; sinon consommé OU restant selon countdownFrom100
    public var percentText: String          // "33%", "67% left", "--"
    public var color: GaugeColor            // .green / .yellow / .red — TOUJOURS sur le consommé
    public var caption: String              // "Resets in 2h 14m" / "Refills Sun at 3:47 PM" / "$12.07 of $60.00" / "Resets Jul 31"
    public var isStale: Bool                // tooltip « Last updated Xm ago »
    public var isShimmering: Bool
    public var subBars: [UsageSubBar]       // Cursor : Auto/Composer, API (REQ-USG-13)
}
public enum GaugeColor: Sendable { case green, yellow, red }
```

Seuils et hystérésis (REQ-USG-15) :

```swift
func gaugeColor(consumed p: Double, previous: GaugeColor?) -> GaugeColor {
    // montée : <70 vert, <90 jaune, ≥90 rouge ; redescente : −2 points d'hystérésis
    let up: GaugeColor = p < 70 ? .green : (p < 90 ? .yellow : .red)
    guard let prev = previous, prev != up else { return up }
    switch (prev, up) {
    case (.yellow, .green): return p < 68 ? .green : .yellow
    case (.red, .yellow):   return p < 88 ? .yellow : .red
    default:                return up
    }
}
```

### 3.2 Pollers

```swift
// AgentClaude
actor ClaudeUsagePoller: UsageProvider {
    private var backoff = Backoff(base: 180, factor: 2, cap: 900)   // REQ-USG-20
    func fetchUsage(account: UsageAccount.ID) async throws -> UsageSnapshot {
        let token = try KeychainReader.claudeAccessToken()          // SecItemCopyMatching, à la demande
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/\(detectedCLIVersion)", forHTTPHeaderField: "User-Agent")  // sans lui : 429 [VÉRIFIÉ]
        // …URLSession, décodage tolérant (fenêtres null), mapping → UsageWindow…
    }
}

// AgentCursor — cookie construit à chaque requête, jamais stocké
actor CursorUsagePoller: UsageProvider {
    func fetchUsage(account: UsageAccount.ID) async throws -> UsageSnapshot {
        let jwt = try await stateReader.cursorAccessToken()          // ItemTable, RO
        let userId = try JWTClaims(jwt).sub.split(separator: "|").last.map(String.init) ?? { throw UsageError.decoding(field: "sub") }()
        let cookie = "WorkosCursorSessionToken=\(userId)%3A%3A\(jwt)"
        // GET /api/usage-summary (+ en-têtes anti-bot) → CursorUsageSummary
        // dérivation des 4 mesures + sous-barres ; cycle = billingCycleStart/End (ISO ou epoch-ms string)
    }
}
```

Dérivation de la mesure Cursor (REQ-USG-11/12, pure et testée sur fixtures) :

```swift
func cursorWindow(_ s: CursorUsageSummary, measure: CursorUsageMeasure) -> UsageWindow {
    switch measure {
    case .spend:    // $X of $Y ; isUnlimited → dollars sans limit, fillFraction nil
    case .weighted: // utilization = s.plan.totalPercentUsed   [HYPOTHÈSE cursor n°8]
    case .auto:     // utilization = s.plan.autoPercentUsed    [HYPOTHÈSE]
    case .api:      // utilization = s.plan.apiPercentUsed     [HYPOTHÈSE]
    }
    // resetsAt = billingCycleEnd ; champ attendu absent → UsageError.decoding → health notice (REQ-USG-33)
}
```

### 3.3 Flux poll → jauges (nominal + échec)

```
DispatchSourceTimer (180 s / 300 s, back-off)             refresh manuel (bouton, anti-rafale 10 s)
        │                                                          │ shimmer ON (min 600 ms)
        ▼                                                          ▼
actor ClaudeUsagePoller / CursorUsagePoller  ── fetchUsage() ── HTTPS
        │ succès                                    │ échec (réseau/401/429/decoding)
        ▼                                           ▼
 UsageSnapshot (fenêtres + raw)              UsageError
        │ hop MainActor                             │ hop MainActor
        ▼                                           ▼
 UsageStore.apply(snapshot)                  UsageStore.markFailure(agent, error)
   ├─ diff : publication seulement si ≠       ├─ fenêtres CONSERVÉES, isStale = true (REQ-USG-19)
   ├─ isStale = false, fetchedAt = now        ├─ failureStreak += 1 ; ≥ 3 → health .degraded
   ├─ BudgetAlertEvaluator.evaluate(...)      │        └─→ DoctorStore + badge health notice
   ├─ réarmement du timer de rollover         └─ 429 → back-off ×2 (cap 15 min)
   └─ GaugeModel recalculés → NotchUI / MenuBarUI / pill (shimmer OFF)
```

### 3.4 Rollover de fenêtre (REQ-USG-22/23)

```
armé à min(resetsAt) ── fire ──► rolloverIfNeeded(now)
   pour chaque fenêtre où now ≥ resetsAt :
     utilization affichée ← 0 (consommé) / 100 (restant en mode countdown)
     isStale ← true (valeur locale, non confirmée serveur)
     purge des dedupKey BUDGET_ALERT du cycle échu  → alertes réarmées
   poll immédiat ──► apply(snapshot) : nouvelle fenêtre + resets_at suivant → timer réarmé
NSWorkspace.didWakeNotification ─────► même chemin (timers gelés pendant le sommeil)
```

### 3.5 Alertes de budget (REQ-USG-38/39)

```swift
struct BudgetAlertEvaluator {
    /// Appelé à chaque apply() et à chaque changement de seuil dans Settings.
    func evaluate(window: UsageWindow, threshold: Int, previous: Double?,
                  alreadyFired: Set<String>) -> NotificationEvent? {
        guard window.kind == .fiveHour || window.kind == .sevenDay else { return nil }
        let key = "\(window.kind.rawValue)|\(threshold)|\(window.resetsAt?.ISO8601Format() ?? "?")"
        guard !alreadyFired.contains(key),
              window.utilization >= Double(threshold),
              (previous ?? 0) < Double(threshold) || previous == nil && window.utilization >= Double(threshold)
        else { return nil }
        return NotificationEvent(kind: .budgetAlert, sessionID: nil,
            title: window.kind == .fiveHour ? "5h usage at \(Int(window.utilization))%"
                                            : "Weekly usage at \(Int(window.utilization))%",
            body: "Threshold \(threshold)% reached. \(gaugeCaption(window))", dedupKey: key)
    }
}
```

### 3.6 Stats journalières (REQ-USG-24…28)

```swift
actor DailyUsageAggregator {
    // Alimentation : deltas du TranscriptIngestor {requestId, model, usage, timestamp, sessionID}
    // (déjà dédupliqués « dernière entrée gagne » ; un remplacement ré-émet l'ancien et le nouveau
    //  pour appliquer un delta = nouveau − ancien sur le jour concerné).
    private var contributions: [String: TokenTally]   // requestId → dernière contribution (fenêtre glissante 24 h)
    private var days: [String: DailyUsage]            // "YYYY-MM-DD|agent"
    func ingest(_ delta: UsageDelta) async
    func snapshotForUI() async -> [DailyUsage]        // publié coalescé (1 s max) vers UsageStore
    func rebuildFromScratch() async                   // bouton Doctor « Rebuild stats »
    // Persistance : daily-usage.json {schemaVersion, days, cursorLinesByDay, checkpoints{path, offset}}
}
```

Cursor : lecture des clés `aiCodeTracking.dailyStats.v1.5.*` à chaque tick lent du `CursorStateReader` (10 s) — coût négligeable, valeurs déjà agrégées par Cursor **[VÉRIFIÉ local]**.

### 3.7 Formatage (fonctions pures, testées)

```swift
enum UsageFormat {
    static func tokens(_ n: Int) -> String        // 0…999 → "66" ; 1 000…99 949 → "24.6k" ;
                                                  // 99 950…999 499 → "245k" ; ≥ 999 500 → "1.2M"
    static func resetsIn(_ until: TimeInterval) -> String   // "2h 14m" / "42m" / "<1m"
    static func refills(_ date: Date, clock24h: Bool) -> String  // "Sun at 3:47 PM" / "Sun at 15:47"
    static func dollars(_ cents: Int) -> String   // 1207 → "$12.07"
}
```

---

## 4. Spécification UX/UI

### 4.1 Section usage du panel (notch étendu)

- Header de section : titre « **Usage** », bouton refresh (`arrow.clockwise`, 16 pt) à droite ; bouton désactivé 10 s après un refresh manuel.
- Une ligne par jauge active, hauteur 28 pt (densité regular ; compact 24 pt, colossal 34 pt) :
  - label gauche : « **Claude · 5h** », « **Claude · 7d** », « **Cursor · Monthly** » (13 pt, opacité pilotée par `metricsOpacity`) ;
  - jauge batterie centrale : hauteur **12 pt**, coins arrondis 4 pt, ergot 2 × 6 pt à droite, remplissage animé (150 ms ease-out) depuis la gauche ;
  - texte droit : `percentText` + `caption` (11 pt, secondaire) — ex. « 33% · Resets in 2h 14m », « 13% · Refills Sun at 3:47 PM », « $12.07 of $60.00 · Resets Jul 31 ».
- Sous-barres Cursor (si activées) : hauteur 4 pt sous la jauge principale, labels « Auto » / « API » (10 pt).
- Badge health notice : icône ⚠ ambrée + texte « **Usage may be inaccurate — check Doctor** » sous la dernière jauge ; clic → Settings → Doctor.
- Jauge stale : opacité de la barre à 60 %, tooltip « Last updated 12m ago ».
- Jauge jamais alimentée : barre en contour seul, texte « **--** ».

### 4.2 Mode usage du pill

- Contenu : mini-jauges empilées horizontalement (hauteur 7 pt, largeur 22 pt chacune, espacement 6 pt) dans l'ordre Claude 5 h, Claude 7 j, Cursor mensuel ; mêmes couleurs/états que §4.1, sans texte (tooltip au survol).
- Largeur du pill **fixe** (Wide ou Ultra-wide) : aucune variation avec les valeurs ; « Auto width » grisé dans Appearance avec la légende « Unavailable in usage mode ».

### 4.3 Popover menu bar

Réutilise les mêmes `GaugeModel` en lignes plates (résumé) + le même bouton refresh ; aucun état spécifique — spécifié dans le document menu bar.

### 4.4 Vue « Daily usage » (détail)

- Accès : clic sur le header « Usage » du panel → vue détail (retour par chevron « Back »).
- Histogramme 14 jours (barres verticales, hauteur max 48 pt, couleur = agent), puis liste :
  - Claude : « **Mon 29 · 1.2M in / 48k out · ~$4.12** » ;
  - Cursor : « **Mon 29 · 320 lines accepted / 510 suggested** » (+ « · $1.90 » si REQ-USG-07 actif).
- État vide : « **No usage recorded yet** ».

### 4.5 Shimmer de refresh

Bande de surbrillance diagonale (gradient blanc 0 → 22 % → 0 d'opacité) balayant chaque jauge de gauche à droite en boucle de 1,1 s, pendant `refresh == .refreshing(manual: true)` ; minimum 600 ms ; respecte `agentGlass()` (pas de blend additif en mode Opaque).

### 4.6 Chip de tokens de session

- Sur la carte de session Claude : « **24.6k / 66** » (police monospaced digits 11 pt), séparateur « / », icônes ↑input ↓output implicites par position (tooltip « input / output tokens » ; tooltip enrichi REQ-USG-44).
- Pendant le tour : point pulsant 4 pt à gauche du chip (animation 1 s, en pause quand le notch est fermé — budget CPU).
- Sur la carte de session Cursor : « **ctx 72%** », teinté par les mêmes seuils de couleur que les jauges.
- Aucune animation de « compteur qui défile » : la valeur saute à chaque coalescence (≤ 300 ms) — sobriété et coût de rendu.

---

## 5. Cas limites & gestion d'erreurs

| # | Cas | Comportement |
|---|---|---|
| 1 | App lancée sans réseau | jauges `--` (jamais de valeur) ; premier poll réussi les peuple ; pas de health notice avant 3 échecs |
| 2 | Keychain Claude refusé | REQ-USG-21 : `--`, bouton retry, health `unavailable`, aucun re-prompt automatique en boucle |
| 3 | Token Claude expiré (401) | relecture Keychain + 1 retry ; 401 persistant → rétention + health notice (compte déconnecté ?) |
| 4 | 429 Anthropic (User-Agent manquant/rate limit) | back-off ×2 plafonné 15 min, rétention, health après 3 échecs |
| 5 | Fenêtre `null` (ex. `seven_day_opus`) | aucune jauge créée ; disparition d'une fenêtre existante → la jauge est retirée (pas de `--` orphelin) |
| 6 | `resets_at` dans le passé (horloge locale déréglée, cache serveur) | 1 occurrence : poll immédiat de confirmation ; 2 polls consécutifs → health notice, countdown remplacé par « Resets soon » |
| 7 | `utilization` > 100 ou < 0 | clamp [0, 100] (REQ-USG-17), log `.notice` |
| 8 | Cursor non installé / `state.vscdb` absent | flux Cursor `unavailable`, aucune jauge Cursor, aucune requête |
| 9 | `state.vscdb` verrouillée (`SQLITE_BUSY`) | retry du `CursorStateReader` ; échec persistant → rétention + health |
| 10 | JWT Cursor sans `|` dans `sub` / non décodable | `UsageError.decoding("sub")` → rétention + health notice ; fallback userId via `sentry/scope_v3.json` **[VÉRIFIÉ local]** en P1 |
| 11 | `usage-summary` : champs percents absents (plan free/enterprise, `limitType: team`) | mesure choisie indisponible → jauge `--` + health notice ; mesure Spend tentée en secours si `plan.used` présent **[HYPOTHÈSE cursor n°7]** |
| 12 | `isUnlimited` | REQ-USG-12 : texte sans barre ; alertes de budget non applicables |
| 13 | Changement de mesure Cursor sans snapshot retenu | jauge `--` jusqu'au prochain poll (déclenché immédiatement) |
| 14 | Rollover pendant le sommeil | `didWakeNotification` → `rolloverIfNeeded` + poll ; pas de notification budget fantôme (dedup purgée avant réévaluation) |
| 15 | Sursaut de tokens en un poll (ex. 40 % → 95 %) | franchissement de plusieurs seuils : une seule notification (le seuil configuré), couleur passe directement au rouge |
| 16 | Transcript JSONL corrompu / ligne > 64 Ko / type inconnu | parseur tolérant (architecture §9) : ligne ignorée, agrégats journaliers continuent ; compteur d'erreurs → Doctor |
| 17 | `requestId` re-émis après minuit (tour à cheval sur 2 jours) | contribution réaffectée au jour de la **dernière** entrée (delta appliqué : retrait ancien jour, ajout nouveau) |
| 18 | `daily-usage.json` corrompu ou schéma inconnu | fichier ignoré + reconstruction complète en arrière-plan ; bouton « Rebuild stats » toujours disponible |
| 19 | Deux comptes détectés pour un agent (futur) | picker REQ-USG-30 les liste ; sans sélection, le plus récemment actif (`fetchedAt`) est prioritaire **[TRANCHÉ produit]** |
| 20 | Refresh manuel pendant un poll périodique en vol | requête unique partagée (coalescence) ; le shimmer s'applique à la requête en cours |
| 21 | `pillUsageMode` activé alors que tous les toggles d'usage sont off | le pill retombe en mode statut normal + mention dans Settings (« Enable a usage source first ») |
| 22 | Toggle agent off pendant un shimmer | shimmer interrompu, jauges retirées, poller stoppé proprement (annulation de la `Task`) |
| 23 | Mode countdown + rollover | la jauge se remplit d'un coup à 100 % restant — animation 150 ms, pas de flash de couleur (couleur = consommé = vert) |
| 24 | Chip mid-turn : entrées `assistant` sans `usage` (erreurs API) | contribution ignorée, chip conserve la dernière valeur |
| 25 | Session `/clear` | le chip de l'ancienne row reste figé (row conservée, 02 §7) ; la nouvelle session démarre à 0 |

---

## 6. Critères d'acceptation

1. **Given** Claude Code connecté (Keychain accessible) et AgentDash lancé, **When** le premier poll aboutit, **Then** les jauges 5 h et 7 j affichent un pourcentage entier, « Resets in Xh Ym » et « Refills <EEE> at <heure> » cohérents avec `/usage` dans le CLI (±1 point, ±1 min).
2. **Given** le réglage horloge sur 24 h, **When** j'ouvre le panel, **Then** le refill 7 j s'affiche « Refills Sun at 15:47 » ; en 12 h, « Refills Sun at 3:47 PM ».
3. **Given** le Wi-Fi coupé après un premier poll réussi, **When** trois polls échouent, **Then** les jauges gardent leurs dernières valeurs (opacité réduite, tooltip « Last updated… »), le badge « Usage may be inaccurate — check Doctor » apparaît, et **aucune** jauge ne passe à `--`.
4. **Given** le Wi-Fi rétabli, **When** le poll suivant réussit, **Then** valeurs et opacité redeviennent normales et le badge disparaît (récupération sans redémarrage).
5. **Given** aucune valeur jamais obtenue (premier lancement hors ligne), **Then** chaque jauge affiche « -- » avec barre en contour.
6. **Given** une fenêtre 5 h dont `resets_at` est dans 2 minutes, **When** l'échéance passe (app ouverte ou après réveil du Mac), **Then** la jauge revient à 0 % (ou 100 % en mode countdown) puis se confirme au poll suivant, et une alerte budget peut se redéclencher dans le nouveau cycle.
7. **Given** `budgetThreshold5h = 50` et une utilisation qui passe de 45 % à 62 %, **Then** exactement une notification « 5h usage at 62% » est émise ; elle ne se répète pas aux polls suivants du même cycle.
8. **Given** la mesure Cursor sur Weighted, **When** je passe à Spend dans Settings → Usage, **Then** la jauge affiche « $X of $Y » **instantanément**, sans requête réseau (vérifiable via un proxy réseau).
9. **Given** `countdownFrom100` activé, **Then** toutes les jauges affichent le restant (« 67% left »), se vident, et conservent la couleur du consommé — bascule immédiate au toggle.
10. **Given** le mode usage du pill activé avec `pillWidthMode = auto`, **Then** le pill passe en largeur Wide fixe, montre les mini-jauges, et le picker Appearance grise « Auto width ».
11. **Given** le bouton refresh du header cliqué, **Then** un shimmer visible ≥ 600 ms parcourt les jauges, les valeurs se mettent à jour, et le bouton reste inactif 10 s.
12. **Given** une session Claude en plein tour (génération streaming), **Then** le chip « in / out » de sa carte augmente pendant le tour (mise à jour ≤ 300 ms, point pulsant), se fige au `Stop`, et son total dédupliqué correspond à ccusage sur le même transcript (± arrondi d'affichage).
13. **Given** une session Cursor active, **Then** sa carte affiche « ctx N% » et jamais un compteur de tokens par tour.
14. **Given** 7 jours d'activité Claude dans `~/.claude/projects`, **When** j'ouvre « Daily usage », **Then** les totaux input/output par jour correspondent au calcul ccusage (dédup `requestId`, caches inclus dans le total consommé) et le cache `daily-usage.json` évite un re-parse complet au relancement (lancement < 1 s).
15. **Given** l'invite Keychain refusée, **Then** seules les jauges Claude passent à `--` avec un bouton « Retry Keychain access » ; Cursor et le reste de l'app fonctionnent.
16. **Given** `claudeUsageEnabled` désactivé, **Then** plus aucune requête vers `api.anthropic.com` (vérifiable au proxy) et les jauges Claude disparaissent de toutes les surfaces.

---

## 7. Dépendances (autres fichiers du plan) et risques

### Dépendances

| Document | Ce qu'on en attend |
|---|---|
| `plan/01-architecture.md` | cadences de poll (180/300 s), anti-rafale 10 s, timers mutualisés + `didWakeNotification`, budgets perfs, santé par flux |
| `plan/02-data-model.md` | `UsageWindow`, `UsageAccount`, `DailyUsage`, `TokenTally`, `CursorUsageMeasure`, `NotificationEvent.dedupKey`, réglages `AppSettings` (§6.1) |
| Document sessions/ingestion (transcripts) | deltas dédupliqués `requestId` du `TranscriptIngestor` (alimentent le chip mid-turn **et** l'agrégateur journalier), `ContextUsage` Cursor |
| Document notch UI | emplacement de la section usage, header + bouton refresh, pill (mode usage), densités/largeurs |
| Document menu bar | réutilisation des `GaugeModel` + bouton refresh du popover |
| Document notifications | canal `UNUserNotificationCenter`, toggle maître/son, routage de `BUDGET_ALERT` |
| Document Doctor | affichage des états de santé usage, bouton « Rebuild stats », check Keychain/compte |
| Document Settings | onglet Usage (toggles, picker de compte, mesure Cursor, sous-barres, countdown, daily stats) |

### Risques

1. **Endpoints non officiels** (`/api/oauth/usage`, `usage-summary`, `get-aggregated-usage-events`) : schéma susceptible de changer sans préavis → décodage tolérant, health notice systématique, bancs de fixtures versionnées, dégradation en `--` jamais en crash. *(Risque majeur, mitigé mais non éliminable.)*
2. **Mapping Spend/Weighted/Auto/API** non confirmé (hypothèse cursor n°8) : à valider sur de vraies réponses (plans pro/enterprise) **avant** de figer les libellés ; prévoir un remapping par simple table.
3. **Label de compte Claude** (hypothèse claude-code n°5) : si le JSON OAuth n'expose ni email ni organisation, retomber sur « Claude account » — dégrade la feature « label de compte » sans la bloquer.
4. **Plans enterprise/team Cursor** (`limitType: team`, `isUnlimited`) : champs individuels possiblement absents — la machine de dev est justement « enterprise », bon banc de test.
5. **429 Anthropic** si un autre outil (ccusage monitor, etc.) partage le même token : back-off + rétention suffisent, mais la fraîcheur peut se dégrader → tooltip d'horodatage indispensable.
6. **Volume des transcripts** pour l'agrégation initiale : si > 1 s sur de gros historiques, activer le snapshot d'offsets (02 §8) — mécanisme déjà prévu.

---

## 8. Découpage en tâches

| # | Tâche | Contenu | Taille |
|---|---|---|---|
| U1 | Types + `UsageStore` | `UsageProvider`, `UsageSnapshot`, `RawUsagePayload`, `UsageError`, store, `gauge(for:)`, tests de dérivation | **M** |
| U2 | `ClaudeUsagePoller` | Keychain, requête `/api/oauth/usage`, décodage tolérant, 401/429/back-off, tests sur fixtures | **M** |
| U3 | `CursorUsagePoller` | token `ItemTable`, JWT → cookie, `usage-summary`, dérivation des 4 mesures + sous-barres, « $X of $Y », tests fixtures multi-plans | **L** |
| U4 | Jauges batterie SwiftUI | composant `BatteryGauge` (couleurs, hystérésis, stale, `--`, animation), mode countdown, sous-barres | **M** |
| U5 | Countdowns & formatage | `UsageFormat` (resets in / refills / dollars / tokens abrégés), tick partagé 1 s, 12/24 h — tests unitaires exhaustifs | **S** |
| U6 | Rollover & réveil | timer à date exacte, `rolloverIfNeeded`, purge des dedup, `didWakeNotification` | **S** |
| U7 | Refresh manuel + shimmer | coalescence des requêtes, anti-rafale 10 s, composant shimmer, branchement header/popover/row | **M** |
| U8 | Alertes de budget | `BudgetAlertEvaluator`, dedup par cycle, réévaluation au changement de seuil, tests de franchissement | **M** |
| U9 | Stats journalières | `DailyUsageAggregator`, cache `daily-usage.json`, table de prix, `dailyStats.v1.5.*` Cursor, « Rebuild stats », vue « Daily usage » | **L** |
| U10 | Chip de tokens mid-turn | branchement des deltas `TranscriptIngestor` → `TokenTally` (coalescence 300 ms), chip UI + variante « ctx N% » Cursor | **M** |
| U11 | Mode usage du pill | mini-jauges, verrouillage de largeur, interactions avec Appearance | **M** |
| U12 | Comptes & health | `discoverAccounts()`, picker Settings, health par flux → `DoctorStore`, badge notice, bouton retry Keychain | **M** |
| U13 | Banc d'hypothèses | scripts `scripts/experiments/` : réponse réelle `usage-summary` (mapping n°8), label de compte OAuth (n°5 claude), 401/refresh Keychain | **S** |

Ordre recommandé : U1 → U2/U3 (parallèles, U13 en amont de U3) → U4/U5 → U6/U7/U8 → U10 → U11 → U9 → U12 en continu (le health s'enrichit à chaque brique).
