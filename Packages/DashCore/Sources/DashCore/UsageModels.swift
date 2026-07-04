import Foundation

/// Compte d'usage détecté (Claude Keychain / Cursor JWT) — 02 · §5.
public struct UsageAccount: Identifiable, Hashable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let label: String
    public let plan: String?

    public init(id: String, agent: AgentKind, label: String, plan: String? = nil) {
        self.id = id
        self.agent = agent
        self.label = label
        self.plan = plan
    }
}

/// Une fenêtre d'usage (02 · §5). `fetchedAt` = horodatage de la DERNIÈRE valeur obtenue,
/// conservé sur échec (rétention, REQ-USG-19).
public struct UsageWindow: Sendable, Equatable {
    public var kind: UsageWindowKind
    public var utilization: Double      // 0–100, consommé
    public var resetsAt: Date?
    public var fetchedAt: Date
    public var isStale: Bool
    public var dollars: Dollars?

    public struct Dollars: Sendable, Equatable {
        public var used: Double
        public var limit: Double
        public init(used: Double, limit: Double) { self.used = used; self.limit = limit }
    }

    public init(kind: UsageWindowKind, utilization: Double, resetsAt: Date?, fetchedAt: Date, isStale: Bool = false, dollars: Dollars? = nil) {
        self.kind = kind
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.dollars = dollars
    }
}

/// Instantané d'un poll réussi (09 · §3.1).
public struct UsageSnapshot: Sendable {
    public var agent: AgentKind
    public var account: String
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public init(agent: AgentKind, account: String, windows: [UsageWindow], fetchedAt: Date) {
        self.agent = agent
        self.account = account
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

/// Stats journalières (02 · §5, feature AgentPeek v0.2.6).
public struct DailyUsage: Identifiable, Sendable, Equatable, Codable {
    public var id: String              // "YYYY-MM-DD|agent"
    public var date: Date
    public var agent: AgentKind
    public var tokens: TokenTally
    public var costUSD: Double?
    public var sessionCount: Int

    public init(id: String, date: Date, agent: AgentKind, tokens: TokenTally, costUSD: Double? = nil, sessionCount: Int = 0) {
        self.id = id
        self.date = date
        self.agent = agent
        self.tokens = tokens
        self.costUSD = costUSD
        self.sessionCount = sessionCount
    }
}

/// Santé d'un flux (architecture §7.2) → DoctorStore.
public enum FlowHealth: Equatable, Sendable {
    case healthy
    case degraded(reason: String)
    case unavailable
}

/// Modèle de rendu d'une jauge (dérivation pure et testable, 09 · §3.1).
public struct GaugeModel: Equatable, Sendable {
    public var kind: UsageWindowKind
    public var fillFraction: Double?   // nil ⇒ « -- »
    public var percentText: String
    public var color: GaugeColor
    public var caption: String
    public var isStale: Bool
    public var isShimmering: Bool

    public init(kind: UsageWindowKind, fillFraction: Double?, percentText: String, color: GaugeColor, caption: String, isStale: Bool, isShimmering: Bool) {
        self.kind = kind
        self.fillFraction = fillFraction
        self.percentText = percentText
        self.color = color
        self.caption = caption
        self.isStale = isStale
        self.isShimmering = isShimmering
    }
}

public enum GaugeColor: Sendable, Equatable { case green, yellow, red }

/// Couleur de jauge par seuils exacts sur le consommé, avec hystérésis (REQ-USG-15).
public func gaugeColor(consumed p: Double, previous: GaugeColor?) -> GaugeColor {
    let up: GaugeColor = p < 70 ? .green : (p < 90 ? .yellow : .red)
    guard let prev = previous, prev != up else { return up }
    switch (prev, up) {
    case (.yellow, .green): return p < 68 ? .green : .yellow
    case (.red, .yellow): return p < 88 ? .yellow : .red
    default: return up
    }
}

/// Formats des countdowns et légendes de jauge (REQ-USG-08/09).
public enum UsageFormat {
    /// « Resets in 2h 14m » / « Xm » / « <1m ».
    public static func resetCountdown(from now: Date, to resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        if seconds <= 0 { return "Resetting…" }
        if seconds < 60 { return "Resets in <1m" }
        if seconds < 3600 { return "Resets in \(seconds / 60)m" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return "Resets in \(h)h \(m)m"
    }

    /// « Refills Sun at 3:47 PM » (12/24 h selon le réglage).
    public static func refillCaption(_ resetsAt: Date?, clock24h: Bool) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = clock24h ? "EEE 'at' HH:mm" : "EEE 'at' h:mm a"
        return "Refills \(formatter.string(from: resetsAt))"
    }

    /// Texte de pourcentage : « 33% » ou « 67% left » (countdownFrom100).
    public static func percentText(consumed: Double, countdownFrom100: Bool) -> String {
        let consumed = min(100, max(0, consumed))
        if countdownFrom100 {
            return "\(Int((100 - consumed).rounded()))% left"
        }
        return "\(Int(consumed.rounded()))%"
    }

    /// Dollars compacts pour la ligne inline : « $12.40 », « $135 » (≥ $100 sans décimales).
    public static func dollars(_ amount: Double) -> String {
        amount >= 100 ? String(format: "$%.0f", amount) : String(format: "$%.2f", amount)
    }
}
