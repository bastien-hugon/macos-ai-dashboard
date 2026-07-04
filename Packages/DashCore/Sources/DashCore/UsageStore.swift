import Foundation
import Observation

public enum RefreshState: Equatable, Sendable {
    case idle
    case refreshing(manual: Bool)
}

/// Évaluateur d'alertes de budget (09 · REQ-USG-38/39) — logique pure, câblage système en M5.
/// Émet au plus une alerte par (fenêtre, seuil, cycle) ; le rollover réarme.
public struct BudgetAlertEvaluator: Sendable {
    private var fired: Set<String> = []

    public init() {}

    public struct Alert: Equatable, Sendable {
        public let kind: UsageWindowKind
        public let threshold: Int
        public let utilization: Double
    }

    /// Retourne une alerte si `utilization` franchit `threshold` pour un cycle jamais notifié.
    public mutating func evaluate(kind: UsageWindowKind, utilization: Double, threshold: Int, resetsAt: Date?) -> Alert? {
        guard utilization >= Double(threshold) else { return nil }
        let cycle = resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset"
        let key = "\(kind.rawValue)|\(threshold)|\(cycle)"
        guard !fired.contains(key) else { return nil }
        fired.insert(key)
        return Alert(kind: kind, threshold: threshold, utilization: utilization)
    }

    /// Réarme les alertes d'une fenêtre au rollover (nouveau `resetsAt`).
    public mutating func rearm(kind: UsageWindowKind) {
        fired = fired.filter { !$0.hasPrefix("\(kind.rawValue)|") }
    }
}

/// Store d'usage — source de vérité UI (09 · §3.1). Mutations sur MainActor ; les jauges
/// sont dérivées à la demande (pures, testables). Réglages injectés via SettingsStore.
@MainActor @Observable
public final class UsageStore {
    public private(set) var windows: [UsageWindowKind: UsageWindow] = [:]
    public private(set) var accounts: [UsageAccount] = []
    public private(set) var health: [AgentKind: FlowHealth] = [:]
    public private(set) var refresh: RefreshState = .idle
    public private(set) var daily: [DailyUsage] = []

    /// Couleur courante par fenêtre, recalculée avec hystérésis UNIQUEMENT quand les données
    /// changent (apply/rollover). `gauge(for:)` la lit sans jamais muter — sinon SwiftUI
    /// boucle (mutation d'état observable pendant le rendu).
    private var colors: [UsageWindowKind: GaugeColor] = [:]
    private var consecutiveFailures: [AgentKind: Int] = [:]
    private var budget = BudgetAlertEvaluator()

    /// Injecté par la composition root : réglages courants (seuils, countdownFrom100, clock24h).
    public var settingsProvider: (@MainActor () -> UsageSettings)?
    /// Émis quand une alerte de budget se déclenche (câblage notifications en M5).
    public var onBudgetAlert: (@MainActor (BudgetAlertEvaluator.Alert) -> Void)?

    public struct UsageSettings: Sendable {
        public var countdownFrom100: Bool
        public var clock24h: Bool
        public var threshold5h: Int
        public var threshold7d: Int
        public init(countdownFrom100: Bool, clock24h: Bool, threshold5h: Int, threshold7d: Int) {
            self.countdownFrom100 = countdownFrom100
            self.clock24h = clock24h
            self.threshold5h = threshold5h
            self.threshold7d = threshold7d
        }
    }

    public init() {}

    // MARK: - Ingestion

    public func apply(_ snapshot: UsageSnapshot) {
        for window in snapshot.windows {
            windows[window.kind] = window
            // Hystérésis calculée ici (données fraîches), pas pendant le rendu.
            colors[window.kind] = gaugeColor(consumed: min(100, max(0, window.utilization)),
                                             previous: colors[window.kind])
            evaluateBudget(for: window)
        }
        health[snapshot.agent] = .healthy
        consecutiveFailures[snapshot.agent] = 0
        if case .refreshing = refresh { refresh = .idle }
    }

    public func setAccounts(_ accounts: [UsageAccount]) {
        self.accounts = accounts
    }

    /// Ajoute des comptes sans écraser ceux d'un autre agent (multi-agents).
    public func addAccounts(_ new: [UsageAccount]) {
        let agents = Set(new.map(\.agent))
        accounts = accounts.filter { !agents.contains($0.agent) } + new
    }

    public func markFailure(_ agent: AgentKind, _ error: UsageError) {
        // Rétention : on marque stale les fenêtres existantes, jamais d'effacement (REQ-USG-19).
        for (kind, var window) in windows where windowAgent(kind) == agent {
            window.isStale = true
            windows[kind] = window
        }
        let count = (consecutiveFailures[agent] ?? 0) + 1
        consecutiveFailures[agent] = count
        health[agent] = count >= 3 ? .degraded(reason: describe(error)) : (health[agent] ?? .healthy)
        if case .refreshing = refresh { refresh = .idle }
    }

