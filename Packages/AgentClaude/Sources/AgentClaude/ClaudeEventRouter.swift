import DashCore
import Foundation

/// Traduit les événements de hook Claude Code (enveloppe IPC) en actions sur les stores
/// (03 · REQ-CLA-13, 40..46 ; 08 · §2). Classification décision/télémétrie ; les décisions
/// gardent leur connexion ouverte jusqu'à la réponse de l'utilisateur.
public enum ClaudeEventRouter {
    /// Résultat de classification d'un événement.
    public enum Routing: Sendable {
        /// Prompt actionnable à enfiler ; l'appelant garde `request.reply` pour la décision.
        case decision(PendingPrompt)
        /// Événement de télémétrie : à corroborer dans les stores ; réponse vide immédiate.
        case telemetry(ClaudeTelemetry)
        /// Ni l'un ni l'autre : réponse vide immédiate.
        case ignore
    }

    public struct ClaudeTelemetry: Sendable {
        public var sessionID: SessionID
        public var kind: Kind
        public init(sessionID: SessionID, kind: Kind) {
            self.sessionID = sessionID
            self.kind = kind
        }
        public enum Kind: Sendable {
            case sessionEnd(reason: String)
            case stop
            case notification(type: String)
            case toolResolved(toolUseID: String?) // PreToolUse/PostToolUse : le prompt est obsolète
        }
    }

    /// Analyse une enveloppe et produit un routage. `now` injectable pour les tests.
    public static func route(_ envelope: HookEnvelope, now: Date) -> Routing {
        guard let event = try? JSONSerialization.jsonObject(with: Data(envelope.eventJSON.utf8)) as? [String: Any],
              let eventName = event["hook_event_name"] as? String,
              let sessionId = event["session_id"] as? String else {
            return .ignore
        }
        let sessionID = SessionID(agent: .claude, nativeID: sessionId)
        let toolName = event["tool_name"] as? String

        switch eventName {
        case "PermissionRequest":
            return decisionPrompt(event: event, envelope: envelope, sessionID: sessionID,
                                  toolName: toolName, viaPreToolUse: false, now: now)
        case "PreToolUse" where toolName == "AskUserQuestion" || toolName == "ExitPlanMode":
            return decisionPrompt(event: event, envelope: envelope, sessionID: sessionID,
                                  toolName: toolName, viaPreToolUse: true, now: now)
        case "PreToolUse", "PostToolUse":
            return .telemetry(.init(sessionID: sessionID,
                                    kind: .toolResolved(toolUseID: event["tool_use_id"] as? String)))
        case "Stop":
            return .telemetry(.init(sessionID: sessionID, kind: .stop))
        case "SessionEnd":
            return .telemetry(.init(sessionID: sessionID,
                                    kind: .sessionEnd(reason: event["reason"] as? String ?? "other")))
        case "Notification":
            return .telemetry(.init(sessionID: sessionID,
                                    kind: .notification(type: event["notification_type"] as? String ?? "")))
        default:
            return .ignore
        }
    }

    // MARK: - Construction du prompt actionnable

    private static func decisionPrompt(
        event: [String: Any],
        envelope: HookEnvelope,
        sessionID: SessionID,
        toolName: String?,
        viaPreToolUse: Bool,
        now: Date
    ) -> Routing {
        let toolInput = event["tool_input"] as? [String: Any] ?? [:]
        let cwd = event["cwd"] as? String ?? ""
        let expiresAt = now.addingTimeInterval(IPCProtocol.hookDecisionDeadlineSeconds - 10)
        let label = sessionLabel(cwd: cwd, sessionID: sessionID)

        let payload: PendingPromptPayload
        let capabilities: PromptCapabilities

        switch toolName {
        case "ExitPlanMode":
            let markdown = toolInput["plan"] as? String ?? ""
            payload = .plan(PlanProposal(
                markdown: markdown,
                planFilePath: toolInput["planFilePath"] as? String,
                allowedPrompts: (toolInput["allowedPrompts"] as? [[String: Any]] ?? []).compactMap {
                    guard let tool = $0["tool"] as? String else { return nil }
                    return "\(tool): \($0["prompt"] as? String ?? "")"
                },
                title: planTitle(markdown),
                viaPreToolUse: viaPreToolUse
            ))
            capabilities = PromptCapabilities(
                canAlwaysAllow: false, canDenyWithFeedback: true, canAnswerInline: false,
                canApprovePlan: true, canHandInToTerminal: true
            )

        case "AskUserQuestion":
            let questions = (toolInput["questions"] as? [[String: Any]] ?? []).map { q in
                AgentQuestion(
                    id: q["question"] as? String ?? UUID().uuidString,
                    header: q["header"] as? String,
                    text: q["question"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                    multiSelect: q["multiSelect"] as? Bool ?? false
                )
            }
            let originalInput = (try? JSONSerialization.data(withJSONObject: toolInput))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            payload = .question(QuestionPrompt(
                questions: questions, toolName: "AskUserQuestion",
                originalInputJSON: originalInput, viaPreToolUse: viaPreToolUse
            ))
            capabilities = PromptCapabilities(
                canAlwaysAllow: false, canDenyWithFeedback: false, canAnswerInline: true,
                canApprovePlan: false, canHandInToTerminal: true
            )

        default:
            // Permission classique (Bash, Edit, Write, MCP…).
            let suggestions = parseSuggestions(event["permission_suggestions"])
            let command = toolInput["command"] as? String
            var honest: [String] = []
            var opaque: String?
            if let command {
                switch HonestCommandAnalyzer.analyze(command) {
                case .effects(let effects): honest = effects
                case .opaque(let reason): opaque = reason
                }
            }
            payload = .permission(PermissionRequest(
                toolName: toolName ?? "Tool",
                displayTitle: displayTitle(toolName: toolName, toolInput: toolInput),
                commandText: command,
                filePath: toolInput["file_path"] as? String,
                suggestions: suggestions,
                cwd: cwd,
                honestEffects: honest,
                effectsOpaqueReason: opaque
            ))
            capabilities = PromptCapabilities(
                canAlwaysAllow: !suggestions.isEmpty, canDenyWithFeedback: true,
                canAnswerInline: false, canApprovePlan: false, canHandInToTerminal: true
            )
        }

        let prompt = PendingPrompt(
            sessionID: sessionID, receivedAt: now, expiresAt: expiresAt,
            payload: payload, capabilities: capabilities, sessionLabel: label,
            termProgram: envelope.termProgram, ppid: envelope.ppid
        )
        return .decision(prompt)
    }

    private static func parseSuggestions(_ raw: Any?) -> [PermissionSuggestion] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(PermissionSuggestion.self, from: data)
        }
    }

    private static func displayTitle(toolName: String?, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return toolInput["description"] as? String ?? "Run a command"
        case "Edit", "MultiEdit", "Write":
            let file = (toolInput["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            return "\(toolName == "Write" ? "Write" : "Edit") \(file ?? "a file")"
        default:
            return toolName ?? "Tool request"
        }
    }

    private static func planTitle(_ markdown: String) -> String {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)) }
        }
        return "Plan"
    }

    private static func sessionLabel(cwd: String, sessionID: SessionID) -> String {
        let project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        return project
    }
}
