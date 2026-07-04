import Foundation

/// Catalogue FERMÉ des notifications (12 · REQ-NOT-07) : exactement cinq types.
public enum NotificationKind: String, Sendable {
    case permissionRequest
    case budgetAlert
    case stuckSession
    case taskComplete
    case test
}

/// Contenu d'une notification (12 · §4.2) — titres/corps en anglais.
public struct NotificationContent: Sendable {
    public var kind: NotificationKind
    public var identifier: String       // stable → re-post remplace (REQ-NOT-27)
    public var threadIdentifier: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var categoryIdentifier: String?

    public init(kind: NotificationKind, identifier: String, threadIdentifier: String,
                title: String, subtitle: String? = nil, body: String, categoryIdentifier: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.categoryIdentifier = categoryIdentifier
    }
}

/// Construit le contenu et applique dédup/throttle (12 · §3, logique pure et testable).
/// Le câblage `UNUserNotificationCenter` vit dans l'app ; cette struct ne dépend de rien.
public struct NotificationComposer: Sendable {
    private var firedBudgetKeys: Set<String> = []
    private var lastPermissionPost: [String: TimeInterval] = [:] // sessionRawID → monotone

    public init() {}

    /// Permission demandée : ≤ 1 post / session / 10 s (REQ-NOT-29).
    public mutating func permissionRequest(session: SessionID, projectName: String,
                                           toolTitle: String, nowMonotonic: TimeInterval) -> NotificationContent? {
        let last = lastPermissionPost[session.nativeID] ?? -.infinity
        guard nowMonotonic - last >= 10 else { return nil }
        lastPermissionPost[session.nativeID] = nowMonotonic
        return NotificationContent(
            kind: .permissionRequest,
            identifier: "perm|\(session.nativeID)",
            threadIdentifier: "\(session.agent.rawValue)|\(session.nativeID)",
            title: "\(session.agent.displayName) needs permission",
            subtitle: projectName,
            body: toolTitle,
            categoryIdentifier: "PERMISSION_REQUEST"
        )
    }

    /// Alerte budget : au plus une par (fenêtre, seuil, cycle) — REQ-NOT-28.
    public mutating func budgetAlert(kind: UsageWindowKind, threshold: Int, utilization: Double,
                                     resetsAt: Date?) -> NotificationContent? {
        let cycle = resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "no-reset"
        let key = "\(kind.rawValue)|\(threshold)|\(cycle)"
        guard !firedBudgetKeys.contains(key) else { return nil }
        firedBudgetKeys.insert(key)
        let windowName = kind == .fiveHour ? "5-hour" : (kind == .sevenDay ? "7-day" : "monthly")
        return NotificationContent(
            kind: .budgetAlert,
            identifier: "budget|\(key)",
            threadIdentifier: "budget",
            title: "Usage at \(Int(utilization))%",
            body: "You've used \(Int(utilization))% of your \(windowName) limit.",
            categoryIdentifier: "BUDGET_ALERT"
        )
    }

    public mutating func rearmBudget(kind: UsageWindowKind) {
        firedBudgetKeys = firedBudgetKeys.filter { !$0.hasPrefix("\(kind.rawValue)|") }
    }

    public func stuckSession(session: SessionID, projectName: String, seconds: Int) -> NotificationContent {
        NotificationContent(
            kind: .stuckSession,
            identifier: "stuck|\(session.nativeID)",
            threadIdentifier: "\(session.agent.rawValue)|\(session.nativeID)",
            title: "\(session.agent.displayName) may be stuck",
            subtitle: projectName,
            body: "No activity for over \(seconds / 60) min."
        )
    }

    public func taskComplete(session: SessionID, projectName: String) -> NotificationContent {
        NotificationContent(
            kind: .taskComplete,
            identifier: "done|\(session.nativeID)",
            threadIdentifier: "\(session.agent.rawValue)|\(session.nativeID)",
            title: "\(session.agent.displayName) finished",
            subtitle: projectName,
            body: "The current turn is complete."
        )
    }

    public func test() -> NotificationContent {
        NotificationContent(
            kind: .test,
            identifier: "test",
            threadIdentifier: "test",
            title: "AgentDash",
            body: "Notifications are working."
        )
    }
}