    public func setDaily(_ daily: [DailyUsage]) {
        self.daily = daily
    }

    public func beginManualRefresh() {
        refresh = .refreshing(manual: true)
    }

    // MARK: - Rollover (REQ-USG-22)

    public func rolloverIfNeeded(now: Date) {
        for (kind, var window) in windows {
            if let resetsAt = window.resetsAt, resetsAt <= now {
                window.utilization = 0
                window.resetsAt = nil
                windows[kind] = window
                colors[kind] = .green
                budget.rearm(kind: kind)
            }
        }
    }

    /// Prochaine échéance de rollover (pour armer le timer à date exacte).
    public var nextRollover: Date? {
        windows.values.compactMap(\.resetsAt).min()
    }

    // MARK: - Dérivation des jauges (pure)

    public func gauge(for kind: UsageWindowKind) -> GaugeModel? {
        let settings = settingsProvider?() ?? UsageSettings(countdownFrom100: false, clock24h: true, threshold5h: 80, threshold7d: 80)
        guard let window = windows[kind] else {
            // Jamais de valeur → « -- » (REQ-USG-18).
            return GaugeModel(kind: kind, fillFraction: nil, percentText: "--", color: .green,
                              caption: "", isStale: false, isShimmering: false)
        }
        let consumed = min(100, max(0, window.utilization))
        // Lecture pure : la couleur a été calculée dans apply()/rollover (jamais ici).
        let color = colors[kind] ?? gaugeColor(consumed: consumed, previous: nil)
        let fill = settings.countdownFrom100 ? (100 - consumed) / 100 : consumed / 100
        let caption: String = switch kind {
        case .fiveHour: UsageFormat.resetCountdown(from: Date(), to: window.resetsAt)
        case .sevenDay, .sevenDayOpus, .sevenDaySonnet: UsageFormat.refillCaption(window.resetsAt, clock24h: settings.clock24h)
        case .monthly: monthlyCaption(window)
        }
        let shimmering = refresh == .refreshing(manual: true)
        return GaugeModel(
            kind: kind, fillFraction: fill,
            percentText: UsageFormat.percentText(consumed: consumed, countdownFrom100: settings.countdownFrom100),
            color: color, caption: caption, isStale: window.isStale, isShimmering: shimmering
        )
    }

    /// Jauges du résumé Claude (5 h + 7 j) présentes, dans l'ordre.
    public var claudeSummaryGauges: [GaugeModel] {
        UsageWindowKind.summaryClaude.compactMap { windows[$0] != nil ? gauge(for: $0) : nil }
    }

    public var hasAnyClaudeWindow: Bool {
        windows[.fiveHour] != nil || windows[.sevenDay] != nil
    }

    /// Une jauge (Claude ou Cursor) est-elle disponible (visibilité de la section) ?
    public var hasAnyWindow: Bool { !windows.isEmpty }

    // MARK: -

    private func evaluateBudget(for window: UsageWindow) {
        let settings = settingsProvider?() ?? UsageSettings(countdownFrom100: false, clock24h: true, threshold5h: 80, threshold7d: 80)
        let threshold: Int? = switch window.kind {
        case .fiveHour: settings.threshold5h
        case .sevenDay: settings.threshold7d
        default: nil
        }
        guard let threshold else { return }
        if let alert = budget.evaluate(kind: window.kind, utilization: window.utilization, threshold: threshold, resetsAt: window.resetsAt) {
            onBudgetAlert?(alert)
        }
    }

    private func windowAgent(_ kind: UsageWindowKind) -> AgentKind {
        kind == .monthly ? .cursor : .claude
    }

    private func describe(_ error: UsageError) -> String {
        switch error {
        case .network(let m): "network: \(m)"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate limited"
        case .decoding(let f): "decoding\(f.map { " (\($0))" } ?? "")"
        case .accountUnavailable: "account unavailable"
        }
    }

    private func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Légende Cursor mensuel (09 · REQ-USG-10/12) : « $X of $Y » ou « $X spent · Unlimited »,
    /// complétée de la date de reset.
    private func monthlyCaption(_ window: UsageWindow) -> String {
        let reset = window.resetsAt.map { " · Resets \(monthDay($0))" } ?? ""
        guard let dollars = window.dollars else {
            return window.resetsAt.map { "Resets \(monthDay($0))" } ?? ""
        }
        if dollars.limit.isInfinite || dollars.limit <= 0 {
            return String(format: "$%.2f spent · Unlimited", dollars.used)
        }
        return String(format: "$%.2f of $%.2f", dollars.used, dollars.limit) + reset
    }

    /// La fenêtre mensuelle Cursor est-elle disponible (pour l'affichage) ?
    public var hasCursorMonthly: Bool { windows[.monthly] != nil }
}
