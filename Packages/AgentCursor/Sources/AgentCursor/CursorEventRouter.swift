import DashCore
import Foundation

/// Traduit les événements de hook Cursor (research cursor §1) en prompts actionnables.
/// Cursor supporte les permissions (`beforeShellExecution`/`beforeMCPExecution`) ; les
/// questions et plans sont détectés mais NON actionnables (aligné AgentPeek : ⌥A et
/// réponses réservés à Claude Code) — 08 · REQ-ACT-23.
public enum CursorEventRouter {
    public enum Routing: Sendable {
        case decision(PendingPrompt)
        case telemetry(sessionID: SessionID, isStop: Bool)
        case ignore
    }

    public static func route(_ envelope: HookEnvelope, now: Date) -> Routing {
        guard let event = try? JSONSerialization.jsonObject(with: Data(envelope.eventJSON.utf8)) as? [String: Any] else {
            return .ignore
        }
        let eventName = event["hook_event_name"] as? String ?? ""
        let conversationID = event["conversation_id"] as? String ?? event["generation_id"] as? String ?? ""
        guard !conversationID.isEmpty else { return .ignore }
        let sessionID = SessionID(agent: .cursor, nativeID: conversationID)
        let cwd = (event["workspace_roots"] as? [String])?.first ?? event["cwd"] as? String ?? ""

        switch eventName {
        case "beforeShellExecution":
            let command = event["command"] as? String
            var honest: [String] = []
            var opaque: String?
            if let command {
                switch HonestCommandAnalyzer.analyze(command) {
                case .effects(let e): honest = e
                case .opaque(let reason): opaque = reason
                }
            }
            let request = PermissionRequest(
                toolName: "Shell", displayTitle: command ?? "Run a command",
                commandText: command, suggestions: [], cwd: cwd,
                honestEffects: honest, effectsOpaqueReason: opaque
            )
            return decisionPrompt(request: request, sessionID: sessionID, cwd: cwd, envelope: envelope, now: now)

        case "beforeMCPExecution":
            let tool = event["tool_name"] as? String ?? "MCP tool"
            let request = PermissionRequest(toolName: tool, displayTitle: "Run \(tool)", cwd: cwd)
            return decisionPrompt(request: request, sessionID: sessionID, cwd: cwd, envelope: envelope, now: now)

        case "stop":
            return .telemetry(sessionID: sessionID, isStop: true)
        default:
            return .telemetry(sessionID: sessionID, isStop: false)
        }
    }

    private static func decisionPrompt(request: PermissionRequest, sessionID: SessionID,
                                       cwd: String, envelope: HookEnvelope, now: Date) -> Routing {
        let capabilities = PromptCapabilities(
            canAlwaysAllow: false,       // Cursor : pas d'always-allow (limite plateforme)
            canDenyWithFeedback: true,
            canAnswerInline: false,
            canApprovePlan: false,
            canHandInToTerminal: true
        )
        let prompt = PendingPrompt(
            sessionID: sessionID, receivedAt: now,
            expiresAt: now.addingTimeInterval(IPCProtocol.hookDecisionDeadlineSeconds - 10),
            payload: .permission(request), capabilities: capabilities,
            sessionLabel: cwd.isEmpty ? "Cursor" : (cwd as NSString).lastPathComponent,
            termProgram: envelope.termProgram, ppid: envelope.ppid
        )
        return .decision(prompt)
    }
}
