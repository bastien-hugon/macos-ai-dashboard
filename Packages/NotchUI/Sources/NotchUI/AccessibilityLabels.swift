import DashCore
import Foundation

/// Construction des labels VoiceOver (REQ-NUI-57) — logique pure et testable.
public enum AccessibilityLabels {
    /// Label agrégé du pill : « AgentDash. 2 sessions running, 1 waiting for permission ».
    public static func pill(sessions: [Session], hasPrompt: Bool) -> String {
        let running = sessions.filter { $0.state == .executing || $0.state == .thinking }.count
        let waiting = sessions.filter { $0.state == .waiting }.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) session\(running > 1 ? "s" : "") running") }
        if waiting > 0 { parts.append("\(waiting) waiting for input") }
        if parts.isEmpty {
            let live = sessions.filter { $0.liveness.isLive }.count
            parts.append(live > 0 ? "\(live) idle session\(live > 1 ? "s" : "")" : "no active sessions")
        }
        return "AgentDash. " + parts.joined(separator: ", ") + ". Double-tap to expand."
    }

    /// Label d'une carte de session : agent, titre, état, activité.
    public static func sessionCard(_ session: Session) -> String {
        var parts = ["\(session.id.agent.displayName): \(session.displayTitle)"]
        parts.append(stateWord(session.state))
        if let activity = session.lastActivity { parts.append(activity) }
        if !session.tokens.isEmpty {
            parts.append("\(DashFormat.tokens(session.tokens.inputTokens)) input, \(DashFormat.tokens(session.tokens.outputTokens)) output tokens")
        }
        return parts.joined(separator: ", ")
    }

    /// Valeur d'une jauge d'usage : « 57 percent used, resets in 2h 14m ».
    public static func gauge(title: String, percentText: String, caption: String) -> String {
        var s = "\(title): \(percentText)"
        if !caption.isEmpty { s += ", \(caption)" }
        return s
    }

    /// Annonce à l'apparition d'un prompt (posted comme .announcement).
    public static func promptAnnouncement(_ prompt: PendingPrompt) -> String {
        switch prompt.payload {
        case .permission(let r): "\(prompt.sessionLabel) needs permission: \(r.displayTitle)"
        case .plan(let p): "\(prompt.sessionLabel) proposed a plan: \(p.title)"
        case .question: "\(prompt.sessionLabel) is asking a question"
        }
    }

    private static func stateWord(_ state: SessionState) -> String {
        switch state {
        case .executing: "running"
        case .thinking: "thinking"
        case .waiting: "waiting for input"
        case .idle: "idle"
        case .ended: "ended"
        }
    }
}
