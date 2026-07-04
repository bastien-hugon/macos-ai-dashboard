import DashCore
import Foundation
import UserNotifications

/// Câblage système des notifications (12) : autorisation, catégories avec actions
/// (Allow/Deny sur PERMISSION_REQUEST), post/retrait, réception des actions → PromptStore.
@MainActor
final class NotificationsController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let settings: SettingsStore
    private let prompts: PromptStore
    private let clock: any ClockProvider
    private var composer = NotificationComposer()

    init(settings: SettingsStore, prompts: PromptStore, clock: any ClockProvider = SystemClock()) {
        self.settings = settings
        self.prompts = prompts
        self.clock = clock
        super.init()
        center.delegate = self
        registerCategories()
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func registerCategories() {
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        let permission = UNNotificationCategory(identifier: "PERMISSION_REQUEST",
                                                actions: [allow, deny], intentIdentifiers: [])
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [])
        let reject = UNNotificationAction(identifier: "REJECT", title: "Reject", options: [.destructive])
        let plan = UNNotificationCategory(identifier: "PLAN_REVIEW",
                                          actions: [approve, reject], intentIdentifiers: [])
        let budget = UNNotificationCategory(identifier: "BUDGET_ALERT", actions: [], intentIdentifiers: [])
        center.setNotificationCategories([permission, plan, budget])
    }

    // MARK: - Post

    func post(_ content: NotificationContent) {
        guard settings.notificationsMasterEnabled else { return }
        guard typeEnabled(content.kind) else { return }
        let un = UNMutableNotificationContent()
        un.title = content.title
        if let subtitle = content.subtitle { un.subtitle = subtitle }
        un.body = content.body
        un.threadIdentifier = content.threadIdentifier
        if let category = content.categoryIdentifier { un.categoryIdentifier = category }
        if settings.notificationSoundEnabled { un.sound = .default }
        // userInfo pour router les actions.
        un.userInfo = ["kind": content.kind.rawValue, "session": content.identifier]
        let request = UNNotificationRequest(identifier: content.identifier, content: un, trigger: nil)
        center.add(request)
    }

    /// Retrait actif d'une notification livrée (REQ-NOT-20).
    func withdraw(identifier: String) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func sendTest() {
        post(composer.test())
    }

    // MARK: - Événements produit → notifications

    func onPromptArrived(session: SessionID, projectName: String, toolTitle: String) {
        if let content = composer.permissionRequest(session: session, projectName: projectName,
                                                     toolTitle: toolTitle, nowMonotonic: clock.monotonicSeconds) {
            post(content)
        }
    }

    func onPromptResolved(session: SessionID) {
        withdraw(identifier: "perm|\(session.nativeID)")
    }

    func onBudgetAlert(_ alert: BudgetAlertEvaluator.Alert, resetsAt: Date?) {
        if let content = composer.budgetAlert(kind: alert.kind, threshold: alert.threshold,
                                              utilization: alert.utilization, resetsAt: resetsAt) {
            post(content)
        }
    }

    func onTaskComplete(session: SessionID, projectName: String) {
        post(composer.taskComplete(session: session, projectName: projectName))
    }

    func onStuckSession(session: SessionID, projectName: String, seconds: Int) {
        post(composer.stuckSession(session: session, projectName: projectName, seconds: seconds))
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            self.handleAction(action, forNotification: identifier)
        }
    }

    private func handleAction(_ action: String, forNotification identifier: String) {
        // identifier « perm|<sessionRawID> » → retrouver le prompt de cette session.
        guard identifier.hasPrefix("perm|") else { return }
        let rawID = String(identifier.dropFirst("perm|".count))
        guard let prompt = prompts.prompts.first(where: { $0.sessionID.nativeID == rawID }) else {
            return // déjà résolu/expiré → no-op (REQ-NOT-19)
        }
        switch action {
        case "ALLOW", "APPROVE":
            let decision: PromptDecision = if case .plan = prompt.payload {
                .approvePlan(switchToAcceptEdits: false)
            } else { .allow }
            prompts.decide(prompt.id, decision, via: .notification)
        case "DENY", "REJECT":
            let decision: PromptDecision = if case .plan = prompt.payload {
                .rejectPlan(feedback: "")
            } else { .deny(feedback: nil) }
            prompts.decide(prompt.id, decision, via: .notification)
        default:
            break // clic sur le corps : ouverture de la surface (géré ailleurs)
        }
    }

    private func typeEnabled(_ kind: NotificationKind) -> Bool {
        switch kind {
        case .permissionRequest: settings.notifyPermission
        case .budgetAlert: settings.notifyBudget
        case .stuckSession: settings.notifyStuck
        case .taskComplete: settings.notifyTaskComplete
        case .test: true
        }
    }
}
